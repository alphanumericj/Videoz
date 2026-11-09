import 'package:flutter_test/flutter_test.dart';

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
}
