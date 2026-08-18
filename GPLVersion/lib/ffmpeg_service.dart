import 'dart:io';

import 'editor_model.dart';

/// Result of probing a media file for its stream layout.
class MediaStreams {
  const MediaStreams({required this.hasVideo, required this.hasAudio});
  final bool hasVideo;
  final bool hasAudio;
}

class ExportException implements Exception {
  ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thin wrapper around the system `ffmpeg` / `ffprobe` binaries.
class FfmpegService {
  FfmpegService({String? ffmpegPath, String? ffprobePath})
      : ffmpeg = ffmpegPath ?? _resolve('ffmpeg'),
        ffprobe = ffprobePath ?? _resolve('ffprobe');

  final String ffmpeg;
  final String ffprobe;

  /// Look in the common Homebrew locations first, then fall back to bare name
  /// (resolved via PATH). GUI apps on macOS don't inherit a login shell PATH,
  /// so the absolute paths matter.
  static String _resolve(String tool) {
    for (final p in ['/opt/homebrew/bin/$tool', '/usr/local/bin/$tool']) {
      if (File(p).existsSync()) return p;
    }
    return tool;
  }

  Future<bool> isAvailable() async {
    try {
      final r = await Process.run(ffmpeg, ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<MediaStreams> probe(String path) async {
    Future<bool> hasStream(String type) async {
      final r = await Process.run(ffprobe, [
        '-v', 'error',
        '-select_streams', type,
        '-show_entries', 'stream=index',
        '-of', 'csv=p=0',
        path,
      ]);
      return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
    }

    return MediaStreams(
      hasVideo: await hasStream('v'),
      hasAudio: await hasStream('a'),
    );
  }

  Future<Duration?> duration(String path) async {
    final r = await Process.run(ffprobe, [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'csv=p=0',
      path,
    ]);
    if (r.exitCode != 0) return null;
    final secs = double.tryParse((r.stdout as String).trim());
    if (secs == null) return null;
    return Duration(microseconds: (secs * 1e6).round());
  }

  static String _fmt(Duration d) =>
      (d.inMicroseconds / 1e6).toStringAsFixed(3);

  /// Concatenate [kept] segments of [inputPath] into [outputPath], re-encoding
  /// so cuts are frame-accurate regardless of keyframe placement.
  Future<void> export({
    required String inputPath,
    required String outputPath,
    required List<Segment> kept,
    required MediaStreams streams,
    void Function(String line)? onLog,
  }) async {
    if (kept.isEmpty) {
      throw ExportException('Nothing to export — every segment is X\'d out.');
    }

    final filters = <String>[];
    final concatInputs = <String>[];

    for (var i = 0; i < kept.length; i++) {
      final s = kept[i];
      final start = _fmt(s.start);
      final end = _fmt(s.end);
      if (streams.hasVideo) {
        filters.add(
            '[0:v]trim=start=$start:end=$end,setpts=PTS-STARTPTS[v$i]');
        concatInputs.add('[v$i]');
      }
      if (streams.hasAudio) {
        filters.add(
            '[0:a]atrim=start=$start:end=$end,asetpts=PTS-STARTPTS[a$i]');
        concatInputs.add('[a$i]');
      }
    }

    final v = streams.hasVideo ? 1 : 0;
    final a = streams.hasAudio ? 1 : 0;
    final maps = <String>[];
    if (streams.hasVideo) maps.addAll(['-map', '[outv]']);
    if (streams.hasAudio) maps.addAll(['-map', '[outa]']);

    final outLabels = <String>[];
    if (streams.hasVideo) outLabels.add('[outv]');
    if (streams.hasAudio) outLabels.add('[outa]');

    filters.add(
        '${concatInputs.join()}concat=n=${kept.length}:v=$v:a=$a${outLabels.join()}');

    // Pin output codecs so any input (ProRes, 10-bit HEVC from an iPhone, etc.)
    // yields one widely-compatible H.264/AAC file. Re-encoding is required
    // anyway for frame-accurate cuts, so being explicit costs us nothing.
    final encodeArgs = <String>[];
    if (streams.hasVideo) {
      encodeArgs.addAll([
        '-c:v', 'libx264',
        '-preset', 'medium',
        '-crf', '18',
        '-pix_fmt', 'yuv420p',
      ]);
    }
    if (streams.hasAudio) {
      encodeArgs.addAll(['-c:a', 'aac', '-b:a', '192k']);
    }
    // faststart helps .mp4/.mov play back / stream cleanly.
    final ext = outputPath.toLowerCase();
    if (ext.endsWith('.mp4') || ext.endsWith('.mov') || ext.endsWith('.m4v')) {
      encodeArgs.addAll(['-movflags', '+faststart']);
    }

    final args = <String>[
      '-y',
      '-i', inputPath,
      '-filter_complex', filters.join(';'),
      ...maps,
      ...encodeArgs,
      outputPath,
    ];

    onLog?.call('ffmpeg ${args.join(' ')}');

    final process = await Process.start(ffmpeg, args);
    final errBuf = StringBuffer();
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((chunk) {
      errBuf.write(chunk);
      onLog?.call(chunk.trimRight());
    });

    final code = await process.exitCode;
    if (code != 0) {
      throw ExportException(
          'ffmpeg exited with code $code.\n${errBuf.toString().split('\n').reversed.take(6).toList().reversed.join('\n')}');
    }
  }
}
