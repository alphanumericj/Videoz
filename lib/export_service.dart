import 'package:flutter/services.dart';

/// A single filmstrip-thumbnail request: [time] seconds into the file at [path].
class ThumbRequest {
  const ThumbRequest({required this.path, required this.time});
  final String path;
  final double time;

  Map<String, dynamic> toMap() => {'path': path, 'time': time};
}

class ExportException implements Exception {
  ExportException(this.message);
  final String message;
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
  });

  final String path;
  final double start;
  final double end;
  final double crossfade;
  final String type; // transition into the next piece

  Map<String, dynamic> toMap() => {
        'path': path,
        'start': start,
        'end': end,
        'cfAfter': crossfade,
        'type': type,
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
      });
    } on PlatformException catch (e) {
      throw ExportException(e.message ?? 'Render failed (${e.code}).');
    } finally {
      _onProgress = null;
    }
  }

  /// Duration of a media file, measured natively (no video-player controller).
  Future<Duration> probeDuration(String path) async {
    try {
      final secs = await _channel.invokeMethod<double>('probe', {'path': path});
      return Duration(microseconds: ((secs ?? 0) * 1e6).round());
    } on PlatformException {
      return Duration.zero;
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
