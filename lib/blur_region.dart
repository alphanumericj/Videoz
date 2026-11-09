import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

/// The strength of a look: how coarse the mosaic, or how heavy the blur. The native
/// side sizes everything relative to the box (10, 6 or 3 blocks across its shorter
/// side, or a blur a fraction of its size), so a small face and a wide banner look
/// alike; the numbers live in macos/Runner/VideoExporter.swift.
enum PixelScale {
  fine('fine'),
  medium('medium'),
  coarse('coarse');

  const PixelScale(this.wire);
  final String wire;
}

/// How a blur is drawn.
enum BlurStyle {
  pixelate('pixelate', 'Pixelate', 'Blocky mosaic. Coarse is the safest choice for text.'),
  blur('blur', 'Frosted blur',
      'Smooth and cloudy, with soft edges. For text use Heavy: a light blur can sometimes be partly undone.'),
  box('box', 'Black box', 'A solid black box. It hides everything, for certain.'),
  fill('fill', 'Match background',
      'Fills the box with the colors around it, so text all but vanishes. Best on a plain or smoothly '
          'shaded background; on a busy one the smooth patch will show.');

  const BlurStyle(this.wire, this.label, this.hint);
  final String wire;
  final String label;
  final String hint;

  /// Black box and Match background have just one strength.
  bool get hasScale => this == pixelate || this == blur;

  /// What to call a strength for this style.
  String labelFor(PixelScale scale) {
    if (this == pixelate) {
      return switch (scale) {
        PixelScale.fine => 'Fine',
        PixelScale.medium => 'Medium',
        PixelScale.coarse => 'Coarse',
      };
    }
    return switch (scale) {
      PixelScale.fine => 'Light',
      PixelScale.medium => 'Medium',
      PixelScale.coarse => 'Heavy',
    };
  }
}

/// A chosen look: style and strength.
class BlurLook {
  const BlurLook(this.style, this.scale);
  final BlurStyle style;
  final PixelScale scale;

  /// "Frosted blur (heavy)", or just "Black box" for styles with one strength.
  String get description =>
      style.hasScale ? '${style.label} (${style.labelFor(scale).toLowerCase()})' : style.label;
}

/// An object blur follows one box; a text blur boxes every place a phrase was found.
enum BlurKind { object, text }

/// One sampled frame where the searched text was found: every box (0 to 1, top-left
/// origin, on the clip's displayed frame) where it appeared, there can be several.
class TextHit {
  const TextHit({required this.t, required this.rects});
  final double t;
  final List<Rect> rects;
}

/// The tracked box at one moment: [rect] is normalized (0 to 1) to the clip's
/// displayed frame with a top-left origin, [t] is clip time in seconds, and
/// [conf] is the tracker's confidence (which, as we found, is not proof that
/// the box is right, only a hint that it might be wrong when low).
class BlurSample {
  const BlurSample({required this.t, required this.rect, required this.conf});
  final double t;
  final Rect rect;
  final double conf;
}

/// One blur: a pixelated box that follows something through a stretch of one
/// clip. Times are clip-local seconds, so reordering clips or adding cut points
/// doesn't move it.
class BlurRegion {
  BlurRegion({
    required this.id,
    required this.clipId,
    required this.start,
    required this.end,
    required this.scale,
    required this.samples,
    required this.anchors,
    this.style = BlurStyle.pixelate,
    this.kind = BlurKind.object,
    this.hits = const [],
    this.phrases = const [],
    this.checked = 0,
  });

  static int _next = 0;
  static int nextId() => _next++;

  /// Below this the tracker is guessing; the box is held at its last good spot
  /// and the stretch is flagged for the user to check.
  static const unsureBelow = 0.35;

  final int id;
  final int clipId;
  final double start;
  final double end;
  PixelScale scale;
  BlurStyle style;
  final BlurKind kind;

  /// Text blurs: where the phrase was found, time-ordered.
  final List<TextHit> hits;

  /// Text blurs: what was searched for.
  final List<String> phrases;

  /// Text blurs: how many frames were read to look for it.
  final int checked;

  // Text coverage. Frames are read ~8 times a second, so each find also covers a
  // little before it and after it; two finds less than [textBridge] apart are
  // treated as one continuous presence (the reader misses frames now and then).
  // During a bridged gap both finds' boxes apply, which also covers motion between.
  static const textLead = 0.2;
  static const textTail = 0.3;
  static const textBridge = 0.8;

  /// Each find as a stretch of time with its boxes; at any moment the boxes of
  /// every stretch containing it are the ones blurred.
  late final List<({double a, double b, List<Rect> rects})> entries = _buildEntries();

  List<({double a, double b, List<Rect> rects})> _buildEntries() {
    final out = <({double a, double b, List<Rect> rects})>[];
    for (var i = 0; i < hits.length; i++) {
      final t = hits[i].t;
      final a = (i > 0 && t - hits[i - 1].t <= textBridge) ? hits[i - 1].t : t - textLead;
      final b = (i < hits.length - 1 && hits[i + 1].t - t <= textBridge) ? hits[i + 1].t : t + textTail;
      out.add((a: math.max(a, start), b: math.min(b, end), rects: hits[i].rects));
    }
    return out;
  }

  /// The boxes to pixelate at clip time [t] (none outside this blur's range).
  List<Rect> rectsAt(double t) {
    if (kind == BlurKind.object) {
      final r = rectAt(t);
      return r == null ? const [] : [r];
    }
    if (!contains(t)) return const [];
    return [
      for (final e in entries)
        if (t >= e.a - 1e-6 && t <= e.b + 1e-6) ...e.rects,
    ];
  }

  /// Text blurs: the stretches (clip seconds) where something is actually
  /// blurred, merged. The rest of the marked range is where the text wasn't found.
  List<({double start, double end})> get coveredSpans {
    final sorted = [...entries]..sort((x, y) => x.a.compareTo(y.a));
    final spans = <({double start, double end})>[];
    for (final e in sorted) {
      if (spans.isNotEmpty && e.a <= spans.last.end + 1e-6) {
        if (e.b > spans.last.end) spans[spans.length - 1] = (start: spans.last.start, end: e.b);
      } else {
        spans.add((start: e.a, end: e.b));
      }
    }
    return spans;
  }

  /// Time-ordered boxes covering [start]..[end].
  List<BlurSample> samples;

  /// Times (clip seconds) where the user placed the box by hand: the original
  /// frame, and any frame they later fixed. Re-tracking never crosses one.
  List<double> anchors;

  bool contains(double t) => t >= start - 0.001 && t <= end + 0.001;

  /// Index of the first sample later than [t] (samples.length if none).
  int _upper(double t) {
    var lo = 0, hi = samples.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].t <= t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The box at clip time [t]: interpolated between samples and held at the
  /// ends, or null outside this blur's own time range.
  Rect? rectAt(double t) {
    if (samples.isEmpty || !contains(t)) return null;
    final i = _upper(t);
    if (i == 0) return samples.first.rect;
    if (i >= samples.length) return samples.last.rect;
    final a = samples[i - 1], b = samples[i];
    final f = (t - a.t) / math.max(1e-9, b.t - a.t);
    return Rect.fromLTWH(
      a.rect.left + (b.rect.left - a.rect.left) * f,
      a.rect.top + (b.rect.top - a.rect.top) * f,
      a.rect.width + (b.rect.width - a.rect.width) * f,
      a.rect.height + (b.rect.height - a.rect.height) * f,
    );
  }

  /// Tracker confidence at [t] (nearest earlier sample).
  double confAt(double t) {
    if (samples.isEmpty) return 0;
    final i = _upper(t);
    return samples[math.max(0, i - 1)].conf;
  }

  bool isUnsureAt(double t) => confAt(t) < unsureBelow;

  /// Stretches (clip seconds) where the tracker was unsure, ignoring blips
  /// shorter than a tenth of a second.
  List<({double start, double end})> get unsureSpans {
    if (kind == BlurKind.text) return const []; // text is found or not; see coveredSpans
    final spans = <({double start, double end})>[];
    double? runStart;
    for (var i = 0; i < samples.length; i++) {
      final low = samples[i].conf < unsureBelow;
      if (low && runStart == null) runStart = samples[i].t;
      final last = i == samples.length - 1;
      if (runStart != null && (!low || last)) {
        final runEnd = samples[i].t;
        if (runEnd - runStart >= 0.1) spans.add((start: runStart, end: runEnd));
        runStart = null;
      }
    }
    return spans;
  }

  /// What the native renderer needs: the clip, the time range, the scale, and the
  /// boxes: an object's flattened as [t, x, y, w, h, ...], or a text blur's as
  /// entries of [from, to, x, y, w, h, x, y, w, h, ...].
  Map<String, dynamic> toMap() => {
        'clipId': clipId.toString(),
        'start': start,
        'end': end,
        'scale': scale.wire,
        'style': style.wire,
        if (kind == BlurKind.text)
          'entries': [
            for (final e in entries)
              [
                e.a,
                e.b,
                for (final r in e.rects) ...[r.left, r.top, r.width, r.height],
              ],
          ],
        if (kind == BlurKind.object) 'samples': [
          for (final s in samples) ...[
            s.t,
            s.rect.left,
            s.rect.top,
            s.rect.width,
            s.rect.height,
          ],
        ],
      };
}

/// Converts between the preview canvas (what's on screen, which letterboxes a
/// clip whose shape differs from the first clip's) and the clip's own frame.
/// Both are in 0 to 1 coordinates with a top-left origin. This is the same
/// aspect-fit the renderer uses, so a box drawn on the preview lands on the
/// same pixels in the saved file.
class FrameMapper {
  FrameMapper({required this.canvas, required this.clip});

  /// Preview video size in pixels.
  final Size canvas;

  /// The clip's displayed size in pixels (after rotation).
  final Size clip;

  double get _scale =>
      math.min(canvas.width / clip.width, canvas.height / clip.height);

  /// Where the clip's frame sits inside the canvas, in canvas pixels.
  Rect get _shown {
    final w = clip.width * _scale, h = clip.height * _scale;
    return Rect.fromLTWH((canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
  }

  Rect _toPixels(Rect n) => Rect.fromLTRB(n.left * canvas.width, n.top * canvas.height,
      n.right * canvas.width, n.bottom * canvas.height);

  Rect _fromPixels(Rect p) => Rect.fromLTRB(p.left / canvas.width, p.top / canvas.height,
      p.right / canvas.width, p.bottom / canvas.height);

  /// A box drawn on the canvas, as a box on the clip's frame (clamped to it).
  /// Empty if it was drawn entirely outside the clip (in the letterbox bars).
  Rect canvasToClip(Rect canvasNorm) {
    final shown = _shown;
    final px = _toPixels(canvasNorm).intersect(shown);
    if (px.width <= 0 || px.height <= 0) return Rect.zero;
    return Rect.fromLTRB((px.left - shown.left) / shown.width, (px.top - shown.top) / shown.height,
        (px.right - shown.left) / shown.width, (px.bottom - shown.top) / shown.height);
  }

  /// A box on the clip's frame, as a box on the canvas.
  Rect clipToCanvas(Rect clipNorm) {
    final shown = _shown;
    return _fromPixels(Rect.fromLTWH(
      shown.left + clipNorm.left * shown.width,
      shown.top + clipNorm.top * shown.height,
      clipNorm.width * shown.width,
      clipNorm.height * shown.height,
    ));
  }

  /// The area that actually gets pixelated for a tracked box: grown by 20% on
  /// each side (and at least 1.2% of the canvas's short side). Mirrors
  /// `paddedBox` in macos/Runner/VideoExporter.swift so the on-screen outline
  /// matches the pixelation.
  ///
  /// Text boxes are padded by a third of the text's height instead, so a long
  /// phrase doesn't swallow its neighbors.
  Rect paddedOnCanvas(Rect clipNorm, {bool text = false}) {
    final px = _toPixels(clipToCanvas(clipNorm));
    final floorPad = 0.012 * math.min(canvas.width, canvas.height);
    final padX = text ? math.max(0.33 * px.height, floorPad) : math.max(0.2 * px.width, floorPad);
    final padY = text ? math.max(0.33 * px.height, floorPad) : math.max(0.2 * px.height, floorPad);
    final padded = Rect.fromLTRB(px.left - padX, px.top - padY, px.right + padX, px.bottom + padY)
        .intersect(Rect.fromLTWH(0, 0, canvas.width, canvas.height));
    return _fromPixels(padded);
  }
}
