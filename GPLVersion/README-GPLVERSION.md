# GPLVersion — preserved ffmpeg build

This is a frozen copy of Videoz as it existed **before** the switch to AVFoundation
(Path B). It works and is fine for personal/local use, but it is **not App Store
distributable** because:

- It shells out to the system Homebrew `ffmpeg` (an external binary — blocked by the
  macOS App Sandbox).
- That ffmpeg is a **GPL** build (it uses `libx264` for `-c:v libx264`), and GPL is
  incompatible with the App Store's terms.

The main `Videoz/` project supersedes this with a native AVFoundation implementation
(playback via `video_player`, export via a Swift `AVMutableComposition` /
`AVAssetExportSession` method channel) — no external binaries, no GPL/LGPL code,
sandbox-friendly.

To run this version:
```
cd GPLVersion
flutter pub get
flutter run -d macos
```
Requires `ffmpeg` on PATH (`brew install ffmpeg`).
