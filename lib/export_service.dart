import 'package:flutter/services.dart';

import 'blur_region.dart';
import 'export_settings.dart';

/// What a text search found: the frames where it appeared, and how many it read.
class TextSearchResult {
  const TextSearchResult({required this.hits, required this.checked});
  final List<TextHit> hits;
  final int checked;
}

/// A single filmstrip-thumbnail request: [time] seconds into the file at [path].
class ThumbRequest {
  const ThumbRequest({required this.path, required this.time});
  final String path;
  final double time;

  Map<String, dynamic> toMap() => {'path': path, 'time': time};
}

class ExportException implements Exception {
  ExportException(this.message, {this.code});
  final String message;

  /// The native error code, when there is one (e.g. `remux_failed`).
  final String? code;
  @override
  String toString() => message;
}

/// One piece of the output: [start]–[end] seconds of the file at [path],
/// followed by a [crossfade] (seconds) into the next piece (0 = hard cut).
class RenderPiece {
  RenderPiece({
    required this.path,
    required this.start,
    required this.end,
    this.crossfade = 0,
    this.type = 'none',
    this.clipId = '',
  });

  final String path;
  final double start;
  final double end;
  final double crossfade;
  final String type; // transition into the next piece
  final String clipId; // which clip this came from (blur regions belong to a clip)

  Map<String, dynamic> toMap() => {
        'path': path,
        'start': start,
        'end': end,
        'cfAfter': crossfade,
        'type': type,
        'clipId': clipId,
      };
}

/// Talks to the native macOS AVFoundation renderer. The same call builds the
/// preview and the final file — see macos/Runner/VideoExporter.swift.
class ExportService {
  ExportService() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel('videoz/export');

  void Function(double progress)? _onProgress;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'progress') {
      final p = (call.arguments as num?)?.toDouble() ?? 0.0;
      _onProgress?.call(p.clamp(0.0, 1.0));
    }
    return null;
  }

  /// Render [pieces] into [outputPath]. Throws [ExportException] on failure.
  Future<void> render({
    required List<RenderPiece> pieces,
    required String outputPath,
    Compression compression = Compression.none,
    List<BlurRegion> blurs = const [],
    void Function(double progress)? onProgress,
  }) async {
    if (pieces.isEmpty) {
      throw ExportException('Nothing to render.');
    }
    _onProgress = onProgress;
    try {
      await _channel.invokeMethod<void>('render', {
        'pieces': pieces.map((p) => p.toMap()).toList(),
        'output': outputPath,
        'compression': compression.wire,
        'blurs': blurs.map((b) => b.toMap()).toList(),
      });
    } on PlatformException catch (e) {
      throw ExportException(e.message ?? 'Render failed (${e.code}).', code: e.code);
    } finally {
      _onProgress = null;
    }
  }

  /// Convert one untouched file to the container implied by [outputPath]'s
  /// extension by copying its streams: instant and lossless. Throws
  /// [ExportException] (code `remux_unsupported` / `remux_failed`) when the
  /// streams can't live in that container, so the caller can re-encode.
  Future<void> remux({
    required String inputPath,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    _onProgress = onProgress;
    try {
      await _channel.invokeMethod<void>('remux', {
        'input': inputPath,
        'output': outputPath,
      });
    } on PlatformException catch (e) {
      throw ExportException(e.message ?? 'Convert failed (${e.code}).', code: e.code);
    } finally {
      _onProgress = null;
    }
  }

  /// Duration and displayed frame size of a media file, measured natively (no
  /// video-player controller). The size is null when there's no video track.
  Future<({Duration duration, Size? size})> probeInfo(String path) async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('probe', {'path': path});
      final secs = (raw != null && raw.isNotEmpty ? raw[0] as num : 0).toDouble();
      final w = (raw != null && raw.length > 1 ? raw[1] as num : 0).toDouble();
      final h = (raw != null && raw.length > 2 ? raw[2] as num : 0).toDouble();
      return (
        duration: Duration(microseconds: (secs * 1e6).round()),
        size: (w > 0 && h > 0) ? Size(w, h) : null,
      );
    } on PlatformException {
      return (duration: Duration.zero, size: null);
    }
  }

  /// Follow the object in [rect] (0 to 1, top-left origin, on the frame at
  /// [anchor] seconds) through [rangeStart]..[rangeEnd] of the clip, forward and
  /// backward. Throws [ExportException] if the video can't be read.
  Future<List<BlurSample>> track({
    required String path,
    required double anchor,
    required Rect rect,
    required double rangeStart,
    required double rangeEnd,
  }) async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('track', {
        'path': path,
        'anchor': anchor,
        'rangeStart': rangeStart,
        'rangeEnd': rangeEnd,
        'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
      });
      return [
        for (final row in (raw ?? const <Object?>[]).cast<List<Object?>>())
          BlurSample(
            t: (row[0] as num).toDouble(),
            rect: Rect.fromLTWH((row[1] as num).toDouble(), (row[2] as num).toDouble(),
                (row[3] as num).toDouble(), (row[4] as num).toDouble()),
            conf: (row[5] as num).toDouble(),
          ),
      ];
    } on PlatformException catch (e) {
      throw ExportException(e.message ?? 'Tracking failed (${e.code}).', code: e.code);
    }
  }

  /// The text inside [rect] (0 to 1, top-left origin) on the frame at [time]
  /// seconds, one string per line, top to bottom. Empty if nothing was readable.
  Future<List<String>> readText({
    required String path,
    required double time,
    required Rect rect,
  }) async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('readText', {
        'path': path,
        'time': time,
        'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
      });
      return [for (final e in raw ?? const <Object?>[]) e.toString()];
    } on PlatformException {
      return const [];
    }
  }

  /// Read the text on frames of [rangeStart]..[rangeEnd] (clip seconds) and find
  /// every place any of [phrases] appears (ignoring capitals and punctuation, and
  /// forgiving a few misread characters). [onProgress] gets 0 to 1. Call [cancel]
  /// to stop early, which throws an [ExportException] with code `cancelled`.
  Future<TextSearchResult> findText({
    required String path,
    required List<String> phrases,
    required double rangeStart,
    required double rangeEnd,
    void Function(double progress)? onProgress,
  }) async {
    _onProgress = onProgress;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('findText', {
        'path': path,
        'phrases': phrases,
        'rangeStart': rangeStart,
        'rangeEnd': rangeEnd,
      });
      final hits = <TextHit>[];
      for (final row in (raw?['hits'] as List<Object?>? ?? const <Object?>[])) {
        final n = (row as List<Object?>).cast<num>();
        hits.add(TextHit(t: n[0].toDouble(), rects: [
          for (var i = 1; i + 3 < n.length; i += 4)
            Rect.fromLTWH(n[i].toDouble(), n[i + 1].toDouble(), n[i + 2].toDouble(), n[i + 3].toDouble()),
        ]));
      }
      return TextSearchResult(hits: hits, checked: (raw?['checked'] as num?)?.toInt() ?? 0);
    } on PlatformException catch (e) {
      throw ExportException(e.message ?? 'Search failed (${e.code}).', code: e.code);
    } finally {
      _onProgress = null;
    }
  }

  /// Three small JPEGs of [rect] drawn in [style] at its three strengths, on the
  /// frame at [time] seconds. A `null` entry means that one failed. [text] pads
  /// the box the way a text blur does.
  Future<List<Uint8List?>> blurPreview({
    required String path,
    required double time,
    required Rect rect,
    required BlurStyle style,
    bool text = false,
  }) async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('blurPreview', {
        'path': path,
        'time': time,
        'style': style.wire,
        'text': text,
        'rect': {'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height},
      });
      return [for (final e in raw ?? const <Object?>[]) e is Uint8List ? e : null];
    } on PlatformException {
      return const [null, null, null];
    }
  }

  /// Batch-generate small JPEG thumbnails, one per request, in the same order.
  /// A `null` entry means that frame failed to generate — never throws for
  /// individual failures, only for a channel-level problem.
  Future<List<Uint8List?>> thumbnails(List<ThumbRequest> requests) async {
    if (requests.isEmpty) return const [];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('thumbnails', {
        'requests': requests.map((r) => r.toMap()).toList(),
      });
      if (raw == null) return List.filled(requests.length, null);
      return raw.map((e) => e is Uint8List ? e : null).toList();
    } on PlatformException {
      return List.filled(requests.length, null);
    }
  }

  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // best-effort
    }
  }
}
