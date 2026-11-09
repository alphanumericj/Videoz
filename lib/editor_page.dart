import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import 'blur_dialog.dart';
import 'blur_overlay.dart';
import 'blur_region.dart';
import 'clip.dart';
import 'editor_model.dart';
import 'export_dialog.dart';
import 'export_service.dart';
import 'export_settings.dart';
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
  final List<BlurRegion> _blurs = [];
  _BlurDraw? _draw; // set while the user is drawing (or fixing) a blur box
  BlurLook _lastLook = const BlurLook(BlurStyle.pixelate, PixelScale.medium);
  bool _searching = false; // a text search is running (and can be cancelled)
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
      final info = await _exporter.probeInfo(path);
      _clips.add(Clip(path: path, duration: info.duration, displaySize: info.size));
    }
    _resetTimelineForClips();
    await _requestRender();
  }

  void _removeClip(Clip clip) {
    setState(() {
      _clips.removeWhere((c) => c.id == clip.id);
      _blurs.removeWhere((b) => b.clipId == clip.id);
    });
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
          clipId: _clips[subs[j].clip].id.toString(),
        ));
      }
    }
    return pieces;
  }

  // ---------- Rendering (preview == output) ----------

  /// True when the current edit is just a single whole clip — no combine/cut/
  /// fade needed, so we can play the original file directly (no re-encode).
  bool get _isTrivialSingleClip {
    // Blurred video must be re-rendered; copying the file would keep the original pixels.
    if (_blurs.isNotEmpty) return false;
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
          blurs: _blurs,
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

    final unsure = _blurs.where((b) => b.unsureSpans.isNotEmpty).length;
    if (unsure > 0) {
      final go = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Check the red stretches first'),
          content: Text(
            unsure == 1
                ? 'One blur has a stretch (red on the timeline) where the tracker lost '
                    'what it was following. There the box stays at its last known spot, so '
                    'the object may show. Scrub through it, and use right-click, "Fix box '
                    'on this frame", where it is off.'
                : '$unsure blurs have stretches (red on the timeline) where the tracker '
                    'lost what it was following. There the box stays at its last known '
                    'spot, so the object may show. Scrub through them, and use right-click, '
                    '"Fix box on this frame", where a box is off.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Go back')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Export anyway')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }

    // One whole clip with no cuts or transitions: "no compression" can convert
    // by copying the video into the new container instead of re-encoding it.
    final convertOnly = _isTrivialSingleClip;
    final settings = await showDialog<ExportSettings>(
      context: context,
      builder: (_) => ExportDialog(canConvertOnly: convertOnly),
    );
    if (settings == null) return;

    final ref = _clips.first.path;
    final ext = settings.format.extension;
    final copyOnly = convertOnly && settings.compression == Compression.none;
    // A pure format change keeps the name; anything else gets "-edited" so it
    // can't be mistaken for (or overwrite) the original.
    final sameFormat = p.extension(ref).toLowerCase() == '.$ext';
    final base = p.basenameWithoutExtension(ref);
    final suggested = (copyOnly && !sameFormat) ? '$base.$ext' : '$base-edited.$ext';

    var outPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save as ${settings.format.label}',
      fileName: suggested,
      initialDirectory: p.dirname(ref),
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (outPath == null) return;
    // The extension decides the container, so make it match the chosen format.
    final typed = p.extension(outPath).toLowerCase();
    if (typed != '.$ext') {
      outPath = const ['.mp4', '.mov', '.m4v'].contains(typed)
          ? p.setExtension(outPath, '.$ext')
          : '$outPath.$ext';
    }

    void onProgress(double pr) {
      if (mounted) setState(() => _status = 'Exporting… ${(pr * 100).round()}%');
    }

    setState(() {
      _busy = true;
      _status = copyOnly ? 'Converting…' : 'Exporting… 0%';
    });
    try {
      var done = false;
      if (copyOnly) {
        try {
          await _exporter.remux(
              inputPath: ref, outputPath: outPath, onProgress: onProgress);
          done = true;
        } on ExportException {
          // Can't be copied as-is (ProRes into an .mp4, say): re-encode below.
          if (mounted) setState(() => _status = 'Exporting… 0%');
        }
      }
      if (!done) {
        await _exporter.render(
          pieces: _buildPieces(),
          outputPath: outPath,
          compression: settings.compression,
          blurs: _blurs,
          onProgress: onProgress,
        );
      }
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
    var size = '';
    try {
      size = ' (${_fmtSize(File(path).lengthSync())})';
    } catch (_) {}
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Wrote ${p.basename(path)}$size'
          '${_blurs.isEmpty ? '' : '. Watch the blurred parts through before sharing it.'}'),
      duration: const Duration(seconds: 8),
    ));
  }

  // ---------- Blur ----------

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Clip? _clipAt(Duration source) {
    if (_clips.isEmpty) return null;
    final starts = _clipStarts;
    for (var i = 0; i < _clips.length; i++) {
      if (source < starts[i] + _clips[i].duration) return _clips[i];
    }
    return _clips.last;
  }

  Duration _clipStart(Clip clip) {
    final i = _clips.indexWhere((c) => c.id == clip.id);
    return i < 0 ? Duration.zero : _clipStarts[i];
  }

  double _localSeconds(Clip clip, Duration source) =>
      (source - _clipStart(clip)).inMicroseconds / 1e6;

  /// Maps between the preview canvas and a clip's own frame; null until the
  /// preview is loaded and the clip's size is known.
  FrameMapper? _mapperFor(Clip clip) {
    final v = _video;
    final size = clip.displaySize;
    if (v == null || !v.value.isInitialized || size == null) return null;
    final canvas = v.value.size;
    if (canvas.width <= 0 || canvas.height <= 0) return null;
    return FrameMapper(canvas: canvas, clip: size);
  }

  /// Begin a new blur: the stretch between the two marks around the playhead is
  /// the range, and the box is drawn on the frame showing now.
  Future<void> _startBlur({bool text = false}) async {
    final v = _video;
    if (v == null || !v.value.isInitialized || _draw != null) return;
    await v.pause();
    final t = _playhead;
    Segment? seg;
    for (final s in _model.segments) {
      if (t >= s.start && t < s.end) {
        seg = s;
        break;
      }
    }
    seg ??= _model.segments.isEmpty ? null : _model.segments.last;
    if (seg == null) return;
    if (seg.removed) {
      _snack('That part is X\'d out. Move the playhead into a kept segment first.');
      return;
    }
    final clip = _clipAt(seg.start);
    if (clip == null || clip.displaySize == null) {
      _snack('This file has no video to blur.');
      return;
    }
    final clipStart = _clipStart(clip);
    final startLocal = (seg.start - clipStart).inMicroseconds / 1e6;
    final endLocal = (seg.end - clipStart).inMicroseconds / 1e6;
    final anchor = _localSeconds(clip, t).clamp(startLocal, endLocal).toDouble();
    setState(() => _draw = _BlurDraw(
          clip: clip, anchor: anchor, rangeStart: startLocal, rangeEnd: endLocal, text: text));
  }

  /// Re-draw one blur's box on the frame showing now (after a right-click).
  Future<void> _startFix(BlurRegion r) async {
    final v = _video;
    if (v == null || !v.value.isInitialized || _draw != null) return;
    await v.pause();
    final clip = _clipAt(_playhead);
    final local = clip == null ? 0.0 : _localSeconds(clip, _playhead);
    if (clip == null || clip.id != r.clipId || !r.contains(local)) {
      _snack('Move the playhead onto a frame where this blur is active, then try again.');
      return;
    }
    setState(() => _draw = _BlurDraw(
          clip: clip,
          anchor: local.clamp(r.start, r.end).toDouble(),
          rangeStart: r.start,
          rangeEnd: r.end,
          fixing: r));
  }

  void _cancelDraw() {
    if (_draw != null) setState(() => _draw = null);
  }

  Future<void> _onBoxDrawn(Rect canvasNorm) async {
    final d = _draw;
    if (d == null) return;
    final mapper = _mapperFor(d.clip);
    if (mapper == null) {
      _cancelDraw();
      return;
    }
    final box = mapper.canvasToClip(canvasNorm);
    if (box.width < 0.01 || box.height < 0.01) return; // a stray click, not a box
    if (d.text) {
      await _textBoxDrawn(d, box);
      return;
    }
    if (d.fixing != null) {
      await _applyFix(d, box);
      return;
    }
    final look = await showDialog<BlurLook>(
      context: context,
      builder: (_) => BlurScaleDialog(
        exporter: _exporter,
        path: d.clip.path,
        time: d.anchor,
        rect: box,
        initial: _lastLook,
      ),
    );
    // Back (or clicking away) keeps drawing mode on so the box can be redone;
    // the banner's Cancel or Esc is what leaves it.
    if (look == null) return;
    _lastLook = look;
    await _trackNew(d, box, look);
  }

  /// A box was drawn around some text: confirm what it says and how pixelated,
  /// then search the marked stretch for every place it appears.
  Future<void> _textBoxDrawn(_BlurDraw d, Rect box) async {
    final choice = await showDialog<TextBlurChoice>(
      context: context,
      builder: (_) => TextBlurDialog(
        exporter: _exporter,
        path: d.clip.path,
        time: d.anchor,
        rect: box,
        initial: _lastLook,
      ),
    );
    if (choice == null) return; // Back: stay in drawing mode
    _lastLook = choice.look;
    await _searchText(d, box, choice);
  }

  Future<void> _searchText(_BlurDraw d, Rect box, TextBlurChoice choice) async {
    setState(() {
      _draw = null;
      _busy = true;
      _searching = true;
      _status = 'Searching for the text… 0%';
    });
    try {
      final found = await _exporter.findText(
        path: d.clip.path,
        phrases: choice.phrases,
        rangeStart: d.rangeStart,
        rangeEnd: d.rangeEnd,
        onProgress: (pr) {
          if (mounted) setState(() => _status = 'Searching for the text… ${(pr * 100).round()}%');
        },
      );
      if (found.hits.isEmpty) {
        _showError('That text wasn\'t found in any of the ${found.checked} frames read, so '
            'nothing was blurred. Check the spelling in the box, or pick a stretch where it '
            'is clearly on screen.');
      } else {
        // The frame you drew on is always covered, even if the reader missed it there.
        final hits = [...found.hits, TextHit(t: d.anchor, rects: [box])]
          ..sort((a, b) => a.t.compareTo(b.t));
        final region = BlurRegion(
          id: BlurRegion.nextId(),
          clipId: d.clip.id,
          start: d.rangeStart,
          end: d.rangeEnd,
          scale: choice.look.scale,
          style: choice.look.style,
          samples: const [],
          anchors: [d.anchor],
          kind: BlurKind.text,
          hits: hits,
          phrases: choice.phrases,
          checked: found.checked,
        );
        if (mounted) setState(() => _blurs.add(region));
        _snack('Found it in ${found.hits.length} of ${found.checked} frames read. Watch the '
            'stretch through: the bar under the timeline is solid where text was blurred.');
      }
    } on ExportException catch (e) {
      if (e.code != 'cancelled') _showError('Couldn\'t search for that text:\n${e.message}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _searching = false;
          _status = null;
        });
      }
    }
    _requestRender();
  }

  Future<void> _trackNew(_BlurDraw d, Rect box, BlurLook look) async {
    setState(() {
      _draw = null;
      _busy = true;
      _status = 'Tracking…';
    });
    try {
      final samples = await _exporter.track(
        path: d.clip.path,
        anchor: d.anchor,
        rect: box,
        rangeStart: d.rangeStart,
        rangeEnd: d.rangeEnd,
      );
      final region = BlurRegion(
        id: BlurRegion.nextId(),
        clipId: d.clip.id,
        start: d.rangeStart,
        end: d.rangeEnd,
        scale: look.scale,
        style: look.style,
        samples: samples,
        anchors: [d.anchor],
      );
      if (mounted) setState(() => _blurs.add(region));
      if (region.unsureSpans.isNotEmpty) {
        _snack('Tracking done. Red stretches on the timeline are where it was unsure: '
            'scrub through them.');
      }
    } on ExportException catch (e) {
      _showError('Couldn\'t track that:\n${e.message}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
    _requestRender();
  }

  /// Put the box where the user just drew it on this frame, and re-track
  /// between the nearest hand-placed frames on either side.
  Future<void> _applyFix(_BlurDraw d, Rect box) async {
    final r = d.fixing!;
    setState(() {
      _draw = null;
      _busy = true;
      _status = 'Tracking…';
    });
    try {
      final anchor = d.anchor;
      final others = r.anchors.where((a) => (a - anchor).abs() > 0.02).toList()..sort();
      double? prev, next;
      for (final a in others) {
        if (a < anchor) prev = a;
        if (a > anchor && next == null) next = a;
      }
      final fresh = await _exporter.track(
        path: d.clip.path,
        anchor: anchor,
        rect: box,
        rangeStart: prev ?? r.start,
        rangeEnd: next ?? r.end,
      );
      final kept = [
        for (final s in r.samples)
          if ((prev != null && s.t <= prev) || (next != null && s.t >= next)) s,
      ];
      final inside = [
        for (final s in fresh)
          if ((prev == null || s.t > prev) && (next == null || s.t < next)) s,
      ];
      r.samples = [...kept, ...inside]..sort((a, b) => a.t.compareTo(b.t));
      r.anchors = [...others, anchor]..sort();
      if (mounted) setState(() {});
    } on ExportException catch (e) {
      _showError('Couldn\'t track that:\n${e.message}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
    _requestRender();
  }

  void _removeBlur(BlurRegion r) {
    setState(() => _blurs.removeWhere((b) => b.id == r.id));
    _requestRender();
  }

  void _setLook(BlurRegion r, {BlurStyle? style, PixelScale? scale}) {
    setState(() {
      if (style != null) r.style = style;
      if (scale != null) r.scale = scale;
    });
    _lastLook = BlurLook(r.style, r.scale);
    _requestRender();
  }

  bool _isActiveNow(BlurRegion r) {
    final clip = _clipAt(_playhead);
    return clip != null && clip.id == r.clipId && r.contains(_localSeconds(clip, _playhead));
  }

  Future<void> _blurMenu(BlurRegion r, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          Rect.fromLTWH(global.dx, global.dy, 0, 0), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 'remove', child: Text('Remove blur')),
        if (r.kind == BlurKind.object && _isActiveNow(r))
          const PopupMenuItem(value: 'fix', child: Text('Fix box on this frame…')),
        const PopupMenuDivider(),
        for (final st in BlurStyle.values)
          PopupMenuItem(
            value: 'style:${st.wire}',
            child: Row(children: [
              SizedBox(width: 22, child: r.style == st ? const Icon(Icons.check, size: 18) : null),
              Text(st.label),
            ]),
          ),
        if (r.style.hasScale) ...[
          const PopupMenuDivider(),
          for (final s in PixelScale.values)
            PopupMenuItem(
              value: 'scale:${s.wire}',
              child: Row(children: [
                SizedBox(width: 22, child: r.scale == s ? const Icon(Icons.check, size: 18) : null),
                Text('Strength: ${r.style.labelFor(s)}'),
              ]),
            ),
        ],
      ],
    );
    if (choice == null) return;
    if (choice == 'remove') {
      _removeBlur(r);
    } else if (choice == 'fix') {
      await _startFix(r);
    } else if (choice.startsWith('style:')) {
      _setLook(r, style: BlurStyle.values.firstWhere((s) => s.wire == choice.substring(6)));
    } else if (choice.startsWith('scale:')) {
      _setLook(r, scale: PixelScale.values.firstWhere((s) => s.wire == choice.substring(6)));
    }
  }

  /// Right-click on the preview: if it's on a pixelated box, offer the menu.
  void _onVideoSecondaryTap(Offset canvasPoint, Offset global) {
    if (_draw != null) return;
    final clip = _clipAt(_playhead);
    final mapper = clip == null ? null : _mapperFor(clip);
    if (clip == null || mapper == null) return;
    final local = _localSeconds(clip, _playhead);
    BlurRegion? hit;
    var smallest = double.infinity;
    for (final r in _blurs) {
      if (r.clipId != clip.id) continue;
      for (final box in r.rectsAt(local)) {
        final shown = mapper.paddedOnCanvas(box, text: r.kind == BlurKind.text);
        if (shown.contains(canvasPoint) && shown.width * shown.height < smallest) {
          smallest = shown.width * shown.height;
          hit = r;
        }
      }
    }
    if (hit != null) _blurMenu(hit, global);
  }

  /// Outlines to draw on the preview for the blurs active at the playhead.
  List<OverlayBox> _overlayBoxes() {
    if (_blurs.isEmpty) return const [];
    final clip = _clipAt(_playhead);
    final mapper = clip == null ? null : _mapperFor(clip);
    if (clip == null || mapper == null) return const [];
    final local = _localSeconds(clip, _playhead);
    return [
      for (final r in _blurs)
        if (r.clipId == clip.id)
          for (final box in r.rectsAt(local))
            OverlayBox(
              id: r.id,
              rect: mapper.paddedOnCanvas(box, text: r.kind == BlurKind.text),
              unsure: r.isUnsureAt(local),
            ),
    ];
  }

  List<BlurSpan> _blurSpans() {
    final starts = _clipStarts;
    final spans = <BlurSpan>[];
    for (final r in _blurs) {
      final i = _clips.indexWhere((c) => c.id == r.clipId);
      if (i < 0) continue;
      Duration at(double sec) => starts[i] + Duration(microseconds: (sec * 1e6).round());
      spans.add(BlurSpan(
        id: r.id,
        start: at(r.start),
        end: at(r.end),
        scale: r.scale,
        unsure: [for (final u in r.unsureSpans) (start: at(u.start), end: at(u.end))],
        covered: r.kind == BlurKind.text
            ? [for (final c in r.coveredSpans) (start: at(c.start), end: at(c.end))]
            : null,
        label: r.kind == BlurKind.text
            ? 'Text: ${BlurLook(r.style, r.scale).description}, found in ${r.hits.length} of ${r.checked} frames read'
            : BlurLook(r.style, r.scale).description,
      ));
    }
    return spans;
  }

  BlurRegion? _blurById(int id) {
    for (final b in _blurs) {
      if (b.id == id) return b;
    }
    return null;
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
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancelDraw},
        child: Focus(
          autofocus: true,
          child: Row(
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
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                VideoPlayer(v),
                                BlurOverlay(
                                  drawing: _draw != null,
                                  boxes: _overlayBoxes(),
                                  onDrawn: _onBoxDrawn,
                                  onSecondaryTap: _onVideoSecondaryTap,
                                ),
                              ],
                            ),
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
                          onBlur: _startBlur,
                          onBlurText: () => _startBlur(text: true),
                          canBlur: _video != null && !_busy,
                          drawing: _draw != null,
                          fixing: _draw?.fixing != null,
                          drawingText: _draw?.text ?? false,
                          onCancelDraw: _cancelDraw,
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
                          blurSpans: _blurSpans(),
                          onBlurTap: (id) {
                            final r = _blurById(id);
                            final i = r == null ? -1 : _clips.indexWhere((c) => c.id == r.clipId);
                            if (r != null && i >= 0) {
                              _seek(_clipStarts[i] + Duration(microseconds: (r.start * 1e6).round()));
                            }
                          },
                          onBlurMenu: (id, global) {
                            final r = _blurById(id);
                            if (r != null) _blurMenu(r, global);
                          },
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
                              if (_searching) ...[
                                const SizedBox(width: 12),
                                TextButton(
                                    onPressed: () => _exporter.cancel(),
                                    child: const Text('Cancel')),
                              ],
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
        ),
      ),
    );
  }
}

/// What the user is currently drawing: a new blur over a stretch of one clip,
/// or a corrected box for an existing one ([fixing]).
class _BlurDraw {
  const _BlurDraw({
    required this.clip,
    required this.anchor,
    required this.rangeStart,
    required this.rangeEnd,
    this.fixing,
    this.text = false,
  });

  final Clip clip;

  /// Clip time (seconds) of the frame being drawn on.
  final double anchor;
  final double rangeStart;
  final double rangeEnd;
  final BlurRegion? fixing;

  /// Drawing a box around text to search for, rather than around an object to track.
  final bool text;
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
    required this.onBlur,
    required this.onBlurText,
    required this.canBlur,
    required this.drawing,
    required this.fixing,
    required this.drawingText,
    required this.onCancelDraw,
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
  final VoidCallback onBlur;
  final VoidCallback onBlurText;
  final bool canBlur;
  final bool drawing;
  final bool fixing;
  final bool drawingText;
  final VoidCallback onCancelDraw;

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
        if (drawing)
          Tooltip(
            message: fixing
                ? 'Drag a box where it belongs on this frame (Esc cancels)'
                : (drawingText
                    ? 'Drag a box around the text to hide (Esc cancels)'
                    : 'Drag a box over what to hide (Esc cancels)'),
            child: FilledButton.tonalIcon(
              onPressed: onCancelDraw,
              icon: const Icon(Icons.close),
              label: const Text('Cancel blur'),
            ),
          )
        else ...[
          Tooltip(
            message: 'Hide a face, a license plate, any thing that moves: mark the video just '
                'before and just after it appears, put the playhead anywhere between, then '
                'draw a box around it. The box follows it.',
            child: OutlinedButton.icon(
              onPressed: (hasContent && canBlur) ? onBlur : null,
              icon: const Icon(Icons.blur_on),
              label: const Text('Blur box'),
            ),
          ),
          Tooltip(
            message: 'Hide some text, such as an address, every place it appears: mark the video '
                'before and after it is on screen, put the playhead on a frame where you can read '
                'it, then draw a box around it. It is read, then found again on the other frames, '
                'even when it moves or shows up more than once.',
            child: OutlinedButton.icon(
              onPressed: (hasContent && canBlur) ? onBlurText : null,
              icon: const Icon(Icons.text_fields),
              label: const Text('Blur text'),
            ),
          ),
        ],
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

String _fmtSize(int bytes) {
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
