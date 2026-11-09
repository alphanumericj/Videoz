import 'package:flutter/material.dart';

/// A blur box to outline on the preview, in canvas coordinates (0 to 1,
/// top-left origin). [unsure] marks a stretch where the tracker was guessing.
class OverlayBox {
  const OverlayBox({required this.id, required this.rect, required this.unsure});
  final int id;
  final Rect rect;
  final bool unsure;
}

/// Sits on top of the video preview. Always outlines the blur boxes active at
/// the current moment (so you can see what the tracker is doing, and
/// right-click one); while [drawing], dragging draws a new box.
class BlurOverlay extends StatefulWidget {
  const BlurOverlay({
    super.key,
    required this.drawing,
    required this.boxes,
    required this.onDrawn,
    required this.onSecondaryTap,
  });

  final bool drawing;
  final List<OverlayBox> boxes;

  /// Called when a drag ends, with the box in canvas coordinates (0 to 1).
  final ValueChanged<Rect> onDrawn;

  /// Right-click / control-click at a canvas position (0 to 1), with the global
  /// position for anchoring a menu.
  final void Function(Offset canvasPoint, Offset global) onSecondaryTap;

  @override
  State<BlurOverlay> createState() => _BlurOverlayState();
}

class _BlurOverlayState extends State<BlurOverlay> {
  Offset? _start;
  Offset? _current;

  Rect? get _drawn =>
      (_start == null || _current == null) ? null : Rect.fromPoints(_start!, _current!);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      Offset norm(Offset p) => Offset(
            (p.dx / size.width).clamp(0.0, 1.0),
            (p.dy / size.height).clamp(0.0, 1.0),
          );
      return MouseRegion(
        cursor: widget.drawing ? SystemMouseCursors.precise : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapUp: (d) =>
              widget.onSecondaryTap(norm(d.localPosition), d.globalPosition),
          onPanStart: widget.drawing
              ? (d) => setState(() {
                    _start = norm(d.localPosition);
                    _current = _start;
                  })
              : null,
          onPanUpdate: widget.drawing
              ? (d) => setState(() => _current = norm(d.localPosition))
              : null,
          onPanEnd: widget.drawing
              ? (_) {
                  final r = _drawn;
                  setState(() {
                    _start = null;
                    _current = null;
                  });
                  if (r != null) widget.onDrawn(r);
                }
              : null,
          child: CustomPaint(
            size: size,
            painter: _BoxPainter(
              boxes: widget.boxes,
              drawn: widget.drawing ? _drawn : null,
            ),
          ),
        ),
      );
    });
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter({required this.boxes, required this.drawn});
  final List<OverlayBox> boxes;
  final Rect? drawn;

  Rect _px(Rect n, Size s) =>
      Rect.fromLTRB(n.left * s.width, n.top * s.height, n.right * s.width, n.bottom * s.height);

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in boxes) {
      final r = _px(b.rect, size);
      final color = b.unsure ? const Color(0xFFFF5252) : Colors.white;
      // A dark line under the colored one keeps the outline visible on any picture.
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..color = Colors.black.withValues(alpha: 0.45));
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = color);
    }
    final d = drawn;
    if (d != null) {
      final r = _px(d, size);
      canvas.drawRect(r, Paint()..color = const Color(0xFF4FC3F7).withValues(alpha: 0.18));
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFF4FC3F7));
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => true;
}
