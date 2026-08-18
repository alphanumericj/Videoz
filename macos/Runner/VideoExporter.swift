import AVFoundation
import CoreGraphics
import CoreImage
import FlutterMacOS
import Foundation
import ImageIO

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
    var length: Double { max(0, end - start) }
  }

  /// Types that need a custom Core Image compositor (no AVFoundation ramp
  /// equivalent). Everything else uses the plain layer-instruction path below.
  private static let customCompositorTypes: Set<String> = ["pagecurl", "blinds"]

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
                     typeAfter: (p["type"] as? String) ?? "crossfade")
      }
      render(pieces: pieces, output: output, result: result)
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
      currentSession?.cancelExport()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Return a file's duration in seconds (0 if unreadable). Uses AVFoundation
  /// directly so we never spin up a video-player controller just to measure.
  private func probe(path: String, result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    asset.loadValuesAsynchronously(forKeys: ["duration"]) {
      var err: NSError?
      let status = asset.statusOfValue(forKey: "duration", error: &err)
      let secs = status == .loaded ? CMTimeGetSeconds(asset.duration) : 0
      DispatchQueue.main.async {
        result(secs.isFinite ? secs : 0.0)
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

  private func render(pieces: [Piece], output: String, result: @escaping FlutterResult) {
    let usable = pieces.filter { $0.length > 0 }
    if usable.isEmpty {
      result(FlutterError(code: "empty", message: "Nothing to render.", details: nil))
      return
    }

    if usable.contains(where: { Self.customCompositorTypes.contains($0.typeAfter) }) {
      renderCustom(pieces: usable, output: output, result: result)
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
        renderSize = CGSize(width: abs(r.width), height: abs(r.height))
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
    currentSession = session

    startProgressTimer(session)
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
          result(FlutterError(code: "render_failed", message: msg, details: nil))
        }
      }
    }
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

  private func renderCustom(pieces: [Piece], output: String, result: @escaping FlutterResult) {
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
        renderSize = CGSize(width: abs(r.width), height: abs(r.height))
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
      placed.append(Placed(track: track, start: start, dur: CMTime(seconds: pc.length, preferredTimescale: 600), fit: fit, typeAfter: pc.typeAfter))
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
      instructions.append(TransitionInstruction(
        timeRange: CMTimeRange(start: soloFrom, end: soloTo),
        kind: .solo(track: trackID, fit: p.fit)))

      if idx <= placed.count - 2 && overlaps[idx] > 0 {
        let next = placed[idx + 1]
        let range = CMTimeRange(start: next.start, duration: CMTime(seconds: overlaps[idx], preferredTimescale: 600))
        instructions.append(TransitionInstruction(
          timeRange: range,
          kind: .transition(type: p.typeAfter,
                             outTrack: vTracks[p.track].trackID, outFit: p.fit,
                             inTrack: vTracks[next.track].trackID, inFit: next.fit)))
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
    currentSession = session

    startProgressTimer(session)
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
          result(FlutterError(code: "render_failed", message: msg, details: nil))
        }
      }
    }
  }

  private func startProgressTimer(_ session: AVAssetExportSession) {
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.channel.invokeMethod("progress", arguments: Double(session.progress))
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

  init(timeRange: CMTimeRange, kind: Kind) {
    self.timeRange = timeRange
    self.kind = kind
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
      let img = CIImage(cvPixelBuffer: buf).transformed(by: fit)
      return img.composited(over: black).cropped(to: extent)
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
