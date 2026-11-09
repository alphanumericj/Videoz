import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:videoz/blur_region.dart';
import 'package:videoz/editor_model.dart';
import 'package:videoz/export_settings.dart';

void main() {
  test('segments, transitions, and seams derive correctly', () {
    final m = EditorModel();
    m.setTimeline(const Duration(seconds: 10));

    // No points -> one segment spanning the whole timeline.
    expect(m.segments.length, 1);
    expect(m.keptSegments.length, 1);

    // Two points -> three segments.
    m.addPoint(const Duration(seconds: 3));
    m.addPoint(const Duration(seconds: 7));
    expect(m.segments.length, 3);

    // X out the middle segment.
    m.setSegmentRemoved(m.segments[1], true);
    expect(m.keptSegments.length, 2);
    expect(m.keptDuration, const Duration(seconds: 6));

    // The seam between the two kept segments is at the end of the first kept
    // segment (t=3s), since the middle was removed.
    expect(m.activeSeamMicros.contains(const Duration(seconds: 3).inMicroseconds),
        isTrue);

    // A transition can be attached there.
    m.setTransition(const Duration(seconds: 3),
        const Transition(TransitionType.slide, Duration(milliseconds: 500)));
    final t = m.transitionAt(const Duration(seconds: 3));
    expect(t.type, TransitionType.slide);
    expect(t.duration, const Duration(milliseconds: 500));
  });

  test('adding a point inside a removed segment keeps both halves removed', () {
    final m = EditorModel();
    m.setTimeline(const Duration(seconds: 10));
    m.addPoint(const Duration(seconds: 2));
    m.setSegmentRemoved(m.segments[1], true); // remove [2,10]
    expect(m.keptDuration, const Duration(seconds: 2));

    // Split the removed segment; output must not change (still only [0,2] kept).
    m.addPoint(const Duration(seconds: 6));
    expect(m.keptDuration, const Duration(seconds: 2));
  });

  test('export settings use the names the native side expects', () {
    // These strings are matched in macos/Runner/VideoExporter.swift (Settings).
    expect(Compression.values.map((c) => c.wire),
        ['none', 'light', 'medium', 'heavy']);
    expect(ExportFormat.mp4.extension, 'mp4');
    expect(ExportFormat.mov.extension, 'mov');
    // Defaults: MP4, uncompressed.
    const d = ExportSettings();
    expect(d.format, ExportFormat.mp4);
    expect(d.compression, Compression.none);
  });

  group('blur regions', () {
    BlurRegion region(List<BlurSample> samples, {double start = 10, double end = 20}) =>
        BlurRegion(
            id: 1, clipId: 7, start: start, end: end, scale: PixelScale.medium,
            samples: samples, anchors: [15]);
    BlurSample at(double t, double x, {double conf = 1}) =>
        BlurSample(t: t, rect: Rect.fromLTWH(x, 0.5, 0.1, 0.1), conf: conf);

    test('rectAt interpolates, holds at the ends, and is null outside the range', () {
      final r = region([at(10, 0.0), at(20, 1.0)]);
      expect(r.rectAt(15)!.left, closeTo(0.5, 1e-9));
      expect(r.rectAt(10)!.left, closeTo(0.0, 1e-9));
      expect(r.rectAt(20)!.left, closeTo(1.0, 1e-9));
      expect(r.rectAt(9.0), isNull);
      expect(r.rectAt(21.0), isNull);
      // Samples that don't reach the range ends are held, not dropped.
      final short = region([at(12, 0.2), at(18, 0.8)]);
      expect(short.rectAt(10.5)!.left, closeTo(0.2, 1e-9));
      expect(short.rectAt(19.5)!.left, closeTo(0.8, 1e-9));
    });

    test('unsure stretches are found, and blips under 0.1s are ignored', () {
      final r = region([
        at(10.0, 0.1), at(10.5, 0.1, conf: 0.9),
        at(11.0, 0.1, conf: 0.1), at(11.5, 0.1, conf: 0.0), at(12.0, 0.1, conf: 0.9),
        at(12.05, 0.1, conf: 0.2), at(12.1, 0.1, conf: 0.9), // a 0.05s blip: ignored
      ]);
      final spans = r.unsureSpans;
      expect(spans.length, 1);
      expect(spans.first.start, 11.0);
      expect(spans.first.end, 12.0);
      expect(r.isUnsureAt(11.2), isTrue);
      expect(r.isUnsureAt(10.7), isFalse);
    });

    test('toMap flattens the boxes for the native renderer', () {
      final m = region([at(10, 0.0), at(20, 1.0)]).toMap();
      expect(m['clipId'], '7');
      expect(m['scale'], 'medium');
      expect((m['samples'] as List).length, 10); // 2 samples x [t, x, y, w, h]
      expect(m['style'], 'pixelate');
    });

    test('styles use the names the native side expects', () {
      // These strings are matched in macos/Runner/VideoExporter.swift (applyBlur).
      expect(BlurStyle.values.map((s) => s.wire), ['pixelate', 'blur', 'box', 'fill']);
      expect(BlurStyle.box.hasScale, isFalse);
      expect(BlurStyle.fill.hasScale, isFalse);
      expect(BlurStyle.blur.hasScale, isTrue);
    });
  });

  group('text blurs', () {
    TextHit hit(double t, double x) =>
        TextHit(t: t, rects: [Rect.fromLTWH(x, 0.5, 0.2, 0.05)]);
    BlurRegion text(List<TextHit> hits, {double start = 0, double end = 5}) => BlurRegion(
        id: 2, clipId: 7, start: start, end: end, scale: PixelScale.coarse,
        samples: const [], anchors: [1], kind: BlurKind.text, hits: hits,
        phrases: const ['123 Main Street'], checked: 40);

    test('finds close together are one continuous stretch, with a lead and tail', () {
      final r = text([hit(1.0, 0.1), hit(1.1, 0.1), hit(1.2, 0.1), hit(3.0, 0.6)]);
      final spans = r.coveredSpans;
      expect(spans.length, 2);
      expect(spans[0].start, closeTo(0.8, 1e-9)); // 0.2 s before the first find
      expect(spans[0].end, closeTo(1.5, 1e-9)); // 0.3 s after the last of the group
      expect(spans[1].start, closeTo(2.8, 1e-9));
      expect(spans[1].end, closeTo(3.3, 1e-9));
    });

    test('rectsAt is empty where the text was not found, and covers every box', () {
      final r = text([
        TextHit(t: 1.0, rects: [const Rect.fromLTWH(0.1, 0.1, 0.2, 0.05), const Rect.fromLTWH(0.5, 0.8, 0.2, 0.05)]),
        hit(3.0, 0.6),
      ]);
      expect(r.rectsAt(1.0).length, 2); // two places at once
      expect(r.rectsAt(2.0), isEmpty); // gone between the finds
      expect(r.rectsAt(3.1).length, 1);
      expect(r.rectsAt(6.0), isEmpty); // outside the marked range
    });

    test('across a bridged gap, both finds apply (covers motion in between)', () {
      final r = text([hit(1.0, 0.1), hit(1.5, 0.4)]);
      expect(r.rectsAt(1.25).length, 2);
      expect(r.rectsAt(1.25).map((e) => e.left), containsAll([0.1, 0.4]));
    });

    test('is sent as entries, not samples, and is never flagged unsure', () {
      final r = text([hit(1.0, 0.1)]);
      final m = r.toMap();
      expect(m.containsKey('entries'), isTrue);
      expect(m.containsKey('samples'), isFalse);
      final entry = ((m['entries'] as List).first as List).cast<double>();
      const expected = [0.8, 1.3, 0.1, 0.5, 0.2, 0.05];
      expect(entry.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        expect(entry[i], closeTo(expected[i], 1e-9));
      }
      expect(r.unsureSpans, isEmpty);
    });
  });

  group('frame mapping', () {
    test('is the identity when the canvas matches the clip', () {
      final m = FrameMapper(canvas: const Size(1280, 588), clip: const Size(1280, 588));
      const r = Rect.fromLTWH(0.25, 0.3, 0.2, 0.1);
      final back = m.canvasToClip(r);
      expect(back.left, closeTo(0.25, 1e-9));
      expect(back.top, closeTo(0.3, 1e-9));
      expect(back.width, closeTo(0.2, 1e-9));
      expect(back.height, closeTo(0.1, 1e-9));
    });

    test('accounts for letterboxing and round-trips', () {
      // A square clip centered in a 16:9 canvas: bars left and right.
      final m = FrameMapper(canvas: const Size(1280, 720), clip: const Size(640, 640));
      // The canvas center is the clip's center.
      final center = m.canvasToClip(const Rect.fromLTWH(0.45, 0.4, 0.1, 0.2));
      expect(center.center.dx, closeTo(0.5, 1e-9));
      expect(center.center.dy, closeTo(0.5, 1e-9));
      // The whole canvas covers the whole clip, nothing more.
      final all = m.canvasToClip(const Rect.fromLTWH(0, 0, 1, 1));
      expect(all, const Rect.fromLTWH(0, 0, 1, 1));
      // A box drawn only in a black bar hits nothing.
      expect(m.canvasToClip(const Rect.fromLTWH(0.0, 0.2, 0.1, 0.2)), Rect.zero);
      // Round trip.
      const clipBox = Rect.fromLTWH(0.2, 0.1, 0.5, 0.3);
      final rt = m.canvasToClip(m.clipToCanvas(clipBox));
      expect(rt.left, closeTo(0.2, 1e-9));
      expect(rt.width, closeTo(0.5, 1e-9));
    });

    test('padding grows the box 20% per side and stays on the canvas', () {
      final m = FrameMapper(canvas: const Size(1000, 500), clip: const Size(1000, 500));
      final p = m.paddedOnCanvas(const Rect.fromLTWH(0.4, 0.4, 0.2, 0.2));
      expect(p.left, closeTo(0.36, 1e-9));
      expect(p.top, closeTo(0.36, 1e-9));
      expect(p.right, closeTo(0.64, 1e-9));
      expect(p.bottom, closeTo(0.64, 1e-9));
      // Text is padded by a third of its height instead of a fifth of its size.
      final t = m.paddedOnCanvas(const Rect.fromLTWH(0.4, 0.4, 0.2, 0.2), text: true);
      expect(t.left, closeTo(0.367, 1e-9));
      expect(t.right, closeTo(0.633, 1e-9));
      expect(t.top, closeTo(0.334, 1e-9));
      final edge = m.paddedOnCanvas(const Rect.fromLTWH(0.0, 0.0, 0.2, 0.2));
      expect(edge.left, 0.0);
      expect(edge.top, 0.0);
    });
  });
}
