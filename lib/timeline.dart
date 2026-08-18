import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'clip.dart';
import 'editor_model.dart';
import 'export_service.dart';

/// The scrubber + segment strip along the bottom of the editor.
///
/// Top row: a thin ruler you tap/drag to seek. Bottom row: one tile per
/// segment, showing a filmstrip of that segment's own thumbnails — tap a tile
/// to X it out (shows the usual red cross) or bring it back. Between two kept
/// segments the divider becomes a transition handle you can click to set a
/// crossfade.
class Timeline extends StatelessWidget {
  const Timeline({
    super.key,
    required this.model,
    required this.clips,
    required this.exporter,
    required this.playhead,
    required this.onSeek,
    required this.onToggleSegment,
    required this.onTransitionTap,
  });

  final EditorModel model;
  final List<Clip> clips;
  final ExportService exporter;
  final Duration playhead;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Segment> onToggleSegment;
  final ValueChanged<Duration> onTransitionTap;

  @override
  Widget build(BuildContext context) {
    final total = model.total;
    final segments = model.segments;

    if (total == Duration.zero || segments.isEmpty) {
      return const SizedBox(
        height: 96,
        child: Center(child: Text('Add clips to see the timeline.')),
      );
    }

    final seams = model.activeSeamMicros;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        Duration posForDx(double dx) {
          final frac = (dx / width).clamp(0.0, 1.0);
          return Duration(microseconds: (total.inMicroseconds * frac).round());
        }

        final playFrac = total.inMicroseconds == 0
            ? 0.0
            : (playhead.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 28,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => onSeek(posForDx(d.localPosition.dx)),
                onHorizontalDragUpdate: (d) =>
                    onSeek(posForDx(d.localPosition.dx)),
                child: CustomPaint(
                  painter: _RulerPainter(
                    playFrac: playFrac,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 60,
              child: _SegmentFilmstrip(
                segments: segments,
                clips: clips,
                exporter: exporter,
                total: total,
                rowWidth: width,
                seams: seams,
                model: model,
                onToggleSegment: onToggleSegment,
                onTransitionTap: onTransitionTap,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The segment row: each kept segment shows a mini filmstrip of its own
/// thumbnails (not tied to a global grid — each segment's cells span exactly
/// its own time range); a removed segment shows the plain red-cross tile.
/// Thumbnail requests for every kept segment are batched into one native
/// call, and results are cached by (path, time) so re-fetching only happens
/// for genuinely new (path, time) pairs — toggling a segment back and forth,
/// or editing an unrelated part of the timeline, reuses what's already there.
class _SegmentFilmstrip extends StatefulWidget {
  const _SegmentFilmstrip({
    required this.segments,
    required this.clips,
    required this.exporter,
    required this.total,
    required this.rowWidth,
    required this.seams,
    required this.model,
    required this.onToggleSegment,
    required this.onTransitionTap,
  });

  final List<Segment> segments;
  final List<Clip> clips;
  final ExportService exporter;
  final Duration total;
  final double rowWidth;
  final Set<int> seams;
  final EditorModel model;
  final ValueChanged<Segment> onToggleSegment;
  final ValueChanged<Duration> onTransitionTap;

  @override
  State<_SegmentFilmstrip> createState() => _SegmentFilmstripState();
}

class _SegmentFilmstripState extends State<_SegmentFilmstrip> {
  static const _cellWidth = 50.0;
  static const _maxCellsPerSegment = 6;

  final Map<String, Uint8List?> _cache = {};
  String _loadedSignature = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(covariant _SegmentFilmstrip old) {
    super.didUpdateWidget(old);
    _maybeLoad();
  }

  String _signature() =>
      '${widget.rowWidth.round()}|'
      '${widget.segments.map((s) => '${s.start.inMicroseconds}-${s.end.inMicroseconds}-${s.removed}').join(',')}|'
      '${widget.clips.map((c) => '${c.id}:${c.path}:${c.duration.inMicroseconds}').join(',')}';

  List<Duration> get _clipStarts {
    final starts = <Duration>[];
    var acc = Duration.zero;
    for (final c in widget.clips) {
      starts.add(acc);
      acc += c.duration;
    }
    return starts;
  }

  int _clipIndexFor(Duration t, List<Duration> starts) {
    for (var i = 0; i < widget.clips.length; i++) {
      if (t < starts[i] + widget.clips[i].duration) return i;
    }
    return widget.clips.length - 1;
  }

  int _cellsFor(Segment s) {
    if (widget.total.inMicroseconds == 0) return 1;
    final frac = s.length.inMicroseconds / widget.total.inMicroseconds;
    final estWidth = frac * widget.rowWidth;
    return (estWidth / _cellWidth).round().clamp(1, _maxCellsPerSegment);
  }

  /// Thumbnail requests spanning exactly this segment's own time range,
  /// mapped into whichever single clip contains it (segments never straddle
  /// a clip boundary, since one is always seeded there).
  List<ThumbRequest> _requestsFor(Segment s, int cells, List<Duration> starts) {
    if (widget.clips.isEmpty) return const [];
    final clipIndex = _clipIndexFor(s.start, starts);
    final clip = widget.clips[clipIndex];
    final clipStart = starts[clipIndex];
    final clipLenSeconds = clip.duration.inMicroseconds / 1e6;
    final reqs = <ThumbRequest>[];
    for (var i = 0; i < cells; i++) {
      final frac = cells == 1 ? 0.5 : (i + 0.5) / cells;
      final t = s.start + s.length * frac;
      final localSeconds = (t - clipStart).inMicroseconds / 1e6;
      reqs.add(ThumbRequest(
        path: clip.path,
        time: localSeconds.clamp(0.0, clipLenSeconds > 0 ? clipLenSeconds : 0.0),
      ));
    }
    return reqs;
  }

  String _cacheKey(ThumbRequest r) => '${r.path}@${r.time.toStringAsFixed(2)}';

  void _maybeLoad() {
    final sig = _signature();
    if (sig == _loadedSignature) return;
    _loadedSignature = sig;
    _load();
  }

  Future<void> _load() async {
    final gen = ++_generation;
    final starts = _clipStarts;
    final toFetch = <ThumbRequest>[];
    final seen = <String>{};
    for (final s in widget.segments) {
      if (s.removed) continue;
      for (final r in _requestsFor(s, _cellsFor(s), starts)) {
        final key = _cacheKey(r);
        if (!_cache.containsKey(key) && seen.add(key)) {
          toFetch.add(r);
        }
      }
    }
    if (toFetch.isEmpty) return;

    final results = await widget.exporter.thumbnails(toFetch);
    if (!mounted || gen != _generation) return;
    setState(() {
      for (var i = 0; i < toFetch.length; i++) {
        _cache[_cacheKey(toFetch[i])] = results[i];
      }
    });
  }

  List<Uint8List?> _thumbsFor(Segment s, List<Duration> starts) {
    if (s.removed) return const [];
    return _requestsFor(s, _cellsFor(s), starts)
        .map((r) => _cache[_cacheKey(r)])
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final segments = widget.segments;
    final starts = _clipStarts;
    return Row(
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          Expanded(
            flex: segments[i].length.inMilliseconds.clamp(1, 1 << 30),
            child: _SegmentTile(
              segment: segments[i],
              thumbnails: _thumbsFor(segments[i], starts),
              onTap: () => widget.onToggleSegment(segments[i]),
            ),
          ),
          if (i != segments.length - 1)
            _Divider(
              point: segments[i].end,
              isSeam: widget.seams.contains(segments[i].end.inMicroseconds),
              transition: widget.model.transitionAt(segments[i].end),
              onTap: widget.onTransitionTap,
            ),
        ],
      ],
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({
    required this.segment,
    required this.thumbnails,
    required this.onTap,
  });

  final Segment segment;
  final List<Uint8List?> thumbnails;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final removed = segment.removed;
    return Tooltip(
      message: removed
          ? 'Removed — click to keep\n${_fmt(segment.start)} → ${_fmt(segment.end)}'
          : 'Kept — click to X out\n${_fmt(segment.start)} → ${_fmt(segment.end)}',
      waitDuration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: removed ? scheme.errorContainer : Colors.black26,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: removed
                  ? scheme.error
                  : scheme.primary.withValues(alpha: 0.4),
              width: 1,
            ),
          ),
          child: removed
              ? SizedBox.expand(
                  child: CustomPaint(painter: _CrossPainter(color: scheme.error)))
              : ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Row(
                    children: [
                      for (final t in thumbnails)
                        Expanded(
                          child: t != null
                              ? Image.memory(t,
                                  fit: BoxFit.cover, gaplessPlayback: true)
                              : const SizedBox.expand(),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// The boundary between two segments. At a real seam (two kept segments meet)
/// it becomes a clickable transition handle; elsewhere it's a plain marker.
class _Divider extends StatelessWidget {
  const _Divider({
    required this.point,
    required this.isSeam,
    required this.transition,
    required this.onTap,
  });

  final Duration point;
  final bool isSeam;
  final Transition transition;
  final ValueChanged<Duration> onTap;

  IconData get _icon => switch (transition.type) {
        TransitionType.fadeBlack => Icons.circle,
        TransitionType.slide => Icons.chevron_right,
        TransitionType.pageCurl => Icons.auto_stories,
        TransitionType.blinds => Icons.view_stream,
        _ => Icons.gradient,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = transition.isActive;

    if (!isSeam) {
      return Container(
        width: 3,
        margin: const EdgeInsets.symmetric(vertical: 2),
        color: scheme.secondary,
      );
    }

    return Tooltip(
      message: active
          ? '${transition.type.label} ${_fadeLabel(transition.duration)} — click to change'
          : 'Click to add a transition here',
      child: GestureDetector(
        onTap: () => onTap(point),
        child: SizedBox(
          width: 18,
          child: Center(
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? scheme.secondary : scheme.surface,
                border: Border.all(color: scheme.secondary, width: 2),
              ),
              child: Icon(
                _icon,
                size: 11,
                color: active ? scheme.onSecondary : scheme.secondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CrossPainter extends CustomPainter {
  _CrossPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(4, 4), Offset(size.width - 4, size.height - 4), p);
    canvas.drawLine(Offset(size.width - 4, 4), Offset(4, size.height - 4), p);
  }

  @override
  bool shouldRepaint(covariant _CrossPainter old) => old.color != color;
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.playFrac, required this.color});
  final double playFrac;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final y = size.height - 8;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), track);

    final x = size.width * playFrac;
    final head = Paint()..color = color;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), head..strokeWidth = 2);
    final path = Path()
      ..moveTo(x - 6, 0)
      ..lineTo(x + 6, 0)
      ..lineTo(x, 8)
      ..close();
    canvas.drawPath(path, head);
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.playFrac != playFrac || old.color != color;
}

String _fadeLabel(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final ms = d.inMilliseconds.remainder(1000) ~/ 100;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss.$ms' : '$mm:$ss.$ms';
}
