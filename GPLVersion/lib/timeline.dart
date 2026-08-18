import 'package:flutter/material.dart';

import 'editor_model.dart';

/// The scrubber + segment strip along the bottom of the editor.
///
/// Top row: a thin ruler you tap/drag to seek. Bottom row: one tile per
/// segment — tap a tile to X it out (or bring it back). Cut points appear as
/// gold dividers between tiles.
class Timeline extends StatelessWidget {
  const Timeline({
    super.key,
    required this.model,
    required this.playhead,
    required this.onSeek,
  });

  final EditorModel model;
  final Duration playhead;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final total = model.total;
    final segments = model.segments;

    if (total == Duration.zero || segments.isEmpty) {
      return const SizedBox(
        height: 96,
        child: Center(child: Text('Load a file to see the timeline.')),
      );
    }

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
            // ----- Ruler / scrubber -----
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
            // ----- Segment tiles -----
            SizedBox(
              height: 60,
              child: Row(
                children: [
                  for (var i = 0; i < segments.length; i++) ...[
                    Expanded(
                      flex: segments[i].length.inMilliseconds.clamp(1, 1 << 30),
                      child: _SegmentTile(
                        index: i,
                        segment: segments[i],
                        onTap: () =>
                            model.setSegmentRemoved(segments[i], !segments[i].removed),
                      ),
                    ),
                    if (i != segments.length - 1)
                      const _PointDivider(),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({
    required this.index,
    required this.segment,
    required this.onTap,
  });

  final int index;
  final Segment segment;
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
            color: removed
                ? scheme.errorContainer
                : scheme.primaryContainer,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: removed ? scheme.error : scheme.primary,
              width: 1,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: removed
                        ? scheme.onErrorContainer
                        : scheme.onPrimaryContainer,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (removed)
                CustomPaint(
                  painter: _CrossPainter(color: scheme.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PointDivider extends StatelessWidget {
  const _PointDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: Theme.of(context).colorScheme.secondary,
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
    // Playhead: line + triangle handle.
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

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final ms = d.inMilliseconds.remainder(1000) ~/ 100;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss.$ms' : '$mm:$ss.$ms';
}
