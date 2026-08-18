import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'editor_model.dart';
import 'ffmpeg_service.dart';
import 'timeline.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final EditorModel _model = EditorModel();
  final FfmpegService _ffmpeg = FfmpegService();

  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  final List<StreamSubscription> _subs = [];

  Duration _playhead = Duration.zero;
  bool _playing = false;
  bool _exporting = false;
  String? _status;
  bool _ffmpegOk = true;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModel);
    _subs.add(_player.stream.position.listen((pos) {
      if (mounted) setState(() => _playhead = pos);
    }));
    _subs.add(_player.stream.duration.listen((dur) {
      if (dur > Duration.zero) _model.setTotal(dur);
    }));
    _subs.add(_player.stream.playing.listen((pl) {
      if (mounted) setState(() => _playing = pl);
    }));
    _ffmpeg.isAvailable().then((ok) {
      if (mounted) setState(() => _ffmpegOk = ok);
    });
  }

  void _onModel() => setState(() {});

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _model.removeListener(_onModel);
    _player.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    const media = [
      'mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm', // video
      'mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg', // audio
    ];
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      // macOS matches these case-sensitively, and camera/phone files are often
      // uppercase (IMG_1234.MOV), so include both cases.
      allowedExtensions: [
        ...media,
        ...media.map((e) => e.toUpperCase()),
      ],
    );
    final path = result?.files.single.path;
    if (path == null) return;

    setState(() => _status = 'Loading…');
    // Probe duration up front so the timeline is usable immediately.
    final probed = await _ffmpeg.duration(path);
    _model.loadFile(path, probed ?? Duration.zero);
    await _player.open(Media(path), play: false);
    setState(() => _status = null);
  }

  Future<void> _togglePlay() async {
    await _player.playOrPause();
  }

  void _addPointAtPlayhead() {
    _model.addPoint(_playhead);
  }

  Future<void> _seek(Duration to) async {
    setState(() => _playhead = to);
    await _player.seek(to);
  }

  Future<void> _apply() async {
    final input = _model.filePath;
    if (input == null) return;

    final kept = _model.keptSegments;
    if (kept.isEmpty) {
      _showError('Every segment is X\'d out — nothing to write.');
      return;
    }

    final dir = p.dirname(input);
    final base = p.basenameWithoutExtension(input);
    final ext = p.extension(input);
    final suggested = '$base-edited$ext';

    final outPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save edited file as',
      fileName: suggested,
      initialDirectory: dir,
    );
    if (outPath == null) return;

    setState(() {
      _exporting = true;
      _status = 'Exporting…';
    });

    try {
      final streams = await _ffmpeg.probe(input);
      await _ffmpeg.export(
        inputPath: input,
        outputPath: outPath,
        kept: kept,
        streams: streams,
        onLog: (line) {
          // Surface the current ffmpeg time as coarse progress.
          if (mounted && line.contains('time=')) {
            setState(() => _status = 'Exporting… ${_extractTime(line)}');
          }
        },
      );
      if (mounted) {
        setState(() => _status = null);
        _showDone(outPath);
      }
    } on ExportException catch (e) {
      if (mounted) {
        setState(() => _status = null);
        _showError(e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = null);
        _showError('$e');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _extractTime(String line) {
    final m = RegExp(r'time=(\S+)').firstMatch(line);
    return m?.group(1) ?? '';
  }

  void _showError(String msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Couldn\'t export'),
        content: SingleChildScrollView(child: Text(msg)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showDone(String path) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Wrote ${p.basename(path)}'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Videoz'),
        actions: [
          if (_model.hasFile)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  'Keeping ${_fmt(_model.keptDuration)} of ${_fmt(_model.total)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!_ffmpegOk)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(8),
              child: const Text(
                'ffmpeg was not found. Install it with:  brew install ffmpeg',
                style: TextStyle(color: Colors.black87),
              ),
            ),
          // ----- Video area -----
          Expanded(
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: _model.hasFile
                  ? Video(controller: _controller)
                  : _EmptyState(onPick: _pickFile),
            ),
          ),
          // ----- Controls + timeline -----
          Material(
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Toolbar(
                    hasFile: _model.hasFile,
                    playing: _playing,
                    exporting: _exporting,
                    playhead: _playhead,
                    total: _model.total,
                    onOpen: _pickFile,
                    onPlayPause: _togglePlay,
                    onAddPoint: _addPointAtPlayhead,
                    onClearPoints: _model.clearPoints,
                    onApply: _apply,
                    canApply: _model.hasFile && !_exporting,
                    pointCount: _model.points.length,
                  ),
                  const SizedBox(height: 10),
                  Timeline(
                    model: _model,
                    playhead: _playhead,
                    onSeek: _seek,
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Text(_status!),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.hasFile,
    required this.playing,
    required this.exporting,
    required this.playhead,
    required this.total,
    required this.onOpen,
    required this.onPlayPause,
    required this.onAddPoint,
    required this.onClearPoints,
    required this.onApply,
    required this.canApply,
    required this.pointCount,
  });

  final bool hasFile;
  final bool playing;
  final bool exporting;
  final Duration playhead;
  final Duration total;
  final VoidCallback onOpen;
  final VoidCallback onPlayPause;
  final VoidCallback onAddPoint;
  final VoidCallback onClearPoints;
  final VoidCallback onApply;
  final bool canApply;
  final int pointCount;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.tonalIcon(
          onPressed: onOpen,
          icon: const Icon(Icons.folder_open),
          label: const Text('Open…'),
        ),
        IconButton.filledTonal(
          onPressed: hasFile ? onPlayPause : null,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          tooltip: playing ? 'Pause' : 'Play',
        ),
        FilledButton.icon(
          onPressed: hasFile ? onAddPoint : null,
          icon: const Icon(Icons.add_location_alt),
          label: const Text('Mark point'),
        ),
        TextButton.icon(
          onPressed: (hasFile && pointCount > 0) ? onClearPoints : null,
          icon: const Icon(Icons.clear_all),
          label: Text('Clear points${pointCount > 0 ? ' ($pointCount)' : ''}'),
        ),
        const SizedBox(width: 8),
        Text(
          '${_fmt(playhead)} / ${_fmt(total)}',
          style: const TextStyle(
            fontFeatures: [FontFeature.tabularFigures()],
            fontSize: 13,
          ),
        ),
        const Spacer(),
        FilledButton.icon(
          onPressed: canApply ? onApply : null,
          icon: exporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_alt),
          label: const Text('Apply & Save…'),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.movie_creation_outlined,
            size: 72, color: Colors.white38),
        const SizedBox(height: 16),
        const Text(
          'No file loaded',
          style: TextStyle(color: Colors.white70, fontSize: 18),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.folder_open),
          label: const Text('Open a video or audio file'),
        ),
      ],
    );
  }
}

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
