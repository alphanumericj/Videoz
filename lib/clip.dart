import 'dart:ui' show Size;

import 'package:path/path.dart' as p;

/// One source file in the clip list. [id] is a stable identity used as the
/// widget key for reordering (paths can repeat if the same file is added twice).
class Clip {
  Clip({required this.path, required this.duration, this.displaySize}) : id = _next++;

  static int _next = 0;

  final int id;
  final String path;
  final Duration duration;

  /// Frame size as displayed (after rotation); null for audio-only or unreadable files.
  final Size? displaySize;

  String get name => p.basename(path);
}
