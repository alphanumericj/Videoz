/// Container for the saved file. The file extension decides the container
/// natively, so [extension] is also what the save dialog asks for.
enum ExportFormat {
  mp4('mp4', 'MP4'),
  mov('mov', 'MOV');

  const ExportFormat(this.extension, this.label);
  final String extension;
  final String label;
}

/// How much to shrink the video. [wire] names match the tiers in
/// macos/Runner/VideoExporter.swift, which owns the actual numbers (frame-size
/// cap on the short side, and bits per pixel).
enum Compression {
  none('none', 'None', 'Original size, best quality'),
  light('light', 'Light', 'Up to 1080p'),
  medium('medium', 'Medium', 'Up to 720p'),
  heavy('heavy', 'Heavy', 'Up to 480p');

  const Compression(this.wire, this.label, this.detail);
  final String wire;
  final String label;
  final String detail;
}

class ExportSettings {
  const ExportSettings({
    this.format = ExportFormat.mp4,
    this.compression = Compression.none,
  });

  final ExportFormat format;
  final Compression compression;
}
