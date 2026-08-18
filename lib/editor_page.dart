import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import 'clip.dart';
import 'editor_model.dart';
import 'export_service.dart';
import 'timeline.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final EditorModel _model = EditorModel();
  final ExportService _exporter = ExportService();

  final List<Clip> _clips = [];
  VideoPlayerController? _video;
  String? _previewTemp;

  // Render serialization — never run two native sessions at once.
  bool _rendering = false;
  bool _renderDirty = false;

  Duration _playhead = Duration.zero; // source time
  bool _playing = false;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModel);
  }

  void _onModel() => setState(() {});

  void _onVideoTick() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    if (mounted) {
      setState(() {
        _playhead = _outputToSource(v.value.position);
        _playing = v.value.isPlaying;
      });
    }
  }

  @override
  void dispose() {
    _model.removeListener(_onModel);
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    _deleteTempFile(_previewTemp);
    super.dispose();
  }

  // ---------- Clip list ----------

  Future<void> _addClips() async {
    const media = [
      'mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm',
      'mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg',
    ];
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: [...media, ...media.map((e) => e.toUpperCase())],
    );
    if (result == null || result.files.isEmpty) return;

    setState(() => _status = 'Loading…');
    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      _clips.add(Clip(path: path, duration: await _exporter.probeDuration(path)));
    }
    _resetTimelineForClips();
    await _requestRender();
  }

  void _removeClip(Clip clip) {
    setState(() => _clips.removeWhere((c) => c.id == clip.id));
    _resetTimelineForClips();
    _requestRender();
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      _clips.insert(newIndex, _clips.removeAt(oldIndex));
    });
    _resetTimelineForClips();
    _requestRender();
  }

  /// Rebuild the source timeline (total = sum of clip durations) and seed a cut
  /// point at each clip boundary. Resets prior edits (they no longer apply).
  void _resetTimelineForClips() {
    if (_clips.isEmpty) {
      _model.clear();
      return;
    }
    final total = _clips.fold(Duration.zero, (a, c) => a + c.duration);
    _model.setTimeline(total);
    var acc = Duration.zero;
    for (var i = 0; i < _clips.length - 1; i++) {
      acc += _clips[i].duration;
      _model.addPoint(acc); // boundary between clip i and i+1
    }
  }

  // ---------- Clip ⇄ source-time layout ----------

  /// Source-time start of each clip.
  List<Duration> get _clipStarts {
    final starts = <Duration>[];
    var acc = Duration.zero;
    for (final c in _clips) {
      starts.add(acc);
      acc += c.duration;
    }
    return starts;
  }

  /// Split a source-time span into per-clip pieces (clipIndex, inStart, inEnd).
  List<({int clip, Duration inStart, Duration inEnd})> _splitAtClips(
      Duration start, Duration end) {
    final starts = _clipStarts;
    final out = <({int clip, Duration inStart, Duration inEnd})>[];
    for (var i = 0; i < _clips.length; i++) {
      final off = starts[i];
      final clipEnd = off + _clips[i].duration;
      final a = start > off ? start : off;
      final b = end < clipEnd ? end : clipEnd;
      if (b > a) {
        out.add((clip: i, inStart: a - off, inEnd: b - off));
      }
    }
    return out;
  }

  /// The pieces that make up the output: kept segments split per clip, with a
  /// crossfade attached at the join after each kept segment.
  List<RenderPiece> _buildPieces() {
    final kept = _model.keptSegments;
    final pieces = <RenderPiece>[];
    for (var k = 0; k < kept.length; k++) {
      final seg = kept[k];
      final subs = _splitAtClips(seg.start, seg.end);
      final t = _model.transitionAt(seg.end);
      for (var j = 0; j < subs.length; j++) {
        final isLastSub = j == subs.length - 1;
        final active = isLastSub && k < kept.length - 1 && t.isActive;
        pieces.add(RenderPiece(
          path: _clips[subs[j].clip].path,
          start: subs[j].inStart.inMicroseconds / 1e6,
          end: subs[j].inEnd.inMicroseconds / 1e6,
          crossfade: active ? t.duration.inMicroseconds / 1e6 : 0.0,
          type: active ? t.type.wire : 'none',
        ));
      }
    }
    return pieces;
  }

  // ---------- Rendering (preview == output) ----------

  /// True when the current edit is just a single whole clip — no combine/cut/
  /// fade needed, so we can play the original file directly (no re-encode).
  bool get _isTrivialSingleClip {
    if (_clips.length != 1) return false;
    final kept = _model.keptSegments;
    if (kept.length != 1) return false;
    if (_model.transitionAt(kept.first.end).isActive) return false;
    return kept.first.start == Duration.zero && kept.first.end == _model.total;
  }

  Future<void> _requestRender() async {
    if (_rendering) {
      _renderDirty = true;
      return;
    }
    _rendering = true;
    try {
      do {
        _renderDirty = false;
        await _renderOnce();
      } while (_renderDirty && mounted && _clips.isNotEmpty);
    } finally {
      _rendering = false;
    }
  }

  Future<void> _renderOnce() async {
    final old = _video;
    old?.removeListener(_onVideoTick);
    final oldTemp = _previewTemp;
    final sourcePlayhead = _playhead;

    if (_clips.isEmpty) {
      setState(() {
        _video = null;
        _previewTemp = null;
        _status = null;
        _playing = false;
        _playhead = Duration.zero;
      });
      await old?.dispose();
      _deleteTempFile(oldTemp);
      return;
    }

    String sourcePath;
    String? newTemp;

    if (_isTrivialSingleClip) {
      sourcePath = _clips.first.path;
    } else {
      newTemp = _newTempPath();
      setState(() => _status = 'Rendering preview…');
      try {
        await _exporter.render(
          pieces: _buildPieces(),
          outputPath: newTemp,
          onProgress: (pr) {
            if (mounted) {
              setState(() => _status = 'Rendering preview… ${(pr * 100).round()}%');
            }
          },
        );
      } on ExportException catch (e) {
        _deleteTempFile(newTemp);
        if (mounted) setState(() => _status = null);
        _showError('Couldn\'t build the preview:\n${e.message}');
        return;
      }
      sourcePath = newTemp;
    }

    final controller = VideoPlayerController.file(File(sourcePath));
    try {
      await controller.initialize().timeout(const Duration(seconds: 30));
    } catch (e) {
      await controller.dispose();
      _deleteTempFile(newTemp);
      if (mounted) setState(() => _status = null);
      _showError('Couldn\'t open the preview:\n$e');
      return;
    }

    controller.addListener(_onVideoTick);
    setState(() {
      _video = controller;
      _previewTemp = newTemp;
      _playing = false;
      _status = null;
    });
    // Keep the playhead roughly where it was.
    final resumeOut = _sourceToOutput(sourcePlayhead);
    if (resumeOut > Duration.zero && resumeOut < controller.value.duration) {
      await controller.seekTo(resumeOut);
      setState(() => _playhead = sourcePlayhead);
    } else {
      setState(() => _playhead = Duration.zero);
    }

    await old?.dispose();
    if (oldTemp != null && oldTemp != sourcePath) _deleteTempFile(oldTemp);
  }

  String _newTempPath() => p.join(Directory.systemTemp.path,
      'videoz_preview_${DateTime.now().microsecondsSinceEpoch}.mov');

  void _deleteTempFile(String? path) {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ---------- Source ⇄ output time mapping ----------

  /// Output layout of the kept segments: (outStart, len, srcStart, srcEnd).
  List<({Duration oStart, Duration len, Duration sStart, Duration sEnd})>
      _layout() {
    final kept = _model.keptSegments;
    final rows =
        <({Duration oStart, Duration len, Duration sStart, Duration sEnd})>[];
    var oStart = Duration.zero;
    for (var i = 0; i < kept.length; i++) {
      final len = kept[i].length;
      rows.add((oStart: oStart, len: len, sStart: kept[i].start, sEnd: kept[i].end));
      // subtract the crossfade into the next segment
      var cf = _model.transitionAt(kept[i].end).duration;
      if (i < kept.length - 1) {
        final half = len < kept[i + 1].length ? len : kept[i + 1].length;
        if (cf > half * 0.5) cf = half * 0.5;
        oStart = oStart + len - cf;
      }
    }
    return rows;
  }

  Duration _outputToSource(Duration op) {
    final rows = _layout();
    for (final r in rows) {
      if (op >= r.oStart && op <= r.oStart + r.len) {
        return r.sStart + (op - r.oStart);
      }
    }
    return rows.isEmpty ? Duration.zero : rows.last.sEnd;
  }

  Duration _sourceToOutput(Duration sp) {
    final rows = _layout();
    for (final r in rows) {
      if (sp >= r.sStart && sp < r.sEnd) {
        return r.oStart + (sp - r.sStart);
      }
    }
    // In a removed gap: snap to the next kept segment's start.
    for (final r in rows) {
      if (r.sStart >= sp) return r.oStart;
    }
    return Duration.zero;
  }

  // ---------- Playback / editing ----------

  Future<void> _togglePlay() async {
    final v = _video;
    if (v == null) return;
    if (v.value.isPlaying) {
      await v.pause();
    } else {
      if (v.value.position >=
          v.value.duration - const Duration(milliseconds: 60)) {
        await v.seekTo(Duration.zero);
      }
      await v.play();
    }
  }

  void _addPointAtPlayhead() => _model.addPoint(_playhead);

  Future<void> _seek(Duration sourceTime) async {
    final v = _video;
    if (v == null) return;
    setState(() => _playhead = sourceTime);
    await v.seekTo(_sourceToOutput(sourceTime));
  }

  void _toggleSegment(Segment seg) {
    _model.setSegmentRemoved(seg, !seg.removed);
    _requestRender();
  }

  Future<void> _editTransition(Duration point) async {
    final choice = await showDialog<Transition>(
      context: context,
      builder: (_) => _TransitionDialog(current: _model.transitionAt(point)),
    );
    if (choice != null) {
      _model.setTransition(point, choice);
      await _requestRender();
    }
  }

  Future<void> _apply() async {
    if (!_model.hasContent) return;
    final kept = _model.keptSegments;
    if (kept.isEmpty) {
      _showError('Every segment is X\'d out — nothing to write.');
      return;
    }

    final ref = _clips.first.path;
    final base = p.basenameWithoutExtension(ref);
    final ext = _clips.length > 1 ? '.mov' : p.extension(ref);
    final outPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save edited file as',
      fileName: '$base-edited$ext',
      initialDirectory: p.dirname(ref),
    );
    if (outPath == null) return;

    setState(() {
      _busy = true;
      _status = 'Exporting… 0%';
    });
    try {
      await _exporter.render(
        pieces: _buildPieces(),
        outputPath: outPath,
        onProgress: (pr) {
          if (mounted) {
            setState(() => _status = 'Exporting… ${(pr * 100).round()}%');
          }
        },
      );
      if (mounted) {
        setState(() => _status = null);
        _showDone(outPath);
      }
    } on ExportException catch (e) {
      if (mounted) setState(() => _status = null);
      _showError(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Something went wrong'),
        content: SingleChildScrollView(child: Text(msg)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  void _showDone(String path) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Wrote ${p.basename(path)}'),
      duration: const Duration(seconds: 4),
    ));
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset('assets/videoz.png',
                  width: 45, height: 45, fit: BoxFit.cover),
            ),
            const SizedBox(width: 10),
            const Text('Videoz'),
          ],
        ),
        actions: [
          if (_model.hasContent)
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
      body: Row(
        children: [
          _ClipSidebar(
            clips: _clips,
            busy: _busy,
            onAdd: _addClips,
            onRemove: _removeClip,
            onReorder: _reorder,
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    color: Colors.black,
                    alignment: Alignment.center,
                    child: (v != null && v.value.isInitialized)
                        ? AspectRatio(
                            aspectRatio: v.value.aspectRatio == 0
                                ? 16 / 9
                                : v.value.aspectRatio,
                            child: VideoPlayer(v),
                          )
                        : _EmptyState(onPick: _addClips),
                  ),
                ),
                Material(
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Toolbar(
                          hasContent: _model.hasContent,
                          playing: _playing,
                          busy: _busy,
                          playhead: _playhead,
                          total: _model.total,
                          onPlayPause: _togglePlay,
                          onAddPoint: _addPointAtPlayhead,
                          onClearPoints: () {
                            _model.clearPoints();
                            _requestRender();
                          },
                          onApply: _apply,
                          canApply: _model.hasContent && !_busy && !_rendering,
                          pointCount: _model.points.length,
                        ),
                        const SizedBox(height: 10),
                        Timeline(
                          model: _model,
                          clips: _clips,
                          exporter: _exporter,
                          playhead: _playhead,
                          onSeek: _seek,
                          onToggleSegment: _toggleSegment,
                          onTransitionTap: _editTransition,
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
          ),
        ],
      ),
    );
  }
}

/// Combined transition picker — type and duration in one popup.
class _TransitionDialog extends StatefulWidget {
  const _TransitionDialog({required this.current});
  final Transition current;

  @override
  State<_TransitionDialog> createState() => _TransitionDialogState();
}

class _TransitionDialogState extends State<_TransitionDialog> {
  late TransitionType _type = widget.current.type;
  late Duration _duration = widget.current.duration > Duration.zero
      ? widget.current.duration
      : const Duration(milliseconds: 500);

  static const _durations = <Duration>[
    Duration(milliseconds: 300),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
  ];

  String _durLabel(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  Widget build(BuildContext context) {
    final needsDuration = _type != TransitionType.none;
    return AlertDialog(
      title: const Text('Transition at this join'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Type'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final t in TransitionType.values)
                ChoiceChip(
                  label: Text(t.label),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Opacity(
            opacity: needsDuration ? 1 : 0.4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Duration'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final d in _durations)
                      ChoiceChip(
                        label: Text(_durLabel(d)),
                        selected: _duration == d,
                        onSelected: needsDuration
                            ? (_) => setState(() => _duration = d)
                            : null,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _type == TransitionType.none
                ? Transition.none
                : Transition(_type, _duration),
          ),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _ClipSidebar extends StatelessWidget {
  const _ClipSidebar({
    required this.clips,
    required this.busy,
    required this.onAdd,
    required this.onRemove,
    required this.onReorder,
  });

  final List<Clip> clips;
  final bool busy;
  final VoidCallback onAdd;
  final void Function(Clip) onRemove;
  final void Function(int, int) onReorder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 248,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 6),
            child: Row(
              children: [
                Text('Clips (${clips.length})',
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  onPressed: busy ? null : onAdd,
                  icon: const Icon(Icons.add),
                  tooltip: 'Add clip(s)',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          if (clips.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No clips yet.\nAdd one or more videos —\nthey play in order.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: clips.length,
                onReorder: onReorder,
                itemBuilder: (context, i) {
                  final clip = clips[i];
                  return Card(
                    key: ValueKey(clip.id),
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 10, right: 4),
                      leading: CircleAvatar(
                        radius: 12,
                        backgroundColor: scheme.primaryContainer,
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onPrimaryContainer)),
                      ),
                      title: Text(clip.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_fmt(clip.duration)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: 'Remove',
                            visualDensity: VisualDensity.compact,
                            onPressed: busy ? null : () => onRemove(clip),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.drag_handle, size: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.hasContent,
    required this.playing,
    required this.busy,
    required this.playhead,
    required this.total,
    required this.onPlayPause,
    required this.onAddPoint,
    required this.onClearPoints,
    required this.onApply,
    required this.canApply,
    required this.pointCount,
  });

  final bool hasContent;
  final bool playing;
  final bool busy;
  final Duration playhead;
  final Duration total;
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
        IconButton.filledTonal(
          onPressed: hasContent ? onPlayPause : null,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          tooltip: playing ? 'Pause' : 'Play',
        ),
        FilledButton.icon(
          onPressed: hasContent ? onAddPoint : null,
          icon: const Icon(Icons.add_location_alt),
          label: const Text('Mark point'),
        ),
        TextButton.icon(
          onPressed: (hasContent && pointCount > 0) ? onClearPoints : null,
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
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
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
        const Text('No clips loaded',
            style: TextStyle(color: Colors.white70, fontSize: 18)),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.folder_open),
          label: const Text('Add video or audio files'),
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
