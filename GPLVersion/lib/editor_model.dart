import 'package:flutter/foundation.dart';

/// A contiguous slice of the source media between two boundaries.
class Segment {
  Segment({required this.start, required this.end, this.removed = false});

  final Duration start;
  final Duration end;
  bool removed;

  Duration get length => end - start;
}

/// Holds the currently loaded file, its duration, the user-placed cut points,
/// and which resulting segments are "X'd out". Segments are always derived from
/// the sorted set of points plus the implicit boundaries at 0 and [total].
class EditorModel extends ChangeNotifier {
  String? _filePath;
  Duration _total = Duration.zero;

  /// Interior cut points (never 0 or [total]). Kept sorted & de-duplicated.
  final List<Duration> _points = <Duration>[];

  /// Removed-state keyed by the segment's start micros, so toggles survive
  /// the addition/removal of unrelated points.
  final Set<int> _removedStartMicros = <int>{};

  String? get filePath => _filePath;
  Duration get total => _total;
  List<Duration> get points => List.unmodifiable(_points);
  bool get hasFile => _filePath != null;

  void loadFile(String path, Duration total) {
    _filePath = path;
    _total = total;
    _points.clear();
    _removedStartMicros.clear();
    notifyListeners();
  }

  void setTotal(Duration total) {
    // Duration may only be known once the player reports it.
    if (total > Duration.zero && total != _total) {
      _total = total;
      notifyListeners();
    }
  }

  /// Add a cut point at [at]. Ignored if it coincides (within 100ms) with an
  /// existing point or an outer boundary.
  void addPoint(Duration at) {
    if (_total == Duration.zero) return;
    const slop = Duration(milliseconds: 100);
    if (at <= slop || at >= _total - slop) return;
    for (final p in _points) {
      if ((p - at).abs() < slop) return;
    }
    _points.add(at);
    _points.sort();
    notifyListeners();
  }

  void removePoint(Duration point) {
    _points.remove(point);
    _points.sort();
    notifyListeners();
  }

  void clearPoints() {
    _points.clear();
    _removedStartMicros.clear();
    notifyListeners();
  }

  /// Segments derived from boundaries = [0, ...points, total].
  List<Segment> get segments {
    if (_total == Duration.zero) return const <Segment>[];
    final bounds = <Duration>[Duration.zero, ..._points, _total];
    final result = <Segment>[];
    for (var i = 0; i < bounds.length - 1; i++) {
      final start = bounds[i];
      final end = bounds[i + 1];
      if (end <= start) continue;
      result.add(Segment(
        start: start,
        end: end,
        removed: _removedStartMicros.contains(start.inMicroseconds),
      ));
    }
    return result;
  }

  void toggleSegmentAt(Duration position) {
    final seg = _segmentContaining(position);
    if (seg == null) return;
    final key = seg.start.inMicroseconds;
    if (_removedStartMicros.contains(key)) {
      _removedStartMicros.remove(key);
    } else {
      _removedStartMicros.add(key);
    }
    notifyListeners();
  }

  void setSegmentRemoved(Segment seg, bool removed) {
    final key = seg.start.inMicroseconds;
    if (removed) {
      _removedStartMicros.add(key);
    } else {
      _removedStartMicros.remove(key);
    }
    notifyListeners();
  }

  Segment? _segmentContaining(Duration position) {
    for (final s in segments) {
      if (position >= s.start && position < s.end) return s;
    }
    return null;
  }

  List<Segment> get keptSegments =>
      segments.where((s) => !s.removed).toList(growable: false);

  Duration get keptDuration => keptSegments.fold(
      Duration.zero, (acc, s) => acc + s.length);
}
