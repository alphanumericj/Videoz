import AVFoundation
import CoreGraphics
import CoreImage
import FlutterMacOS
import Foundation
import ImageIO
import Vision

/// Native, licensing-clean media renderer. The output is a flat list of "pieces"
/// — each a source file plus an in/out time — joined by an optional crossfade
/// (0 = hard cut). One composition drives both the live preview and the final
/// Apply, so what you watch is what gets written. No external binaries, no
/// GPL/LGPL code.
///
/// Channel "videoz/export":
///   - "render" with { pieces: [{path,start,end,cfAfter}], output }
///   - progress pushed back via "progress" (0.0–1.0)
class VideoExporter {
  private let channel: FlutterMethodChannel
  private var progressTimer: Timer?
  private var currentSession: AVAssetExportSession?
  private var currentReader: AVAssetReader?
  private let cancelFlag = CancelFlag()
  private var currentWriter: AVAssetWriter?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "videoz/export", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private struct Piece {
    let path: String
    let start: Double
    let end: Double
    let cfAfter: Double // transition duration into the next piece, seconds
    let typeAfter: String // "crossfade" | "fadeblack" | "slide" | "pagecurl" | "blinds" | "none"
    let clipId: String // which clip in the app's list this came from (blur regions are per clip)
    var length: Double { max(0, end - start) }
  }

  private static func num(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

  private static func normalizedRect(_ any: Any?) -> CGRect? {
    guard let d = any as? [String: Any], let x = num(d["x"]), let y = num(d["y"]),
          let w = num(d["w"]), let h = num(d["h"]) else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
  }

  /// Types that need a custom Core Image compositor (no AVFoundation ramp
  /// equivalent). Everything else uses the plain layer-instruction path below.
  private static let customCompositorTypes: Set<String> = ["pagecurl", "blinds"]

  /// Compression chosen in the Save dialog. "none" keeps the original frame
  /// size and lets AVAssetExportSession pick a high-quality encode. The other
  /// tiers cap the short side of the frame (so portrait video isn't squashed)
  /// and encode in constant-quality mode: the encoder spends only the bits the
  /// picture needs, so a mostly static screen recording shrinks a lot while
  /// busy footage costs more. (A fixed bitrate spends its target on every
  /// video, which left a 195 MB screen recording at 52 MB.)
  private struct Settings {
    let tier: String // "none" | "light" | "medium" | "heavy"

    var isCompressed: Bool { limits != nil }

    /// (max short side in px, encoder quality 0...1)
    private var limits: (shortSide: Double, quality: Double)? {
      switch tier {
      case "light": return (1080, 0.65)
      case "medium": return (720, 0.55)
      case "heavy": return (480, 0.45)
      default: return nil
      }
    }

    var quality: Double { limits?.quality ?? 0.5 }

    /// Scale down (never up) to the tier's cap; H.264 needs even dimensions.
    func scaledSize(_ size: CGSize) -> CGSize {
      guard let l = limits else { return size }
      var w = size.width, h = size.height
      let short = min(w, h)
      if short > l.shortSide {
        let k = l.shortSide / short
        w *= k
        h *= k
      }
      return CGSize(width: max(2, floor(w / 2) * 2), height: max(2, floor(h / 2) * 2))
    }
  }

  private final class ProgressBox { var value = 0.0 }

  /// Set from the main thread by "cancel", polled by the background text search.
  private final class CancelFlag {
    private let lock = NSLock()
    private var flag = false
    func set(_ v: Bool) { lock.lock(); flag = v; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "render":
      guard
        let args = call.arguments as? [String: Any],
        let rawPieces = args["pieces"] as? [[String: Any]],
        let output = args["output"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "Missing render arguments", details: nil))
        return
      }
      let pieces = rawPieces.compactMap { p -> Piece? in
        guard let path = p["path"] as? String,
              let start = p["start"] as? Double,
              let end = p["end"] as? Double else { return nil }
        return Piece(path: path, start: start, end: end,
                     cfAfter: (p["cfAfter"] as? Double) ?? 0,
                     typeAfter: (p["type"] as? String) ?? "crossfade",
                     clipId: (p["clipId"] as? String) ?? "")
      }
      let settings = Settings(tier: (args["compression"] as? String) ?? "none")
      let blurs = (args["blurs"] as? [[String: Any]] ?? []).compactMap { BlurRegionData(dict: $0) }
      render(pieces: pieces, blurs: blurs, output: output, settings: settings, result: result)
    case "track":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let anchor = Self.num(args["anchor"]),
            let rangeStart = Self.num(args["rangeStart"]),
            let rangeEnd = Self.num(args["rangeEnd"]),
            let rect = Self.normalizedRect(args["rect"]) else {
        result(FlutterError(code: "bad_args", message: "Missing track arguments", details: nil))
        return
      }
      track(path: path, anchor: anchor, rect: rect, rangeStart: rangeStart, rangeEnd: rangeEnd, result: result)
    case "readText":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let time = Self.num(args["time"]),
            let rect = Self.normalizedRect(args["rect"]) else {
        result(FlutterError(code: "bad_args", message: "Missing readText arguments", details: nil))
        return
      }
      readText(path: path, time: time, rect: rect, result: result)
    case "findText":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let phrases = args["phrases"] as? [String],
            let rangeStart = Self.num(args["rangeStart"]),
            let rangeEnd = Self.num(args["rangeEnd"]) else {
        result(FlutterError(code: "bad_args", message: "Missing findText arguments", details: nil))
        return
      }
      findText(path: path, phrases: phrases, rangeStart: rangeStart, rangeEnd: rangeEnd, result: result)
    case "blurPreview":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let time = Self.num(args["time"]),
            let rect = Self.normalizedRect(args["rect"]) else {
        result(FlutterError(code: "bad_args", message: "Missing preview arguments", details: nil))
        return
      }
      blurPreview(path: path, time: time, rect: rect, style: (args["style"] as? String) ?? "pixelate",
                  text: (args["text"] as? Bool) ?? false, result: result)
    case "remux":
      guard let args = call.arguments as? [String: Any],
            let input = args["input"] as? String,
            let output = args["output"] as? String else {
        result(FlutterError(code: "bad_args", message: "Missing remux arguments", details: nil))
        return
      }
      remux(input: input, output: output, result: result)
    case "probe":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "Missing path", details: nil))
        return
      }
      probe(path: path, result: result)
    case "thumbnails":
      guard let args = call.arguments as? [String: Any],
            let rawRequests = args["requests"] as? [[String: Any]] else {
        result(FlutterError(code: "bad_args", message: "Missing requests", details: nil))
        return
      }
      thumbnails(rawRequests, result: result)
    case "cancel":
      cancelFlag.set(true)
      currentSession?.cancelExport()
      currentReader?.cancelReading()
      currentWriter?.cancelWriting()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Return [duration seconds, display width, display height] (zeros if
  /// unreadable). Uses AVFoundation directly so we never spin up a
  /// video-player controller just to measure.
  private func probe(path: String, result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
      var err: NSError?
      let status = asset.statusOfValue(forKey: "duration", error: &err)
      let secs = status == .loaded ? CMTimeGetSeconds(asset.duration) : 0
      // Display size (after rotation), so the app can map a drawn box onto the frame.
      var w = 0.0, h = 0.0
      if let t = asset.tracks(withMediaType: .video).first {
        let r = CGRect(origin: .zero, size: t.naturalSize).applying(t.preferredTransform)
        w = Double(abs(r.width))
        h = Double(abs(r.height))
      }
      DispatchQueue.main.async {
        result([secs.isFinite ? secs : 0.0, w, h])
      }
    }
  }

  /// Generate small JPEG thumbnails for a batch of {path, time} requests, for
  /// the timeline's filmstrip. Runs off the main thread since
  /// AVAssetImageGenerator.copyCGImage is synchronous and can block; one
  /// generator is reused per unique path within a batch. Failures come back
  /// as NSNull (not a thrown error) so one bad frame doesn't sink the batch.
  private func thumbnails(_ raw: [[String: Any]], result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      var generators: [String: AVAssetImageGenerator] = [:]
      var out: [Any] = []
      for req in raw {
        guard let path = req["path"] as? String, let time = req["time"] as? Double else {
          out.append(NSNull())
          continue
        }
        let gen: AVAssetImageGenerator
        if let existing = generators[path] {
          gen = existing
        } else {
          let asset = AVURLAsset(url: URL(fileURLWithPath: path))
          let newGen = AVAssetImageGenerator(asset: asset)
          newGen.appliesPreferredTrackTransform = true
          newGen.maximumSize = CGSize(width: 200, height: 200)
          generators[path] = newGen
          gen = newGen
        }
        do {
          let cg = try gen.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
          let data = NSMutableData()
          guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            out.append(NSNull())
            continue
          }
          CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality as String: 0.6] as CFDictionary)
          CGImageDestinationFinalize(dest)
          out.append(FlutterStandardTypedData(bytes: data as Data))
        } catch {
          out.append(NSNull())
        }
      }
      DispatchQueue.main.async { result(out) }
    }
  }

  private func render(pieces: [Piece], blurs: [BlurRegionData], output: String, settings: Settings, result: @escaping FlutterResult) {
    let usable = pieces.filter { $0.length > 0 }
    if usable.isEmpty {
      result(FlutterError(code: "empty", message: "Nothing to render.", details: nil))
      return
    }

    // Blur boxes (and page curl / blinds) are drawn by the custom Core Image
    // compositor; renders without either keep the plain AVFoundation path.
    let hasBlur = usable.contains { pc in
      blurs.contains { $0.clipId == pc.clipId && $0.end > pc.start && $0.start < pc.end }
    }
    if hasBlur || usable.contains(where: { Self.customCompositorTypes.contains($0.typeAfter) }) {
      renderCustom(pieces: usable, blurs: blurs, output: output, settings: settings, result: result)
      return
    }

    let composition = AVMutableComposition()
    guard
      let vA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let vB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      result(FlutterError(code: "no_track", message: "Couldn't create video tracks.", details: nil))
      return
    }
    let vTracks = [vA, vB]
    let aTracks = [
      composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
      composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
    ]

    struct Placed { let track: Int; let start: CMTime; let dur: CMTime; let fit: CGAffineTransform; let typeAfter: String }
    var placed: [Placed] = []
    var overlaps: [Double] = [] // overlap before piece i (index i-1)

    var renderSize = CGSize(width: 1280, height: 720)
    var frameRate: Int32 = 30
    var cursor = CMTime.zero
    var prevLen = 0.0

    for (i, pc) in usable.enumerated() {
      let asset = AVURLAsset(url: URL(fileURLWithPath: pc.path))
      guard let srcV = asset.tracks(withMediaType: .video).first else { continue }
      let inRange = CMTimeRange(
        start: CMTime(seconds: pc.start, preferredTimescale: 600),
        duration: CMTime(seconds: pc.length, preferredTimescale: 600))

      if placed.isEmpty {
        let r = CGRect(origin: .zero, size: srcV.naturalSize).applying(srcV.preferredTransform)
        renderSize = settings.scaledSize(CGSize(width: abs(r.width), height: abs(r.height)))
        let fr = Int32(srcV.nominalFrameRate.rounded())
        frameRate = fr > 0 ? fr : 30
      }

      var start = cursor
      if !placed.isEmpty {
        let reqCf = usable[i - 1].cfAfter
        let cf = reqCf <= 0 ? 0 : min(reqCf, 0.5 * prevLen, 0.5 * pc.length)
        overlaps.append(cf)
        start = cursor - CMTime(seconds: cf, preferredTimescale: 600)
      }
      let track = placed.count % 2
      do {
        try vTracks[track].insertTimeRange(inRange, of: srcV, at: start)
        if let srcA = asset.tracks(withMediaType: .audio).first, let aTrack = aTracks[track] {
          try aTrack.insertTimeRange(inRange, of: srcA, at: start)
        }
      } catch {
        result(FlutterError(code: "compose_failed", message: error.localizedDescription, details: nil))
        return
      }
      let fit = Self.fitTransform(naturalSize: srcV.naturalSize, preferred: srcV.preferredTransform, render: renderSize)
      placed.append(Placed(track: track, start: start, dur: CMTime(seconds: pc.length, preferredTimescale: 600), fit: fit, typeAfter: pc.typeAfter))
      cursor = start + CMTime(seconds: pc.length, preferredTimescale: 600)
      prevLen = pc.length
    }

    if placed.isEmpty {
      result(FlutterError(code: "no_video", message: "None of the pieces had a video track.", details: nil))
      return
    }

    var instructions: [AVMutableVideoCompositionInstruction] = []
    for (idx, p) in placed.enumerated() {
      let headT = idx >= 1 ? overlaps[idx - 1] : 0
      let tailT = idx <= placed.count - 2 ? overlaps[idx] : 0
      let soloFrom = p.start + CMTime(seconds: headT, preferredTimescale: 600)
      let soloTo = p.start + p.dur - CMTime(seconds: tailT, preferredTimescale: 600)

      let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTracks[p.track])
      li.setTransform(p.fit, at: soloFrom)
      let inst = AVMutableVideoCompositionInstruction()
      inst.timeRange = CMTimeRange(start: soloFrom, end: soloTo)
      inst.layerInstructions = [li]
      instructions.append(inst)

      if idx <= placed.count - 2 && overlaps[idx] > 0 {
        let next = placed[idx + 1]
        let range = CMTimeRange(
          start: next.start,
          duration: CMTime(seconds: overlaps[idx], preferredTimescale: 600))
        instructions.append(Self.transitionInstruction(
          type: p.typeAfter, range: range, renderSize: renderSize,
          out: (vTracks[p.track], p.fit), incoming: (vTracks[next.track], next.fit)))
      }
    }

    // Audio: crossfade volumes over each overlap.
    let audioMix = AVMutableAudioMix()
    var params: [AVMutableAudioMixInputParameters] = []
    for t in 0..<2 {
      if let track = aTracks[t] {
        let prm = AVMutableAudioMixInputParameters(track: track)
        prm.setVolume(1.0, at: .zero)
        params.append(prm)
      }
    }
    if params.count == 2 {
      for (idx, p) in placed.enumerated() where idx <= placed.count - 2 && overlaps[idx] > 0 {
        let next = placed[idx + 1]
        let range = CMTimeRange(
          start: next.start,
          duration: CMTime(seconds: overlaps[idx], preferredTimescale: 600))
        params[p.track].setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0, timeRange: range)
        params[next.track].setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0, timeRange: range)
      }
      audioMix.inputParameters = params
    }

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = renderSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
    videoComposition.instructions = instructions

    runExport(
      composition: composition, videoComposition: videoComposition, audioMix: audioMix,
      output: output, settings: settings, frameRate: frameRate,
      result: result)
  }

  /// Build the video instruction for one transition [range] between the
  /// outgoing and incoming pieces, according to [type].
  private static func transitionInstruction(
    type: String,
    range: CMTimeRange,
    renderSize: CGSize,
    out: (track: AVCompositionTrack, fit: CGAffineTransform),
    incoming: (track: AVCompositionTrack, fit: CGAffineTransform)
  ) -> AVMutableVideoCompositionInstruction {
    let inst = AVMutableVideoCompositionInstruction()
    inst.timeRange = range
    let outLI = AVMutableVideoCompositionLayerInstruction(assetTrack: out.track)
    let inLI = AVMutableVideoCompositionLayerInstruction(assetTrack: incoming.track)
    outLI.setTransform(out.fit, at: range.start)
    inLI.setTransform(incoming.fit, at: range.start)

    switch type {
    case "fadeblack":
      // A fades to black over the first half; B fades up over the second half,
      // so the (black) background shows through in the middle.
      let half = CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5)
      let mid = range.start + half
      let firstHalf = CMTimeRange(start: range.start, duration: half)
      let secondHalf = CMTimeRange(start: mid, duration: half)
      outLI.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: firstHalf)
      inLI.setOpacity(0.0, at: range.start)
      inLI.setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0, timeRange: secondHalf)
      inst.layerInstructions = [outLI, inLI]

    case "slide":
      // B slides in from the right edge, covering A (which holds still).
      let offset = incoming.fit.concatenating(
        CGAffineTransform(translationX: renderSize.width, y: 0))
      inLI.setTransformRamp(fromStart: offset, toEnd: incoming.fit, timeRange: range)
      inst.layerInstructions = [inLI, outLI] // incoming on top, sliding over

    default: // "crossfade"
      outLI.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: range)
      inst.layerInstructions = [outLI, inLI] // outgoing on top, fading away
    }
    return inst
  }

  /// Aspect-fit + center a clip (respecting its rotation) into `render`.
  private static func fitTransform(
    naturalSize nw: CGSize, preferred pt: CGAffineTransform, render: CGSize
  ) -> CGAffineTransform {
    let r = CGRect(origin: .zero, size: nw).applying(pt)
    let dispW = abs(r.width), dispH = abs(r.height)
    guard dispW > 0, dispH > 0 else { return pt }
    let s = min(render.width / dispW, render.height / dispH)
    let tx = (render.width - dispW * s) / 2.0 - r.origin.x * s
    let ty = (render.height - dispH * s) / 2.0 - r.origin.y * s
    return pt
      .concatenating(CGAffineTransform(scaleX: s, y: s))
      .concatenating(CGAffineTransform(translationX: tx, y: ty))
  }

  private static func fileType(for path: String) -> AVFileType {
    switch (path as NSString).pathExtension.lowercased() {
    case "mp4": return .mp4
    case "m4v": return .m4v
    case "m4a": return .m4a
    default: return .mov
    }
  }

  // MARK: - Custom compositor path (page curl / bars swipe)
  //
  // AVFoundation's built-in layer instructions only understand opacity,
  // transform, and crop-rect ramps — not arbitrary per-frame image filters.
  // Page curl and bars swipe use Core Image's transition filters, which need a
  // custom AVVideoCompositing implementation. This whole path (solo playback
  // included) is independent of the plain path above, so crossfade/fadeblack/
  // slide/no-transition renders are completely unaffected and keep using the
  // already-verified AVFoundation-ramp implementation.

  private func renderCustom(pieces: [Piece], blurs: [BlurRegionData], output: String, settings: Settings, result: @escaping FlutterResult) {
    let composition = AVMutableComposition()
    guard
      let vA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let vB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      result(FlutterError(code: "no_track", message: "Couldn't create video tracks.", details: nil))
      return
    }
    let vTracks = [vA, vB]
    let aTracks = [
      composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
      composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
    ]

    struct Placed {
      let track: Int; let start: CMTime; let dur: CMTime; let fit: CGAffineTransform; let typeAfter: String
      let srcStart: Double; let dispRect: CGRect; let regions: [BlurRegionData]
    }
    var placed: [Placed] = []
    var overlaps: [Double] = []
    var renderSize = CGSize(width: 1280, height: 720)
    var frameRate: Int32 = 30
    var cursor = CMTime.zero
    var prevLen = 0.0

    for (i, pc) in pieces.enumerated() {
      let asset = AVURLAsset(url: URL(fileURLWithPath: pc.path))
      guard let srcV = asset.tracks(withMediaType: .video).first else { continue }
      let inRange = CMTimeRange(
        start: CMTime(seconds: pc.start, preferredTimescale: 600),
        duration: CMTime(seconds: pc.length, preferredTimescale: 600))

      if placed.isEmpty {
        let r = CGRect(origin: .zero, size: srcV.naturalSize).applying(srcV.preferredTransform)
        renderSize = settings.scaledSize(CGSize(width: abs(r.width), height: abs(r.height)))
        let fr = Int32(srcV.nominalFrameRate.rounded())
        frameRate = fr > 0 ? fr : 30
      }

      var start = cursor
      if !placed.isEmpty {
        let reqCf = pieces[i - 1].cfAfter
        let cf = reqCf <= 0 ? 0 : min(reqCf, 0.5 * prevLen, 0.5 * pc.length)
        overlaps.append(cf)
        start = cursor - CMTime(seconds: cf, preferredTimescale: 600)
      }
      let track = placed.count % 2
      do {
        try vTracks[track].insertTimeRange(inRange, of: srcV, at: start)
        if let srcA = asset.tracks(withMediaType: .audio).first, let aTrack = aTracks[track] {
          try aTrack.insertTimeRange(inRange, of: srcA, at: start)
        }
      } catch {
        result(FlutterError(code: "compose_failed", message: error.localizedDescription, details: nil))
        return
      }
      let fit = Self.fitTransform(naturalSize: srcV.naturalSize, preferred: srcV.preferredTransform, render: renderSize)
      placed.append(Placed(
        track: track, start: start, dur: CMTime(seconds: pc.length, preferredTimescale: 600), fit: fit,
        typeAfter: pc.typeAfter, srcStart: pc.start,
        // Where this clip's displayed frame lands in the canvas (top-left origin).
        dispRect: CGRect(origin: .zero, size: srcV.naturalSize).applying(fit),
        regions: blurs.filter { $0.clipId == pc.clipId && $0.end > pc.start && $0.start < pc.end }))
      cursor = start + CMTime(seconds: pc.length, preferredTimescale: 600)
      prevLen = pc.length
    }

    if placed.isEmpty {
      result(FlutterError(code: "no_video", message: "None of the pieces had a video track.", details: nil))
      return
    }

    var instructions: [TransitionInstruction] = []
    for (idx, p) in placed.enumerated() {
      let headT = idx >= 1 ? overlaps[idx - 1] : 0
      let tailT = idx <= placed.count - 2 ? overlaps[idx] : 0
      let soloFrom = p.start + CMTime(seconds: headT, preferredTimescale: 600)
      let soloTo = p.start + p.dur - CMTime(seconds: tailT, preferredTimescale: 600)
      let trackID = vTracks[p.track].trackID
      func info(_ q: Placed) -> SourceInfo {
        SourceInfo(compStart: q.start, srcStart: q.srcStart, dispRect: q.dispRect, regions: q.regions)
      }
      instructions.append(TransitionInstruction(
        timeRange: CMTimeRange(start: soloFrom, end: soloTo),
        kind: .solo(track: trackID, fit: p.fit),
        sources: [trackID: info(p)]))

      if idx <= placed.count - 2 && overlaps[idx] > 0 {
        let next = placed[idx + 1]
        let range = CMTimeRange(start: next.start, duration: CMTime(seconds: overlaps[idx], preferredTimescale: 600))
        instructions.append(TransitionInstruction(
          timeRange: range,
          kind: .transition(type: p.typeAfter,
                             outTrack: vTracks[p.track].trackID, outFit: p.fit,
                             inTrack: vTracks[next.track].trackID, inFit: next.fit),
          sources: [vTracks[p.track].trackID: info(p), vTracks[next.track].trackID: info(next)]))
      }
    }

    let audioMix = AVMutableAudioMix()
    var params: [AVMutableAudioMixInputParameters] = []
    for t in 0..<2 {
      if let track = aTracks[t] {
        let prm = AVMutableAudioMixInputParameters(track: track)
        prm.setVolume(1.0, at: .zero)
        params.append(prm)
      }
    }
    if params.count == 2 {
      for (idx, p) in placed.enumerated() where idx <= placed.count - 2 && overlaps[idx] > 0 {
        let next = placed[idx + 1]
        let range = CMTimeRange(start: next.start, duration: CMTime(seconds: overlaps[idx], preferredTimescale: 600))
        params[p.track].setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0, timeRange: range)
        params[next.track].setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0, timeRange: range)
      }
      audioMix.inputParameters = params
    }

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = renderSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
    videoComposition.instructions = instructions
    videoComposition.customVideoCompositorClass = TransitionCompositor.self

    runExport(
      composition: composition, videoComposition: videoComposition, audioMix: audioMix,
      output: output, settings: settings, frameRate: frameRate,
      result: result)
  }

  // MARK: - Blur text: read what's in a box, then find it everywhere

  /// Lowercased letters and digits only (accents folded), remembering where each
  /// kept character sat in the original string, so a match found on the
  /// stripped text can be turned back into a range of the original.
  private struct NormText {
    var chars: [Character] = []
    var origOffsets: [Int] = [] // offset, in Characters, into the original string
  }

  private static func normalize(_ s: String) -> NormText {
    var n = NormText()
    for (i, ch) in s.enumerated() {
      let folded = String(ch).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      for c in folded where c.isLetter || c.isNumber {
        n.chars.append(c)
        n.origOffsets.append(i)
      }
    }
    return n
  }

  private static func editDistance(_ a: ArraySlice<Character>, _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    var cur = [Int](repeating: 0, count: b.count + 1)
    for (i, ca) in a.enumerated() {
      cur[0] = i + 1
      for j in 0..<b.count {
        cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == b[j] ? 0 : 1))
      }
      swap(&prev, &cur)
    }
    return prev[b.count]
  }

  /// How many characters of misreading to forgive for a phrase of this length.
  private static func tolerance(_ length: Int) -> Int {
    length <= 4 ? 0 : (length <= 9 ? 1 : (length <= 18 ? 2 : 3))
  }

  /// Non-overlapping places in `text` that match `query` to within `k` edits,
  /// as ranges of normalized characters, best (fewest edits) first accepted.
  private static func fuzzyMatches(in text: NormText, query: [Character], k: Int) -> [Range<Int>] {
    let m = query.count, n = text.chars.count
    guard m > 0, n >= max(1, m - k) else { return [] }
    var candidates: [(dist: Int, start: Int, len: Int)] = []
    for i in 0..<n {
      var best: (dist: Int, len: Int)?
      for len in max(1, m - k)...(m + k) where i + len <= n {
        let d = editDistance(text.chars[i..<(i + len)], query)
        if d <= k, best == nil || d < best!.dist || (d == best!.dist && abs(len - m) < abs(best!.len - m)) {
          best = (d, len)
        }
      }
      if let b = best { candidates.append((b.dist, i, b.len)) }
    }
    candidates.sort { ($0.dist, $0.start) < ($1.dist, $1.start) }
    var accepted: [Range<Int>] = []
    for c in candidates {
      let r = c.start..<(c.start + c.len)
      if !accepted.contains(where: { $0.overlaps(r) }) { accepted.append(r) }
    }
    return accepted.sorted { $0.lowerBound < $1.lowerBound }
  }

  /// Read the text inside `rect` (normalized, top-left origin) on the frame at
  /// `time`: one string per line, top to bottom. The box is cropped and scaled
  /// up first, which makes small text read much better.
  private func readText(path: String, time: Double, rect: CGRect, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
      gen.appliesPreferredTrackTransform = true
      gen.requestedTimeToleranceBefore = .zero
      gen.requestedTimeToleranceAfter = .zero
      guard let cg = try? gen.copyCGImage(at: CMTime(seconds: max(0, time), preferredTimescale: 600), actualTime: nil) else {
        DispatchQueue.main.async { result([String]()) }
        return
      }
      let image = CIImage(cgImage: cg)
      let w = CGFloat(cg.width), h = CGFloat(cg.height)
      let box = CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h)
      let pad = 0.1 * max(box.width, box.height)
      let crop = box.insetBy(dx: -pad, dy: -pad).intersection(image.extent).integral
      guard !crop.isNull, crop.width >= 4, crop.height >= 4 else {
        DispatchQueue.main.async { result([String]()) }
        return
      }
      let up = min(4, max(1, 240 / crop.height))
      let prepared = image.cropped(to: crop)
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                       .concatenating(CGAffineTransform(scaleX: up, y: up)))
      let req = VNRecognizeTextRequest()
      req.recognitionLevel = .accurate
      req.usesLanguageCorrection = false
      try? VNImageRequestHandler(ciImage: prepared, options: [:]).perform([req])
      let lines = (req.results ?? [])
        .sorted { $0.boundingBox.midY > $1.boundingBox.midY } // top of the crop first
        .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      DispatchQueue.main.async { result(lines) }
    }
  }

  /// Read the text on frames of `[rangeStart, rangeEnd]` (8 a second) and, in
  /// each, find every place any of `phrases` appears: ignoring capitals,
  /// punctuation and spacing, and forgiving a few misread characters. Replies
  /// with {hits: [[t, x, y, w, h, x, y, w, h, ...]], checked: N}: only frames
  /// where something was found, boxes normalized, top-left origin. Reports
  /// progress as it goes and stops early if "cancel" is called.
  private func findText(path: String, phrases: [String], rangeStart: Double, rangeEnd: Double,
                        result: @escaping FlutterResult) {
    cancelFlag.set(false)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      func finish(_ value: Any?) { DispatchQueue.main.async { result(value) } }
      let queries = phrases.map { Self.normalize($0).chars }.filter { !$0.isEmpty }
      guard !queries.isEmpty else {
        finish(FlutterError(code: "bad_args", message: "Type at least one phrase to look for.", details: nil))
        return
      }
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      guard let vt = asset.tracks(withMediaType: .video).first else {
        finish(FlutterError(code: "find_failed", message: "This file has no video to search.", details: nil))
        return
      }
      let shown = CGRect(origin: .zero, size: vt.naturalSize).applying(vt.preferredTransform)
      let dw = abs(shown.width), dh = abs(shown.height)
      guard dw > 0, dh > 0 else {
        finish(FlutterError(code: "find_failed", message: "Couldn't read the video size.", details: nil))
        return
      }
      // Upright frames, at most 1600 px on the long side (text needs the pixels).
      let k = min(1.0, 1600.0 / max(dw, dh))
      let render = CGSize(width: max(2, floor(dw * k / 2) * 2), height: max(2, floor(dh * k / 2) * 2))
      let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
      layer.setTransform(Self.fitTransform(naturalSize: vt.naturalSize, preferred: vt.preferredTransform, render: render), at: .zero)
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      instruction.layerInstructions = [layer]
      let comp = AVMutableVideoComposition()
      comp.renderSize = render
      let fps = vt.nominalFrameRate > 0 ? vt.nominalFrameRate.rounded() : 30
      comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
      comp.instructions = [instruction]
      let out = AVAssetReaderVideoCompositionOutput(
        videoTracks: [vt],
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)])
      out.videoComposition = comp
      let reader: AVAssetReader
      do {
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, rangeStart), preferredTimescale: 600),
                                       end: CMTime(seconds: max(rangeStart, rangeEnd), preferredTimescale: 600))
        guard reader.canAdd(out) else { throw NSError(domain: "Videoz", code: 1) }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Videoz", code: 2) }
      } catch {
        finish(FlutterError(code: "find_failed", message: "Couldn't read the video.", details: nil))
        return
      }

      let step = 0.125
      let span = max(0.001, rangeEnd - rangeStart)
      var next = rangeStart
      var checked = 0
      var hits: [[Double]] = []
      while let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
        if self.cancelFlag.isSet {
          reader.cancelReading()
          finish(FlutterError(code: "cancelled", message: "Search cancelled.", details: nil))
          return
        }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        if pts + 1e-6 < next { continue }
        next = max(next + step, pts + step / 2)

        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.004
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        checked += 1

        var found: [CGRect] = []
        for obs in req.results ?? [] {
          guard let cand = obs.topCandidates(1).first else { continue }
          let line = cand.string
          let norm = Self.normalize(line)
          for q in queries {
            for r in Self.fuzzyMatches(in: norm, query: q, k: Self.tolerance(q.count)) {
              let startOff = norm.origOffsets[r.lowerBound]
              let endOff = norm.origOffsets[r.upperBound - 1] + 1
              let lo = line.index(line.startIndex, offsetBy: startOff)
              let hi = line.index(line.startIndex, offsetBy: min(endOff, line.count))
              guard let bb = try? cand.boundingBox(for: lo..<hi)?.boundingBox else { continue }
              found.append(CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height))
            }
          }
        }
        if !found.isEmpty {
          var row: [Double] = [pts]
          for f in found { row += [Double(f.minX), Double(f.minY), Double(f.width), Double(f.height)] }
          hits.append(row)
        }
        let fraction = min(1, max(0, (pts - rangeStart) / span))
        DispatchQueue.main.async { self.channel.invokeMethod("progress", arguments: fraction) }
      }
      reader.cancelReading()
      finish(["hits": hits, "checked": checked])
    }
  }

  // MARK: - Blur: tracking and preview

  private struct TrackError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private struct TrackSample {
    var t: Double
    var rect: CGRect // normalized, top-left origin
    var conf: Float
  }

  /// Follow the object in `rect` (normalized, top-left origin, on the frame at
  /// `anchor`) forward to `rangeEnd` and backward to `rangeStart`, using
  /// Vision's object tracker on upright, downscaled frames. Replies with
  /// [[t, x, y, w, h, confidence]] in time order. Where confidence drops the box
  /// is held at its last good position (and the low confidence is reported), so
  /// the caller can flag the stretch instead of trusting a wandering box.
  private func track(path: String, anchor: Double, rect: CGRect, rangeStart: Double, rangeEnd: Double,
                     result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let samples = try Self.runTracking(path: path, anchor: anchor, box: rect,
                                           rangeStart: rangeStart, rangeEnd: rangeEnd)
        let out: [[Double]] = samples.map {
          [$0.t, Double($0.rect.minX), Double($0.rect.minY), Double($0.rect.width), Double($0.rect.height), Double($0.conf)]
        }
        DispatchQueue.main.async { result(out) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "track_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private static func runTracking(path: String, anchor: Double, box: CGRect,
                                  rangeStart: Double, rangeEnd: Double) throws -> [TrackSample] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let vt = asset.tracks(withMediaType: .video).first else {
      throw TrackError(message: "This file has no video to track.")
    }
    let natural = vt.naturalSize
    let shown = CGRect(origin: .zero, size: natural).applying(vt.preferredTransform)
    let dw = abs(shown.width), dh = abs(shown.height)
    guard dw > 0, dh > 0 else { throw TrackError(message: "Couldn't read the video size.") }
    let k = min(1.0, 960.0 / max(dw, dh))
    let render = CGSize(width: max(2, floor(dw * k / 2) * 2), height: max(2, floor(dh * k / 2) * 2))
    let fit = Self.fitTransform(naturalSize: natural, preferred: vt.preferredTransform, render: render)

    // Upright frames (rotation applied), so Vision's boxes match what the user saw.
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
    layer.setTransform(fit, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    instruction.layerInstructions = [layer]
    let comp = AVMutableVideoComposition()
    comp.renderSize = render
    let fps = vt.nominalFrameRate > 0 ? vt.nominalFrameRate.rounded() : 30
    comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
    comp.instructions = [instruction]

    func makeReader(_ from: Double, _ to: Double) throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
      let reader = try AVAssetReader(asset: asset)
      reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, from), preferredTimescale: 600),
                                     end: CMTime(seconds: max(from, to), preferredTimescale: 600))
      let out = AVAssetReaderVideoCompositionOutput(
        videoTracks: [vt],
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)])
      out.videoComposition = comp
      guard reader.canAdd(out) else { throw TrackError(message: "Couldn't read the video.") }
      reader.add(out)
      guard reader.startReading() else {
        throw TrackError(message: reader.error?.localizedDescription ?? "Couldn't read the video.")
      }
      return (reader, out)
    }

    let start = CGRect(x: max(0, min(1, box.minX)), y: max(0, min(1, box.minY)),
                       width: max(0.005, min(1, box.width)), height: max(0.005, min(1, box.height)))

    /// Run the tracker over frames in the order `next` yields them.
    func follow(_ next: () -> (CVPixelBuffer, Double)?) -> [TrackSample] {
      var samples: [TrackSample] = []
      let handler = VNSequenceRequestHandler()
      // Vision wants bottom-left-origin boxes.
      var obs = VNDetectedObjectObservation(
        boundingBox: CGRect(x: start.minX, y: 1 - start.maxY, width: start.width, height: start.height))
      var lastGood = start
      var first = true
      while let (pb, t) = next() {
        let req = VNTrackObjectRequest(detectedObjectObservation: obs)
        req.trackingLevel = .accurate
        if first {
          // The first frame establishes the object's appearance; report the
          // user's own box for it.
          try? handler.perform([req], on: pb)
          if let r = req.results?.first as? VNDetectedObjectObservation { obs = r }
          samples.append(TrackSample(t: t, rect: start, conf: 1))
          first = false
          continue
        }
        do { try handler.perform([req], on: pb) } catch {
          samples.append(TrackSample(t: t, rect: lastGood, conf: 0))
          continue
        }
        guard let r = req.results?.first as? VNDetectedObjectObservation else {
          samples.append(TrackSample(t: t, rect: lastGood, conf: 0))
          continue
        }
        obs = r // keep feeding it back so it can re-acquire after a dip
        let bb = r.boundingBox
        let tl = CGRect(x: max(0, bb.minX), y: max(0, 1 - bb.maxY),
                        width: min(1, bb.width), height: min(1, bb.height))
        if r.confidence >= 0.35 && tl.width > 0.003 && tl.height > 0.003 {
          lastGood = tl
          samples.append(TrackSample(t: t, rect: tl, conf: r.confidence))
        } else {
          samples.append(TrackSample(t: t, rect: lastGood, conf: r.confidence))
        }
      }
      return samples
    }

    // Forward: anchor -> end.
    var forward: [TrackSample] = []
    if rangeEnd > anchor {
      let (reader, out) = try makeReader(anchor, rangeEnd)
      forward = follow {
        guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        return (pb, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)))
      }
      reader.cancelReading()
    } else {
      // Anchor at the very end of the range: just the user's box.
      forward = [TrackSample(t: anchor, rect: start, conf: 1)]
    }

    // Backward: read one second at a time (decoding only goes forward), then
    // feed that chunk to the tracker in reverse. Starts again at the anchor frame.
    var backward: [TrackSample] = []
    if anchor > rangeStart {
      var chunkEnd = anchor
      var lastPTS = Double.infinity
      var frames: [(CMSampleBuffer, Double)] = []
      var pending: [(CMSampleBuffer, Double)] = [] // frames of the current chunk, newest first
      var firstChunk = true
      func nextBackward() -> (CVPixelBuffer, Double)? {
        while pending.isEmpty {
          guard chunkEnd > rangeStart + 1e-6 else { return nil }
          let chunkStart = max(rangeStart, chunkEnd - 1.0)
          guard let (reader, out) = try? makeReader(chunkStart, chunkEnd + (firstChunk ? 0.05 : 0)) else { return nil }
          frames.removeAll()
          while let sb = out.copyNextSampleBuffer() {
            frames.append((sb, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))))
          }
          reader.cancelReading()
          firstChunk = false
          pending = frames.reversed().filter { $0.1 < lastPTS - 1e-4 }
          chunkEnd = chunkStart
          if chunkStart <= rangeStart + 1e-6 && pending.isEmpty { return nil }
        }
        let (sb, t) = pending.removeFirst()
        lastPTS = t
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return nextBackward() }
        return (pb, t)
      }
      backward = follow(nextBackward)
      if !backward.isEmpty { backward.removeFirst() } // that was the anchor frame again
    }

    var all = backward.reversed() + forward
    all.sort { $0.t < $1.t }
    guard !all.isEmpty else { throw TrackError(message: "No frames were read in that range.") }

    // Light smoothing (5-frame average) so the box doesn't jitter.
    var smooth = all
    for i in all.indices {
      let lo = max(0, i - 2), hi = min(all.count - 1, i + 2)
      var x = 0.0, y = 0.0, w = 0.0, h = 0.0
      for j in lo...hi {
        x += Double(all[j].rect.minX); y += Double(all[j].rect.minY)
        w += Double(all[j].rect.width); h += Double(all[j].rect.height)
      }
      let n = Double(hi - lo + 1)
      smooth[i].rect = CGRect(x: x / n, y: y / n, width: w / n, height: h / n)
    }
    // The tracker can shrink onto the most distinctive part of an object (a
    // rotating rocket's thin side view, say), and a box that's too small leaks.
    // But an object that is really getting smaller (the camera zooming out, a
    // person walking away) should get a smaller box. The difference is speed: a
    // real zoom-out shrinks gradually, a wobble drops fast. So the box may shrink
    // only as fast as the biggest it was within the last and next 0.6 s allows
    // (never below 80% of that), and never under a quarter of what the user drew.
    let half = Int(max(1, (Double(fps) * 0.6).rounded()))
    let hardMinW = start.width * 0.25, hardMinH = start.height * 0.25
    let sizes = smooth.map { ($0.rect.width, $0.rect.height) }
    for i in smooth.indices {
      let lo = max(0, i - half), hi = min(smooth.count - 1, i + half)
      var maxW: CGFloat = 0, maxH: CGFloat = 0
      for j in lo...hi {
        maxW = max(maxW, sizes[j].0)
        maxH = max(maxH, sizes[j].1)
      }
      let minW = max(hardMinW, 0.8 * maxW), minH = max(hardMinH, 0.8 * maxH)
      var r = smooth[i].rect
      if r.width < minW { r = CGRect(x: r.midX - minW / 2, y: r.minY, width: minW, height: r.height) }
      if r.height < minH { r = CGRect(x: r.minX, y: r.midY - minH / 2, width: r.width, height: minH) }
      r.origin.x = max(0, min(1 - r.width, r.minX))
      r.origin.y = max(0, min(1 - r.height, r.minY))
      smooth[i].rect = r
    }
    return smooth
  }

  /// Three small JPEGs (fine, medium, coarse) of the box in the given style, on
  /// the frame at `time`, so the user can pick a look by looking at it.
  private func blurPreview(path: String, time: Double, rect: CGRect, style: String, text: Bool = false,
                           result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let none: [Any] = [NSNull(), NSNull(), NSNull()]
      let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
      gen.appliesPreferredTrackTransform = true
      gen.maximumSize = CGSize(width: 1920, height: 1920)
      gen.requestedTimeToleranceBefore = .zero
      gen.requestedTimeToleranceAfter = .zero
      guard let cg = try? gen.copyCGImage(at: CMTime(seconds: max(0, time), preferredTimescale: 600), actualTime: nil) else {
        DispatchQueue.main.async { result(none) }
        return
      }
      let image = CIImage(cgImage: cg)
      let w = CGFloat(cg.width), h = CGFloat(cg.height)
      let box = CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h)
      let crop = paddedBox(box, extent: image.extent, text: text)
      let ctx = CIContext()
      var out: [Any] = []
      for scale in ["fine", "medium", "coarse"] {
        guard !crop.isNull, crop.width >= 2, crop.height >= 2 else { out.append(NSNull()); continue }
        let k = min(1, 260 / crop.width)
        let shown = applyBlur(image, box: box, style: style, scale: scale, text: text)
          .cropped(to: crop)
          .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                         .concatenating(CGAffineTransform(scaleX: k, y: k)))
        guard let rendered = ctx.createCGImage(shown, from: shown.extent) else { out.append(NSNull()); continue }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
          out.append(NSNull())
          continue
        }
        CGImageDestinationAddImage(dest, rendered, [kCGImageDestinationLossyCompressionQuality as String: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
        out.append(FlutterStandardTypedData(bytes: data as Data))
      }
      DispatchQueue.main.async { result(out) }
    }
  }

  // MARK: - Export back ends

  private func runExport(
    composition: AVMutableComposition,
    videoComposition: AVMutableVideoComposition,
    audioMix: AVMutableAudioMix,
    output: String,
    settings: Settings,
    frameRate: Int32,
    result: @escaping FlutterResult
  ) {
    // An audio track nothing was placed on (a silent clip, or an A/B track one
    // clip never used) makes AVAssetExportSession stop with "Operation Stopped".
    // Drop those, and any mix parameters that point at them.
    for t in composition.tracks(withMediaType: .audio) where t.segments.isEmpty {
      composition.removeTrack(t)
    }
    let liveAudio = Set(composition.tracks(withMediaType: .audio).map { $0.trackID })
    audioMix.inputParameters = audioMix.inputParameters.filter { liveAudio.contains($0.trackID) }

    if settings.isCompressed {
      exportWithWriter(
        composition: composition, videoComposition: videoComposition, audioMix: audioMix,
        output: output, settings: settings, frameRate: frameRate,
        result: result)
    } else {
      exportWithSession(
        composition: composition, videoComposition: videoComposition, audioMix: audioMix,
        output: output, result: result)
    }
  }

  /// Uncompressed path: AVAssetExportSession's highest-quality preset, which
  /// keeps the composition's frame size.
  private func exportWithSession(
    composition: AVMutableComposition,
    videoComposition: AVMutableVideoComposition,
    audioMix: AVMutableAudioMix,
    output: String,
    result: @escaping FlutterResult
  ) {
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
      result(FlutterError(code: "no_session", message: "Couldn't create an export session.", details: nil))
      return
    }
    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)
    session.outputURL = outURL
    session.outputFileType = Self.fileType(for: output)
    session.videoComposition = videoComposition
    if !audioMix.inputParameters.isEmpty { session.audioMix = audioMix }
    session.shouldOptimizeForNetworkUse = true
    runSession(session, failCode: "render_failed", result: result)
  }

  private func runSession(_ session: AVAssetExportSession, failCode: String, result: @escaping FlutterResult) {
    currentSession = session
    startProgressTimer { Double(session.progress) }
    session.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        self?.stopProgressTimer()
        self?.currentSession = nil
        switch session.status {
        case .completed:
          result(nil)
        case .cancelled:
          result(FlutterError(code: "cancelled", message: "Render cancelled.", details: nil))
        default:
          let msg = session.error?.localizedDescription ?? "Unknown render error."
          result(FlutterError(code: failCode, message: msg, details: nil))
        }
      }
    }
  }

  /// Convert a single untouched file to another container (e.g. .mov to .mp4)
  /// by copying its streams as-is: instant and lossless. Reports
  /// "remux_unsupported" when the streams can't live in that container (ProRes
  /// in an .mp4, say) so the caller can fall back to a normal re-encode.
  private func remux(input: String, output: String, result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    let type = Self.fileType(for: output)
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
          session.supportedFileTypes.contains(type)
    else {
      result(FlutterError(
        code: "remux_unsupported",
        message: "This file can't be copied into that format without re-encoding.",
        details: nil))
      return
    }
    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)
    session.outputURL = outURL
    session.outputFileType = type
    session.shouldOptimizeForNetworkUse = true
    runSession(session, failCode: "remux_failed", result: result)
  }

  /// Compressed path: read the composed frames and encode H.264 in
  /// constant-quality mode (AVAssetExportSession can't, and its Medium/Low
  /// presets ignore the frame size). Audio is re-encoded as 128 kbps AAC.
  private func exportWithWriter(
    composition: AVMutableComposition,
    videoComposition: AVMutableVideoComposition,
    audioMix: AVMutableAudioMix,
    output: String,
    settings: Settings,
    frameRate: Int32,
    result: @escaping FlutterResult
  ) {
    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)
    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
      reader = try AVAssetReader(asset: composition)
      writer = try AVAssetWriter(outputURL: outURL, fileType: Self.fileType(for: output))
    } catch {
      result(FlutterError(code: "no_session", message: error.localizedDescription, details: nil))
      return
    }
    writer.shouldOptimizeForNetworkUse = true

    let size = videoComposition.renderSize
    let videoOut = AVAssetReaderVideoCompositionOutput(
      videoTracks: composition.tracks(withMediaType: .video),
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)])
    videoOut.videoComposition = videoComposition
    let fps = Int(max(frameRate, 1))
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoQualityKey: settings.quality,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: fps * 2,
      ] as [String: Any],
    ])
    videoIn.expectsMediaDataInRealTime = false
    guard reader.canAdd(videoOut), writer.canAdd(videoIn) else {
      result(FlutterError(code: "no_session", message: "Couldn't set up the video encoder.", details: nil))
      return
    }
    reader.add(videoOut)
    writer.add(videoIn)

    // Only add audio when something was actually placed on an audio track.
    let audioTracks = composition.tracks(withMediaType: .audio)
    var audioPair: (AVAssetReaderAudioMixOutput, AVAssetWriterInput)?
    if audioTracks.contains(where: { !$0.segments.isEmpty }) {
      let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
      ])
      if !audioMix.inputParameters.isEmpty { audioOut.audioMix = audioMix }
      let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
      ])
      if reader.canAdd(audioOut), writer.canAdd(audioIn) {
        reader.add(audioOut)
        writer.add(audioIn)
        audioPair = (audioOut, audioIn)
      }
    }

    guard writer.startWriting() else {
      result(FlutterError(code: "render_failed",
                          message: writer.error?.localizedDescription ?? "Couldn't start writing the file.",
                          details: nil))
      return
    }
    guard reader.startReading() else {
      writer.cancelWriting()
      result(FlutterError(code: "render_failed",
                          message: reader.error?.localizedDescription ?? "Couldn't read the video.",
                          details: nil))
      return
    }
    writer.startSession(atSourceTime: .zero)
    currentReader = reader
    currentWriter = writer

    let totalSeconds = max(0.001, CMTimeGetSeconds(composition.duration))
    let progress = ProgressBox()
    startProgressTimer { progress.value }

    let group = DispatchGroup()
    func pump(_ out: AVAssetReaderOutput, _ input: AVAssetWriterInput, label: String, reportsProgress: Bool) {
      let queue = DispatchQueue(label: label)
      var done = false
      group.enter()
      input.requestMediaDataWhenReady(on: queue) {
        while input.isReadyForMoreMediaData && !done {
          guard let sample = out.copyNextSampleBuffer() else {
            done = true
            input.markAsFinished()
            group.leave()
            return
          }
          if reportsProgress {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            progress.value = min(1, max(0, pts / totalSeconds))
          }
          if !input.append(sample) {
            done = true
            input.markAsFinished()
            group.leave()
            return
          }
        }
      }
    }
    pump(videoOut, videoIn, label: "videoz.write.video", reportsProgress: true)
    if let (audioOut, audioIn) = audioPair {
      pump(audioOut, audioIn, label: "videoz.write.audio", reportsProgress: false)
    }

    group.notify(queue: .main) { [weak self] in
      self?.stopProgressTimer()
      self?.currentReader = nil
      self?.currentWriter = nil
      if reader.status == .cancelled {
        writer.cancelWriting()
        result(FlutterError(code: "cancelled", message: "Render cancelled.", details: nil))
        return
      }
      if reader.status == .failed || writer.status == .failed {
        let msg = (writer.error ?? reader.error)?.localizedDescription ?? "Unknown render error."
        writer.cancelWriting()
        result(FlutterError(code: "render_failed", message: msg, details: nil))
        return
      }
      writer.finishWriting {
        DispatchQueue.main.async {
          if writer.status == .completed {
            result(nil)
          } else {
            result(FlutterError(code: "render_failed",
                                message: writer.error?.localizedDescription ?? "Unknown render error.",
                                details: nil))
          }
        }
      }
    }
  }

  private func startProgressTimer(_ current: @escaping () -> Double) {
    progressTimer?.invalidate()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.channel.invokeMethod("progress", arguments: current())
    }
  }

  private func stopProgressTimer() {
    progressTimer?.invalidate()
    progressTimer = nil
  }
}

/// One instruction for the custom compositor: either a single track shown
/// as-is (fit-transformed), or a transition blending an outgoing and
/// incoming track. Tuned and verified against real Core Image output before
/// being wired in — see the transition-tuning notes in VideoExporter.swift's
/// git history / project README.
private final class TransitionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
  enum Kind {
    case solo(track: CMPersistentTrackID, fit: CGAffineTransform)
    case transition(type: String, outTrack: CMPersistentTrackID, outFit: CGAffineTransform,
                     inTrack: CMPersistentTrackID, inFit: CGAffineTransform)
  }

  var timeRange: CMTimeRange
  var enablePostProcessing: Bool = false
  var containsTweening: Bool = true
  var requiredSourceTrackIDs: [NSValue]?
  var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
  let kind: Kind
  /// Per source track: where its frames sit in time and the blur boxes to draw.
  let sources: [CMPersistentTrackID: SourceInfo]

  init(timeRange: CMTimeRange, kind: Kind, sources: [CMPersistentTrackID: SourceInfo] = [:]) {
    self.timeRange = timeRange
    self.kind = kind
    self.sources = sources
    switch kind {
    case .solo(let track, _):
      requiredSourceTrackIDs = [NSNumber(value: track)]
    case .transition(_, let outTrack, _, let inTrack, _):
      requiredSourceTrackIDs = [NSNumber(value: outTrack), NSNumber(value: inTrack)]
    }
    super.init()
  }
}

/// Renders solo playback and all five transition types via Core Image. Solo
/// frames are simply fit-transformed and letterboxed; crossfade/fadeblack/
/// slide are hand-reimplemented here to match the plain AVFoundation-ramp
/// path's behavior (verified: identical boundary/midpoint luma values);
/// page curl and bars swipe use Core Image's built-in transition filters.
private final class TransitionCompositor: NSObject, AVVideoCompositing {
  let sourcePixelBufferAttributes: [String: Any]? = [
    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
  ]
  let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
  ]

  private var renderContext: AVVideoCompositionRenderContext?
  private let ciContext = CIContext()

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    renderContext = newRenderContext
  }

  func cancelAllPendingVideoCompositionRequests() {}

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    guard let instruction = request.videoCompositionInstruction as? TransitionInstruction,
          let outputBuffer = renderContext?.newPixelBuffer()
    else {
      request.finish(with: NSError(domain: "Videoz", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Compositor: missing render context"]))
      return
    }
    let renderSize = renderContext?.size ?? CGSize(width: 1280, height: 720)
    let extent = CGRect(origin: .zero, size: renderSize)
    let black = CIImage(color: .black).cropped(to: extent)

    func fitted(_ trackID: CMPersistentTrackID, _ fit: CGAffineTransform) -> CIImage {
      guard let buf = request.sourceFrame(byTrackID: trackID) else { return black }
      // `fit` is in AVFoundation's video space (origin top-left, y down); Core
      // Image is y up. Conjugate with a vertical flip on each side, otherwise
      // rotated clips (phone video) come out upside down.
      let bufH = CGFloat(CVPixelBufferGetHeight(buf))
      let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bufH)
      let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderSize.height)
      var img = CIImage(cvPixelBuffer: buf)
        .transformed(by: flipIn.concatenating(fit).concatenating(flipOut))
        .composited(over: black)
        .cropped(to: extent)
      if let info = instruction.sources[trackID], !info.regions.isEmpty {
        let srcTime = info.srcStart + (request.compositionTime - info.compStart).seconds
        for region in info.regions {
          for n in region.rects(at: srcTime) {
            let d = info.dispRect
            let box = CGRect(
              x: d.minX + n.minX * d.width,
              y: renderSize.height - (d.minY + (n.minY + n.height) * d.height),
              width: n.width * d.width,
              height: n.height * d.height)
            img = applyBlur(img, box: box, style: region.style, scale: region.scale, text: region.isText)
          }
        }
      }
      return img
    }

    let output: CIImage
    switch instruction.kind {
    case .solo(let track, let fit):
      output = fitted(track, fit)
    case .transition(let type, let outTrack, let outFit, let inTrack, let inFit):
      let outImg = fitted(outTrack, outFit)
      let inImg = fitted(inTrack, inFit)
      let durSecs = instruction.timeRange.duration.seconds
      let t = durSecs > 0
        ? (request.compositionTime - instruction.timeRange.start).seconds / durSecs
        : 0
      output = Self.blend(type: type, out: outImg, incoming: inImg,
                           t: max(0, min(1, t)), extent: extent, renderSize: renderSize)
    }

    ciContext.render(output, to: outputBuffer, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
    request.finish(withComposedVideoFrame: outputBuffer)
  }

  private static func blend(
    type: String, out: CIImage, incoming: CIImage, t: Double, extent: CGRect, renderSize: CGSize
  ) -> CIImage {
    switch type {
    case "pagecurl":
      // Diagonal curl anchored near the top-right corner, like an actual page
      // turn. inputAngle's mapping from value -> fold-line orientation was
      // mapped empirically: fold is vertical at 0°/180° (edges at left/right),
      // horizontal at 90°/270° (edges at top/bottom), rotating continuously
      // between. 205° gives a steep, backslash-like diagonal anchored toward
      // the top-right — steeper (more vertical) than the 235° first tried.
      //
      // The shading band's direction is derived from the same angle
      // (bandDir = (cos angle, sin angle)) rather than hardcoded, matching the
      // empirical fact that a 0° (vertical) fold wants a horizontal band and a
      // 90° (horizontal) fold wants a vertical one — so retuning the angle
      // keeps the highlight/shadow aligned with the fold automatically.
      let angle = 205.0 * Double.pi / 180.0
      let radius = min(renderSize.width, renderSize.height) * 0.42
      let ux = CGFloat(cos(angle)), uy = CGFloat(sin(angle))
      let cx = renderSize.width * 0.5, cy = renderSize.height * 0.5
      let p0 = CGPoint(x: cx - ux * radius, y: cy - uy * radius)
      let pMid = CGPoint(x: cx, y: cy)
      let p1 = CGPoint(x: cx + ux * radius, y: cy + uy * radius)
      let g1 = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: pMid),
        "inputColor0": CIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),
        "inputColor1": CIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1),
      ])!.outputImage!.cropped(to: extent)
      let g2 = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(cgPoint: pMid), "inputPoint1": CIVector(cgPoint: p1),
        "inputColor0": CIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1),
        "inputColor1": CIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),
      ])!.outputImage!.cropped(to: extent)
      let shading = g2.composited(over: g1)

      let f = CIFilter(name: "CIPageCurlTransition")!
      f.setValue(out, forKey: "inputImage")
      f.setValue(incoming, forKey: "inputTargetImage")
      f.setValue(out, forKey: "inputBacksideImage")
      f.setValue(shading, forKey: "inputShadingImage")
      f.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
      f.setValue(t, forKey: "inputTime")
      f.setValue(angle, forKey: "inputAngle")
      f.setValue(radius, forKey: "inputRadius")
      return (f.outputImage ?? incoming).cropped(to: extent)

    case "blinds":
      // No canned Core Image filter does this (CIBarsSwipeTransition is a
      // diagonal staggered bar sweep, a different effect despite the name).
      // Hand-built: split the frame into horizontal bands; a strip centered in
      // each band grows from 0 to full band height, revealing the incoming
      // clip — like a row of prism/flip-panel signs rotating in unison.
      let bandCount = 10
      let bandH = renderSize.height / CGFloat(bandCount)
      let revealH = bandH * CGFloat(t)
      guard let maskCtx = CGContext(
        data: nil, width: Int(renderSize.width), height: Int(renderSize.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
      else { return incoming }
      maskCtx.setFillColor(gray: 0, alpha: 1)
      maskCtx.fill(CGRect(origin: .zero, size: renderSize))
      maskCtx.setFillColor(gray: 1, alpha: 1)
      for i in 0..<bandCount {
        let bandY = CGFloat(i) * bandH
        let stripY = bandY + (bandH - revealH) / 2
        maskCtx.fill(CGRect(x: 0, y: stripY, width: renderSize.width, height: revealH))
      }
      guard let maskCG = maskCtx.makeImage() else { return incoming }
      let mask = CIImage(cgImage: maskCG)
      let f = CIFilter(name: "CIBlendWithMask")!
      f.setValue(incoming, forKey: "inputImage")
      f.setValue(out, forKey: "inputBackgroundImage")
      f.setValue(mask, forKey: "inputMaskImage")
      return (f.outputImage ?? incoming).cropped(to: extent)

    case "fadeblack":
      let black = CIImage(color: .black).cropped(to: extent)
      if t <= 0.5 {
        let alpha = 1 - (t / 0.5)
        return out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
          .composited(over: black)
      } else {
        let alpha = (t - 0.5) / 0.5
        return incoming.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
          .composited(over: black)
      }

    case "slide":
      let dx = renderSize.width * (1 - t)
      let slid = incoming.transformed(by: CGAffineTransform(translationX: dx, y: 0))
      return slid.composited(over: out)

    default: // "crossfade"
      let outFaded = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - t)])
      return outFaded.composited(over: incoming)
    }
  }
}

/// Where one source track's frames sit in time, and the blur boxes that apply.
private struct SourceInfo {
  let compStart: CMTime // composition time at which this piece starts
  let srcStart: Double // clip time (seconds) of that first frame
  let dispRect: CGRect // the clip's displayed frame inside the canvas, top-left origin
  let regions: [BlurRegionData]
}

/// One blur region from the app, over a clip-time range. Either an object: one
/// tracked box (normalized to the clip's displayed frame, top-left origin) per
/// sample time. Or text: for each stretch of time, the boxes of every place the
/// searched text was found (there can be several per frame).
private final class BlurRegionData {
  let clipId: String
  let start: Double
  let end: Double
  let scale: String // "fine" | "medium" | "coarse"
  let style: String // "pixelate" | "blur" | "box" | "fill"
  private let times: [Double]
  private let rects: [CGRect]
  private let entries: [(a: Double, b: Double, rects: [CGRect])]
  let isText: Bool

  init?(dict: [String: Any]) {
    func numbers(_ any: Any?) -> [Double]? { (any as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } }
    guard let clipId = dict["clipId"] as? String,
          let start = (dict["start"] as? NSNumber)?.doubleValue,
          let end = (dict["end"] as? NSNumber)?.doubleValue
    else { return nil }
    self.clipId = clipId
    self.start = start
    self.end = end
    self.scale = (dict["scale"] as? String) ?? "medium"
    self.style = (dict["style"] as? String) ?? "pixelate"
    func quads(_ flat: ArraySlice<Double>) -> [CGRect] {
      var out: [CGRect] = []
      var i = flat.startIndex
      while i + 3 < flat.endIndex {
        out.append(CGRect(x: flat[i], y: flat[i + 1], width: flat[i + 2], height: flat[i + 3]))
        i += 4
      }
      return out
    }
    if let raw = dict["entries"] as? [Any] {
      // Text: each entry is [from, to, x, y, w, h, x, y, w, h, ...].
      var list: [(a: Double, b: Double, rects: [CGRect])] = []
      for e in raw {
        guard let n = numbers(e), n.count >= 6 else { continue }
        list.append((a: n[0], b: n[1], rects: quads(n[2...])))
      }
      guard !list.isEmpty else { return nil }
      isText = true
      entries = list
      times = []
      rects = []
    } else {
      guard let flat = numbers(dict["samples"]), flat.count >= 5 else { return nil }
      var t: [Double] = []
      var r: [CGRect] = []
      var i = 0
      while i + 4 < flat.count {
        t.append(flat[i])
        r.append(CGRect(x: flat[i + 1], y: flat[i + 2], width: flat[i + 3], height: flat[i + 4]))
        i += 5
      }
      isText = false
      times = t
      rects = r
      entries = []
    }
  }

  /// The boxes to pixelate at clip time `t`: for an object, its one box
  /// (interpolated between samples, held at the ends); for text, every box from
  /// every stretch that covers `t`. Empty outside the region's own range.
  func rects(at t: Double) -> [CGRect] {
    guard t >= start - 0.001, t <= end + 0.001 else { return [] }
    if isText {
      var out: [CGRect] = []
      for e in entries where t >= e.a - 1e-6 && t <= e.b + 1e-6 { out += e.rects }
      return out
    }
    guard !times.isEmpty else { return [] }
    if t <= times[0] { return [rects[0]] }
    if t >= times[times.count - 1] { return [rects[rects.count - 1]] }
    var lo = 0, hi = times.count - 1
    while hi - lo > 1 {
      let mid = (lo + hi) / 2
      if times[mid] <= t { lo = mid } else { hi = mid }
    }
    let f = CGFloat((t - times[lo]) / max(1e-9, times[hi] - times[lo]))
    let a = rects[lo], b = rects[hi]
    return [CGRect(x: a.minX + (b.minX - a.minX) * f, y: a.minY + (b.minY - a.minY) * f,
                   width: a.width + (b.width - a.width) * f, height: a.height + (b.height - a.height) * f)]
  }
}

/// The area actually pixelated for a tracked box: grown by 20% on every side
/// (and at least 1.2% of the frame's short side), because a tracker that is a
/// little small or off should still hide the target, not leave an edge of it.
///
/// For text the boxes are already tight around the letters, and a phrase can be
/// long, so growing by a fifth of its width would eat neighbouring words:
/// there it grows by a third of the text's height all round instead.
private func paddedBox(_ box: CGRect, extent: CGRect, text: Bool = false) -> CGRect {
  let floorPad = 0.012 * min(extent.width, extent.height)
  let padX = text ? max(0.33 * box.height, floorPad) : max(0.20 * box.width, floorPad)
  let padY = text ? max(0.33 * box.height, floorPad) : max(0.20 * box.height, floorPad)
  return box.insetBy(dx: -padX, dy: -padY).intersection(extent).integral
}

/// Pixelate `box` (Core Image coordinates, y up) inside `image`. The block size
/// is relative to the padded box, so a small face and a wide banner look alike.
private func pixelateBox(_ image: CIImage, box: CGRect, scale: String, text: Bool = false) -> CIImage {
  let padded = paddedBox(box, extent: image.extent, text: text)
  guard !padded.isNull, padded.width >= 2, padded.height >= 2 else { return image }
  let across: CGFloat
  switch scale {
  case "fine": across = 10
  case "coarse": across = 3
  default: across = 6
  }
  let block = max(3, min(padded.width, padded.height) / across)
  guard let f = CIFilter(name: "CIPixellate") else { return image }
  f.setValue(image.cropped(to: padded), forKey: kCIInputImageKey)
  f.setValue(CIVector(x: padded.minX, y: padded.minY), forKey: kCIInputCenterKey)
  f.setValue(block, forKey: kCIInputScaleKey)
  guard let out = f.outputImage else { return image }
  return out.cropped(to: padded).composited(over: image)
}

/// Draw the chosen look over `box` (Core Image coordinates, y up).
private func applyBlur(_ image: CIImage, box: CGRect, style: String, scale: String, text: Bool) -> CIImage {
  switch style {
  case "blur": return frostedBlur(image, box: box, scale: scale, text: text)
  case "fill": return backgroundFill(image, box: box, text: text)
  case "box":
    let padded = paddedBox(box, extent: image.extent, text: text)
    guard !padded.isNull, padded.width >= 2, padded.height >= 2 else { return image }
    return CIImage(color: .black).cropped(to: padded).composited(over: image)
  default: return pixelateBox(image, box: box, scale: scale, text: text)
  }
}

/// A smooth, cloudy blur whose edge fades out instead of ending in a hard
/// rectangle. The fully-blurred core is the padded box grown by half the fade, so
/// the target itself is never in the thin part of the fade.
private func frostedBlur(_ image: CIImage, box: CGRect, scale: String, text: Bool) -> CIImage {
  let padded = paddedBox(box, extent: image.extent, text: text)
  guard !padded.isNull, padded.width >= 2, padded.height >= 2 else { return image }
  let short = min(padded.width, padded.height)
  let feather = max(4, 0.15 * short)
  let core = padded.insetBy(dx: -0.5 * feather, dy: -0.5 * feather)
  let outer = core.insetBy(dx: -1.2 * feather, dy: -1.2 * feather).intersection(image.extent).integral
  guard !outer.isNull, outer.width >= 2, outer.height >= 2 else { return image }

  // Light / Medium / Heavy. Text is the hard case: the blur has to be a good
  // fraction of the letters' height before it stops being readable.
  let blurDivisor: CGFloat = scale == "fine" ? 5 : (scale == "coarse" ? 2.5 : 3.5)
  let sigma = max(2, short / blurDivisor)

  let softened = image.clampedToExtent()
    .applyingGaussianBlur(sigma: Double(sigma))
    .cropped(to: outer)

  // White core fading to black, as an opaque grayscale mask.
  let mask = CIImage(color: .white)
    .cropped(to: core.intersection(outer))
    .composited(over: CIImage(color: .black).cropped(to: outer))
    .clampedToExtent()
    .applyingGaussianBlur(sigma: Double(feather / 2.5))
    .cropped(to: outer)
  return softened
    .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
    .cropped(to: image.extent)
}

/// "White out": cover the box with the color of what surrounds it, so text on a
/// plain or gently shaded background all but disappears. The colors are the
/// average of a thin strip just outside each side of the box; the fill blends the
/// left strip into the right (and top into bottom) and averages the two, so a
/// background that changes across the box is followed. The edge is feathered a
/// little. Everything happens in the Core Image graph, with no readback.
private func backgroundFill(_ image: CIImage, box: CGRect, text: Bool) -> CIImage {
  let padded = paddedBox(box, extent: image.extent, text: text)
  guard !padded.isNull, padded.width >= 2, padded.height >= 2 else { return image }
  let short = min(padded.width, padded.height)
  let feather = max(3, 0.08 * short)
  let core = padded.insetBy(dx: -0.5 * feather, dy: -0.5 * feather)
  let outer = core.insetBy(dx: -1.2 * feather, dy: -1.2 * feather).intersection(image.extent).integral
  guard !outer.isNull, outer.width >= 2, outer.height >= 2 else { return image }

  // A flat color (as an endless image) from the average of a strip, if it's on screen.
  let thick = max(2, 0.08 * short)
  func side(_ strip: CGRect) -> CIImage? {
    let r = strip.intersection(image.extent).integral
    guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
    return image.cropped(to: r)
      .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
      .clampedToExtent()
  }
  let left = side(CGRect(x: core.minX - thick - 1, y: core.minY, width: thick, height: core.height))
  let right = side(CGRect(x: core.maxX + 1, y: core.minY, width: thick, height: core.height))
  let bottom = side(CGRect(x: core.minX, y: core.minY - thick - 1, width: core.width, height: thick))
  let top = side(CGRect(x: core.minX, y: core.maxY + 1, width: core.width, height: thick))
  // Use the opposite side where one is off the edge of the picture.
  let l = left ?? right ?? top ?? bottom, r = right ?? left ?? top ?? bottom
  let t = top ?? bottom ?? left ?? right, b = bottom ?? top ?? left ?? right
  guard let l = l, let r = r, let t = t, let b = b else {
    return CIImage(color: .black).cropped(to: padded).composited(over: image)
  }

  func ramp(from: CGPoint, to: CGPoint) -> CIImage {
    CIFilter(name: "CILinearGradient", parameters: [
      "inputPoint0": CIVector(cgPoint: from), "inputPoint1": CIVector(cgPoint: to),
      "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
      "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
    ])!.outputImage!.cropped(to: outer)
  }
  let horizontal = l.cropped(to: outer).applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: r.cropped(to: outer),
    kCIInputMaskImageKey: ramp(from: CGPoint(x: core.minX, y: 0), to: CGPoint(x: core.maxX, y: 0)),
  ])
  let vertical = t.cropped(to: outer).applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: b.cropped(to: outer),
    kCIInputMaskImageKey: ramp(from: CGPoint(x: 0, y: core.maxY), to: CGPoint(x: 0, y: core.minY)),
  ])
  let fill = horizontal
    .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: vertical, kCIInputTimeKey: 0.5])
    .cropped(to: outer)

  let mask = CIImage(color: .white)
    .cropped(to: core.intersection(outer))
    .composited(over: CIImage(color: .black).cropped(to: outer))
    .clampedToExtent()
    .applyingGaussianBlur(sigma: Double(feather / 2.5))
    .cropped(to: outer)
  return fill
    .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
    .cropped(to: image.extent)
}
