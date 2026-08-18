import 'package:flutter/foundation.dart';

/// The kinds of transition that can sit on a seam between two kept segments.
enum TransitionType {
  none,
  crossfade,
  fadeBlack,
  slide,
  pageCurl,
  blinds;

  /// Wire name sent to the native renderer.
  String get wire => switch (this) {
        TransitionType.none => 'none',
        TransitionType.crossfade => 'crossfade',
        TransitionType.fadeBlack => 'fadeblack',
        TransitionType.slide => 'slide',
        TransitionType.pageCurl => 'pagecurl',
        TransitionType.blinds => 'blinds',
      };

  String get label => switch (this) {
        TransitionType.none => 'None',
        TransitionType.crossfade => 'Crossfade',
        TransitionType.fadeBlack => 'Fade thru black',
        TransitionType.slide => 'Slide',
        TransitionType.pageCurl => 'Page curl',
        TransitionType.blinds => 'Blinds',
      };
}

/// A transition assigned to a seam: a [type] applied over [duration].
class Transition {
  const Transition(this.type, this.duration);

  final TransitionType type;
  final Duration duration;

  static const none = Transition(TransitionType.none, Duration.zero);

  bool get isActive =>
      type != TransitionType.none && duration > Duration.zero;
}

/// A contiguous slice of the source timeline between two boundaries.
class Segment {
  Segment({required this.start, required this.end, this.removed = false});

  final Duration start;
  final Duration end;
  bool removed;

  Duration get length => end - start;
}

/// Editing state over the *source timeline* — all clips concatenated end to end.
/// Cut points divide it into segments (kept or X'd out); a crossfade can be
/// attached to any interior cut point. The clip layout itself lives in the page;
/// this model is source-time only.
class EditorModel extends ChangeNotifier {
  Duration _total = Duration.zero;

  /// Interior cut points (never 0 or [total]). Kept sorted & de-duplicated.
  final List<Duration> _points = <Duration>[];

  /// Removed-state keyed by the segment's start micros.
  final Set<int> _removedStartMicros = <int>{};

  /// Transition keyed by the cut-point micros it sits on.
  final Map<int, Transition> _transitions = <int, Transition>{};

  Duration get total => _total;
  List<Duration> get points => List.unmodifiable(_points);
  bool get hasContent => _total > Duration.zero;

  /// Reset the timeline to a new total length (clips changed). Clears edits.
  void setTimeline(Duration total) {
    _total = total;
    _points.clear();
    _removedStartMicros.clear();
    _transitions.clear();
    notifyListeners();
  }

  void clear() => setTimeline(Duration.zero);

  // ---------- Cut points ----------

  /// Add a cut point at [at]. Preserves the removed-state of the segment it
  /// splits, so adding a point never changes the output.
  void addPoint(Duration at) {
    if (_total == Duration.zero) return;
    const slop = Duration(milliseconds: 100);
    if (at <= slop || at >= _total - slop) return;
    for (final p in _points) {
      if ((p - at).abs() < slop) return;
    }
    final containing = _segmentContaining(at);
    _points.add(at);
    _points.sort();
    // If we split a removed segment, mark the new right half removed too.
    if (containing != null && containing.removed) {
      _removedStartMicros.add(at.inMicroseconds);
    }
    notifyListeners();
  }

  void clearPoints() {
    _points.clear();
    _removedStartMicros.clear();
    _transitions.clear();
    notifyListeners();
  }

  // ---------- Segments ----------

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

  Duration get keptDuration =>
      keptSegments.fold(Duration.zero, (acc, s) => acc + s.length);

  // ---------- Transitions ----------

  /// Transition attached to the cut point at [point]'s time.
  Transition transitionAt(Duration point) =>
      _transitions[point.inMicroseconds] ?? Transition.none;

  void setTransition(Duration point, Transition t) {
    final key = point.inMicroseconds;
    if (!t.isActive) {
      _transitions.remove(key);
    } else {
      _transitions[key] = t;
    }
    notifyListeners();
  }

  /// The cut points that are real seams in the output — i.e. the end of a kept
  /// segment that is followed by another kept segment. Only these can carry a
  /// meaningful transition.
  Set<int> get activeSeamMicros {
    final kept = keptSegments;
    final seams = <int>{};
    for (var i = 0; i < kept.length - 1; i++) {
      seams.add(kept[i].end.inMicroseconds);
    }
    return seams;
  }
}
