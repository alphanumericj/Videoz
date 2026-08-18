import 'package:flutter_test/flutter_test.dart';

import 'package:videoz/editor_model.dart';

void main() {
  test('segments derive from points and toggle removed', () {
    final m = EditorModel();
    m.loadFile('/tmp/x.mp4', const Duration(seconds: 10));

    // No points -> one segment spanning the whole file.
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
  });
}
