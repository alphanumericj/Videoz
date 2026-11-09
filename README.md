# Videoz

A stupid-simple video editor for macOS. Open a file, mark cut points on the
timeline, click segments to "X" them out, then **Apply & Save** to write a new
file with the removed parts gone.

## How it works

- **Playback:** `video_player` (backed by AVFoundation / AVPlayer on macOS).
- **Editing model** (`lib/editor_model.dart`): cut points divide the file into
  numbered segments; un-X'd segments are kept and concatenated in order.
- **Export** (`lib/export_service.dart` → `macos/Runner/VideoExporter.swift`):
  a native Swift method channel builds an `AVMutableComposition` from the kept
  segments and writes it with `AVAssetExportSession`. Video exports as H.264 at
  native resolution; audio-only files export as `.m4a`.

Run it:
```
flutter run -d macos
```

## Architecture decision: AVFoundation, not ffmpeg (2026-08-17)

The first cut shelled out to Homebrew `ffmpeg`. That worked but is **not App
Store distributable**: it runs an external binary (blocked by the App Sandbox),
and the ffmpeg build was **GPL** (via `libx264`), which is incompatible with the
App Store's terms.

We switched to native AVFoundation for both playback and export. This uses only
Apple frameworks — **no external binaries, no GPL/LGPL code, sandbox-friendly** —
which is the clean path to eventual App Store distribution. AVFoundation's
composition API is also the natural home for the planned features (joining
multiple clips, fade transitions).

The original ffmpeg version is preserved, working, under [`GPLVersion/`](GPLVersion/).

## App Sandbox (2026-08-18)

The App Sandbox is **on** (`macos/Runner/*.entitlements`), with
`com.apple.security.files.user-selected.read-write` for the Open/Save panels.
This works with zero code changes because every file access goes through
`file_picker`'s native `NSOpenPanel`/`NSSavePanel`, presented in-process — the
sandbox automatically grants the app access to whatever the user selects, for
the life of the run. No bookmarks needed since nothing persists across
relaunches (the clip list is in-memory only). Temp preview files land in the
app's sandboxed container automatically (`Directory.systemTemp` redirects
there) — no entitlement needed for that.

Dropped `com.apple.security.cs.disable-library-validation`: it was only needed
for the old `media_kit`/mpv build's unsigned bundled binary. Everything now is
either an Apple framework or a CocoaPods plugin compiled from source as part of
the app, so it's unnecessary.

Verified: entitlements are embedded in the signed binary (`codesign -d
--entitlements :-`), the app has a sandbox container
(`~/Library/Containers/com.chipmania.videoz`), it launches with no sandbox
denials in the system log, and the container's `tmp/` is used for previews.

**Still needed before actual distribution** (not code changes, just signing/
packaging): a real Developer ID or Mac App Store signing identity + provisioning
profile (current builds are ad-hoc signed by Xcode for local use), and
notarization if distributing outside the App Store.

## The render model (multi-clip + transitions)

Everything is one **render**: the output is a flat list of *pieces* (a source
file plus an in/out time) joined by an optional crossfade (0 = hard cut). The
**same** native `render` call builds the live preview and the final Apply, so
the preview is exactly what gets written (WYSIWYG).

- **Source timeline** = all clips concatenated end to end. Cut points and X-outs
  live here. A cut point is auto-seeded at every clip boundary.
- **A transition is a property of any cut point.** Click the round handle on a
  seam (where two kept segments meet — a clip boundary *or* the gap left by an
  X'd-out middle) and pick a crossfade. Same machinery either way.
- **Preview re-renders on each output-changing edit** (X-out, transition, clip
  add/remove/reorder). Marking cut points stays instant (never changes output).
- The player plays the rendered *output*; the timeline is the *source*. The page
  maps between the two (`_layout` / `_sourceToOutput` / `_outputToSource`) so the
  playhead tracks correctly and jumps across removed regions.
- Native side: two-track A/B-roll `AVVideoComposition` (video opacity ramps) +
  `AVAudioMix` (audio volume ramps). Each overlap is clamped to half the shorter
  neighbouring piece.

### Page curl & bars swipe (2026-08-18)

Crossfade/fade-black/slide are built from AVFoundation's own opacity/transform/
crop-rect ramps. Page curl and bars swipe are different: they're Core Image
transition filters (`CIPageCurlTransition`, `CIBarsSwipeTransition`), which
AVFoundation's ordinary layer-instruction API can't reach at all. Using them
requires a custom `AVVideoCompositing` compositor — a per-frame render path
where *we* pull the raw source pixel buffers and produce the output frame
ourselves, via Core Image, instead of AVFoundation compositing them for us.

This lives entirely in a second code path (`renderCustom` +
`TransitionInstruction` + `TransitionCompositor` in `VideoExporter.swift`),
used **only** when a render includes page curl or bars swipe. Any render that
doesn't touches none of this — it's on the exact original, already-verified
crossfade/fadeblack/slide code path. When the custom path *is* used, solo
playback and all five transition types are reimplemented via Core Image (the
crossfade/fadeblack/slide math was verified to produce identical
boundary/midpoint luma values to the original AVFoundation-ramp version before
being wired in).

**`CIRippleTransition` is broken on this macOS version** — verified directly:
feeding it solid red/blue test images, its output is the shading input
*verbatim*, completely ignoring both real inputs, regardless of software or
Metal-backed `CIContext`. This is a system bug, not a usage mistake (six other
Core Image transition filters were tested the same way and work correctly).

Page curl's `inputShadingImage` (required — the filter returns `nil` output
without one) turned out to represent the *visible texture of the rolling
page's surface*, not a lighting multiplier as the parameter name suggests. A
dark→bright→dark gradient band (simulating a highlight down the roll) was
tuned empirically against real frames — a flat shading color renders as a
jarring flat slab.

**Page curl direction (2026-08-18):** `inputAngle`'s mapping from value to
fold-line orientation was mapped empirically by sweeping values against real
frames: the fold is **vertical** at 0°/180° (edges at left/right) and
**horizontal** at 90°/270° (edges at top/bottom), rotating continuously
between. **205°** gives a steep, backslash-like diagonal anchored toward the
top-right — steeper/more vertical than the first pass (235°, which read as
too shallow/horizontal). The shading band's direction is derived directly from
the angle (`bandDir = (cos angle, sin angle)`) rather than hardcoded to one
specific diagonal, so retuning the angle keeps the highlight/shadow aligned
with the fold automatically.

**Bars swipe → Blinds.** `CIBarsSwipeTransition` was initially chosen as the
Ripple substitute, but its actual look — a diagonal staggered sweep of
vertical bars — isn't what "Venetian blinds" evokes, and didn't match what was
wanted (horizontal strips widening from a centerline, like a row of
prism/flip-panel signs rotating in unison). No Core Image filter does that.
Built one by hand instead: a `blinds` type that procedurally draws N
horizontal bands (`CGContext` → grayscale mask, one growing centered strip per
band) and blends the two clips through it via `CIBlendWithMask`. Simpler and
more robust than wrestling an undocumented canned filter, since the growth
math is ours and fully understood.

## Filmstrip thumbnails (2026-08-18)

Each **kept** segment tile shows a mini filmstrip of its own thumbnails
instead of a flat numbered color — cells span exactly that segment's own time
range (not a shared global grid), so short and long segments each show a
proportionate number of frames. A **removed** segment keeps the plain
red-cross tile — no thumbnails there, since there's nothing to preview.

Native side: a `thumbnails` method-channel call batches `{path, time}`
requests, reuses one `AVAssetImageGenerator` per unique path, and returns
small JPEGs (200×200 max, quality 0.6) — timed at 15 frames in ~0.17s, so this
is cheap even across many segments. Dart side (`lib/timeline.dart`'s
`_SegmentFilmstrip`): every kept segment's requests are batched into **one**
native call per regeneration; results are cached by `(path, time)`, so
toggling a segment back and forth, or editing an unrelated part of the
timeline, reuses already-fetched frames instead of re-requesting them.
Regeneration is gated on a signature (row width + every segment's
start/end/removed-state + the clip list), so it only actually re-fetches when
something relevant changed.

## Convert and compress (2026-11-09)

**Apply & Save** now asks for a format (MP4 or MOV, MP4 by default) and a
compression level before the save panel opens.

- **Convert only.** One whole clip with no cuts or transitions and no
  compression is converted by copying its streams into the new container
  (`AVAssetExportPresetPassthrough`): instant and lossless. When that isn't
  possible (ProRes into an `.mp4`, for example) it falls back to a normal
  re-encode automatically.
- **Compression levels** (Light / Medium / Heavy = up to 1080p / 720p / 480p).
  The cap applies to the *short* side of the frame, so portrait video isn't
  squashed, and video is never scaled up. The video is encoded as H.264 in
  **constant-quality mode** (quality 0.65 / 0.55 / 0.45) through `AVAssetReader`
  + `AVAssetWriter`, with audio as 128 kbps AAC.
- **Why constant quality, not a bitrate?** The first version used a fixed
  bitrate per tier. Apple's encoder spends a fixed bitrate on every video,
  however static, so a 195 MB screen recording (1280x588, mostly still) only
  came down to 52 MB, while x264 at constant quality had made it 9.6 MB.
  x264 is GPL, so it can't ship in the app; the hardware encoder's own
  constant-quality mode adapts the same way. Same file, Heavy: 9.5 MB.
- **Why not the system export presets?** Tested on a 1080p clip: the Medium
  and Low presets ignore the frame size and force tiny output (568x320,
  224x128), and HighestQuality picks its own bitrate regardless of the source
  (a 2.8 MB low-bitrate 1080p recording came out at 7.5 MB).
- Because size depends on the footage, it isn't predictable ahead of time:
  calm screen recordings shrink a lot, busy gameplay or camera footage less.
  The snackbar after saving shows the resulting size.
- Measured: `GG.mov` (195 MB, 3.5 min, 1280x588 screen recording) gives Light
  29.8 MB, Medium 20.3 MB, Heavy 9.5 MB. A 10 second 1080p, 20 Mbps clip
  (23.4 MB) gives None 12.3 MB (preset), Medium 2.2 MB; convert-only copies a
  file in about 0.1 s.
- This works with transitions too, including the custom page curl/blinds
  compositor, since the writer reads the composed frames.
- The native tiers live in `Settings` in `macos/Runner/VideoExporter.swift`;
  `lib/export_settings.dart` only holds the names (a unit test keeps them in
  sync).

## Blur boxes (2026-11-09)

Hide a face, a license plate, confidential text: mark the video just before the
thing appears and just after it disappears (the existing **Mark point**), put the
playhead on any frame between, press **Blur box**, drag a rectangle over it,
pick how pixelated (three thumbnails of your own box), and press **Blur**. The
app follows it through the whole stretch, forward and backward, and pixelates it.

- **Four looks** (see "Blur styles" below). Pixelate comes with three scales (Fine / Medium / Coarse = 10 / 6 / 3 blocks
  across the box's shorter side, so a small face and a wide banner look alike).
  Core Image's `CIPixellate`, inside the same custom compositor as page curl and
  blinds, so the preview and the saved file match.
- **The stretch you mark is the range.** The app is never asked "is it gone?",
  only "where is it?". A blur keeps its own clip-local time range, so adding or
  moving cut points later doesn't change it, and reordering clips doesn't break it.
- **Tracking** is Apple's Vision object tracker (`VNTrackObjectRequest`) on upright
  frames shrunk to 960 px, run from the drawn frame forward to the end mark and
  backward to the start mark (backward by reading one second at a time and
  feeding it in reverse). About 500 to 750 frames per second; 20 s of 60 fps
  video took 1.2 s.
- **The tracker is not trusted.** Tests on `GG.mov` showed it can drift while
  reporting high confidence (scrolling text clipped by half while it read 0.91),
  switch to a different object after an occlusion (the rocket hit an asteroid),
  and shrink onto the most distinctive part of a rotating object. So:
  - the box is padded 20% on every side (at least 1.2% of the short side), and
    it can only shrink as fast as the last and next 0.6 s allow (never below 80% of
    the biggest it was in that window, or a quarter of what you drew). A real
    zoom-out is gradual, so the box follows it down; a fast wobble (a rotating
    object's thin side view) is held up. This replaced a fixed 55% floor that
    stopped the box shrinking when an object receded: measured on the scrolling
    intro text, width went 0.46 to 0.26 and stalled; now it goes 0.46 to 0.14;
  - where confidence drops under 0.35 the box is held at its last good position,
    and that stretch is drawn **red** under the timeline and the box outline turns
    red on the preview;
  - exporting with red stretches asks you to check them first;
  - the preview is the review: the pixelation (and an outline) shows in the player.
- **Fix box on this frame** (right-click a pixelated area, or a bar under the
  timeline): redraw the box on a frame where it's off. It re-tracks only between
  the nearest hand-placed frames on either side, so earlier fixes stay.
- **Right-click** a pixelated area (or its bar) for Remove blur (the whole stretch),
  Fix box, and a different pixelation. While drawing, the Blur box button becomes Cancel blur (Escape also cancels), and
  there's no banner over the video that could cover what you want to box.
- Blurred video can't use the "convert by copying" shortcut (it would keep the
  original pixels); it is always re-rendered.
- Not covered: audio (voices) and file metadata. Watch the exported file through
  before sharing.
- Coordinates: a drawn box is converted from the preview canvas to the clip's own
  displayed frame (`FrameMapper` in `lib/blur_region.dart`, unit tested), because
  the preview letterboxes clips whose shape differs from the first clip's. The
  renderer maps it back with the same aspect-fit.

**Bug found and fixed along the way:** the custom compositor (page curl, blinds,
and now blur) drew rotated clips (phone video) upside down, because the fit
transform is in AVFoundation's top-left coordinates and Core Image is bottom-left.
It now flips on the way in and out. Also checked: it reproduces the source's
colors exactly.


## Blur styles (2026-11-09)

Picked in the same dialog as the strength (with previews of your own box), and
changeable later from the right-click menu:

- **Pixelate**: Fine / Medium / Coarse.
- **Frosted blur**: a smooth, cloudy-lens Gaussian blur with a feathered edge;
  Light / Medium / Heavy. A light blur on small text can stay partly legible, so use
  Heavy for anything that must not be read.
- **Black box**: solid, nothing recoverable.
- **Match background**: samples the colors just outside the box on all four sides
  and fills the box with a smooth blend of them (feathered edge), so text on a plain
  or gently shaded background mostly vanishes. Works best on plain backgrounds; busy
  ones come out as a soft smear.

Tried and dropped: a frosted-glass distortion and a fog/white veil (both looked poor).
Considered but not added: swirl/twirl (reversible, so not safe for hiding anything).

## Blur text (2026-11-09)

A second blur for text, next to **Blur box**. The object blur follows a box through
a stretch you marked, so after text disappeared it kept pixelating the empty spot.
Text blur instead *reads* the text and looks for it again, so it finds every place
the phrase appears (several at once, moving, switching position) and stops when the
text does.

Flow: mark before and after the text is on screen, put the playhead on a frame where
it's readable, press **Blur text**, drag a box around it. A dialog shows what was
read in the box, one editable line each (checkbox to leave one out), and the three
pixelation previews. **Find and blur** then reads the marked stretch and blurs every
match.

- **Reading and finding** is Vision's text recognizer (`VNRecognizeTextRequest`,
  accurate mode, no language correction, so names and street names stay as printed),
  about 8 frames a second of the marked stretch. `VNRecognizedText.boundingBox(for:)`
  gives the box of just the matched part of a line, so "123 Main Street" inside
  "Deliver to 123 Main Street, Tucson AZ" boxes only the address.
- **Matching** ignores capitals, accents, punctuation and spacing, and forgives
  misread characters (none for 4 or fewer letters, 1 up to 9, 2 up to 18, 3 beyond).
  Each phrase line is searched separately; a phrase that wraps across two lines on
  screen is found as its separate lines only if each was entered separately.
- **Gaps:** the reader misses frames now and then, so each find also covers 0.2 s
  before and 0.3 s after, and two finds under 0.8 s apart count as one stretch (both
  finds' boxes apply across the gap, which also covers motion). The frame you drew
  on is always covered. These constants live in `BlurRegion` in `lib/blur_region.dart`
  and are sent to the renderer as ready-made time stretches, so the on-screen outlines
  and the saved file agree.
- **Padding** for text is a third of the text's height all round (not a fifth of its
  width, which on a long phrase would eat the neighboring words).
- The bar under the timeline is **solid only where text was found and blurred**, faint
  over the rest of the marked range, and its tooltip says "found in N of M frames read".
  The search can be cancelled from the status line.
- **Measured** (`GG.mov`, 1280x588): the careful mode reads about 3 frames a second
  (the fast mode 80, but it read the phrase in only 7 of 120 frames); a 12 s stretch
  sampled at 8/s took 9.5 s. On the receding intro paragraph an exact search found the
  phrase in 38 of 120 frames; fuzzy matching found 63 of 96 and, bridged, covered 8.3 of
  12 s, stopping where the text became too small to read (about 8 s in). On a synthetic
  clip with the same address in three places (one static and vanishing at 4 s, one
  lowercase and drifting, one inside a longer line) and a different address as a decoy:
  found in 48 of 48 frames, 2 then 3 then 2 boxes at the right moments, the decoy never
  touched.
- **Limits:** small, stylized or perspective-warped text is missed on some frames, and
  the app can't prove text *isn't* there when the reader fails, so the preview is still
  the review.

**Bug found and fixed along the way:** a video with **no audio track** failed to
export on the uncompressed path with "Operation Stopped" (the empty audio tracks the
composition always creates stop `AVAssetExportSession`), which also broke the live
preview of any edit to a silent clip. Empty audio tracks, and any mix parameters
pointing at them, are now dropped before exporting.

## Roadmap

- [x] Join multiple separate clips
- [x] Crossfade at any cut point (clip boundary or within a video)
- [x] More transitions (fade to black, slide) — picked in the same popup as duration
- [x] Filmstrip thumbnails on the timeline
- [x] Convert to MP4/MOV and compress on save
- [x] Blur (pixelate) a tracked box over a marked stretch, with fix and remove
- [x] Blur text: read it, find every occurrence in the marked stretch, blur them
- [ ] Bulk "crossfade all joins" convenience control
- [ ] Draggable / individually-deletable cut points
- [ ] Live preview without re-render (native AVPlayer view) for long clips
- [x] Re-enable App Sandbox + file entitlements for distribution
