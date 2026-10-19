# Straighten the picture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-camera Straighten/Level correction, set with two sliders on the camera's web page, that every viewer of the camera on
Camera Bridge OS sees (web live view, Monitor, playback, Apple Home live view, HKSV, snapshots, saved clips) while recordings on disk
stay as the camera sent them.

**Architecture:** One formula (`PictureCorrection` in MediaCore, mirrored in `linux/web/js/live/straighten.js`, both pinned by one
table of test vectors). The browser applies it on the GPU (WebGL, 2D-canvas fallback) to every `<video>`/`<img>` of a camera. The box
applies it in ffmpeg with `remap` (maps written by Swift from the formula, warped at twice the height and shrunk, because `remap`
only picks the nearest pixel) in three places: the Linux transcoder (Apple Home live/HKSV), a one-shot JPEG step (snapshots), and the
clip re-encode (saved clips). Settings change in place: no runtime restart, so NVR recording never restarts.

**Tech Stack:** Swift 6.4 / Swift Testing (Packages/CameraBridgeKit), ffmpeg 7.1 (box) / 8.x (Mac, Docker), vanilla JS modules +
WebGL 1, Node's test runner (`linux/web-tests`).

**Spec:** `docs/superpowers/specs/2026-10-18-straighten-the-picture-design.md` (approved by the owner 2026-10-18).

## Global Constraints

- The formula, verbatim from the spec: `u = (x − W/2)/(W/2)`, `h = clamp(0.5 + a·(1 − u²) + b·u, 0.03, 0.97)`,
  `T = clamp(0.5 + (2/3)·a, 0.03, 0.97)`, `f = y/H`, `fs = f ≤ T ? f·h/T : h + (f − T)·(1 − h)/(1 − T)`, source = `(x, fs·H)`, bilinear,
  vertical only. In this plan it is written resolution-free: `across = x/W`, `down = f`, result `fs` (pixel i's centre is `(i + 0.5)/size`).
- Stored values: `straighten` (a) −0.60…+0.60, `level` (b) −0.40…+0.40, two decimals (sliders show −60…60 and −40…40); both 0 = off.
  Positive Straighten = horizon sags in the middle; positive Level = horizon lower on the right.
- Recordings on disk are never changed. A setting change never restarts the camera's runtime (that would close the NVR file).
- A camera with the correction off costs nothing anywhere (no canvas, no transcode, no ffmpeg step).
- Camera Bridge OS only: the Mac's codecs report the correction unsupported, and the engine then treats it as off everywhere.
- No black edges, no crop, same picture shape, on every output.
- Exact copy (card): title **Straighten the picture**; sliders **Straighten** and **Level**; button **Reset**; the line "Applies everywhere
  this camera is seen: live view, the Monitor, recordings, saved clips and Apple Home. Recordings keep the camera's original picture."
- Tests and docs use 192.168.77.x / 192.0.2.x addresses; the owner's camera frames stay local (never committed).
- The Mac app (`App/`) is out of scope. Nothing is published or released without the owner's yes.
- Swift tests: `swift test --filter <Suite>` in `Packages/CameraBridgeKit` (macOS) and `sh Tools/linux-test.sh test --filter <Suite>`
  (Linux, Docker) for anything in PlatformLinux. Web tests: `sh linux/web-tests/run.sh` from the repository root.

## Review Focus

1. **Letterboxed Apple Home sizes.** Home asks 1920×1080 of a 4256×1888 camera: the picture is fitted to 1920×852 and padded. The warp
   must apply to the 1920×852 picture before the pad (bars stay plain black, the horizon lands at T of the picture, not of the frame).
   Test in Task 3 (`aLetterboxedPictureIsStraightenedBeforeItIsPadded`).
2. **The label and the warp together.** A camera with both the timestamp label and the correction on: the label is drawn after the warp
   (upright, in its corner, never bent), in the transcoder and in saved clips. Tests in Task 3 and Task 6 (filter order).
3. **A slider change while Home is watching or a snapshot is cached.** The running transcoder must pick up the new values at its next
   picture (one child restart), and a snapshot made with the old values must never be served for the new ones. Tests in Task 3
   (`aRunningTranscoderRestartsOnceWhenTheCorrectionChanges`) and Task 5 (`aCachedPictureIsNotReusedAfterTheCorrectionChanges`).
4. **The box cannot write the maps** (scratch directory missing or full). Video must keep flowing, uncorrected, with one warning, never
   a crash loop. Test in Task 3 (`withoutAScratchDirectoryTheTranscoderRunsUncorrected`).
5. **Browsers without WebGL, or out of WebGL contexts** (a Monitor wall of many corrected tiles, a lost context). Every corrected tile
   still shows the straightened picture through the 2D-canvas strip fallback. Test in Task 7 (`stripPlanCoversEveryColumnOnce` and
   `aViewFallsBackTo2DWhenWebGLIsRefused`).

---

### Task 1: The formula (`PictureCorrection`) and its shared test vectors

**Files:**
- Create: `Tools/picture-correction-vectors.py`
- Create: `Packages/CameraBridgeKit/Tests/MediaCoreTests/Fixtures/picture-correction-vectors.json` (generated, committed)
- Create: `Packages/CameraBridgeKit/Sources/MediaCore/PictureCorrection.swift`
- Create: `Packages/CameraBridgeKit/Tests/MediaCoreTests/PictureCorrectionTests.swift`
- Modify: `Packages/CameraBridgeKit/Package.swift` (MediaCoreTests target: `exclude: ["Fixtures"]`)
- Modify: `Packages/CameraBridgeKit/Sources/MediaCore/README.md`

**Interfaces:**
- Produces (MediaCore, public):
  - `struct PictureCorrection: Sendable, Codable, Equatable, Hashable` with `var straighten: Double`, `var level: Double`,
    `init(straighten: Double = 0, level: Double = 0)` (clamps to the limits, rounds to 0.01, non-finite → 0),
    `static let off`, `static let straightenLimit = 0.60`, `static let levelLimit = 0.40`, `var isOff: Bool`.
  - `func horizon(across: Double) -> Double` (h), `var landing: Double` (T), `func sourceFraction(across: Double, down: Double) -> Double`
    (fs, clamped to 0…1), `var largestStretch: Double` (max of `T/h` and `(1−T)/(1−h)` over 256 columns at across = (i + 0.5)/256).
  - Decoding: missing or unreadable `straighten`/`level` → 0; out-of-range → clamped (never throws).
  - `protocol PictureCorrectionProviding: Sendable { var current: PictureCorrection? { get } }` (nil: off) and
    `struct StaticPictureCorrection: PictureCorrectionProviding` (`init(_ correction: PictureCorrection?)`; `.current` is nil when off).
  - The vectors file: `{"vectors": [{"straighten", "level", "across", "down", "source"}…]}`.

- [ ] **Step 1: Write the vector generator** (`Tools/picture-correction-vectors.py`, standard library only; it is the spec's formula,
  written independently of the Swift and JS code it pins):

```python
#!/usr/bin/env python3
"""Writes the shared test vectors of Straighten the picture (docs/superpowers/specs/2026-10-18-straighten-the-picture-design.md)."""
import json, sys
def clamp(v, lo, hi): return min(hi, max(lo, v))
def source(a, b, across, down):
    u = 2 * across - 1
    h = clamp(0.5 + a * (1 - u * u) + b * u, 0.03, 0.97)
    t = clamp(0.5 + 2 / 3 * a, 0.03, 0.97)
    fs = down * h / t if down <= t else h + (down - t) * (1 - h) / (1 - t)
    return clamp(fs, 0, 1)
settings = [(0, 0), (0.40, 0.15), (-0.40, -0.15), (0.60, 0.40), (-0.60, -0.40), (0.60, -0.40), (0, 0.40), (0.25, 0)]
points = [0, 0.001, 0.1, 0.25, 0.5, 0.75, 0.9, 0.999, 1]
vectors = [dict(straighten=a, level=b, across=x, down=y, source=round(source(a, b, x, y), 12))
           for a, b in settings for x in points for y in points]
for a, b in settings[1:]:   # the landing row itself, where the two pieces meet
    t = clamp(0.5 + 2 / 3 * a, 0.03, 0.97)
    vectors += [dict(straighten=a, level=b, across=x, down=t, source=round(source(a, b, x, t), 12)) for x in (0, 0.3, 0.5, 1)]
json.dump({"vectors": vectors}, sys.stdout, indent=1)
print()
```

- [ ] **Step 2: Generate the fixture**

Run: `python3 -I Tools/picture-correction-vectors.py > Packages/CameraBridgeKit/Tests/MediaCoreTests/Fixtures/picture-correction-vectors.json`
Expected: a JSON file with 676 vectors (8 settings × 81 points + 7 × 4 landing points).

- [ ] **Step 3: Write the failing tests** (`PictureCorrectionTests.swift`, suite `PictureCorrectionTests`; the fixture is read through
  `#filePath` like `HDSFixtureGoldenTests`):

```swift
@Test func everyVectorMatches() throws {
    for v in try vectors() {
        let c = PictureCorrection(straighten: v.straighten, level: v.level)
        #expect(abs(c.sourceFraction(across: v.across, down: v.down) - v.source) < 1e-9, "\(v)")
    }
}
@Test func offIsTheIdentity() { for d in stride(from: 0.0, through: 1, by: 0.05) { #expect(PictureCorrection.off.sourceFraction(across: 0.3, down: d) == d) } }
@Test func topAndBottomStayAndEveryColumnIsIncreasing() // settings: (±0.60, ±0.40), (0.40, 0.15); 101 columns × 101 rows:
    // fs(across, 0) == 0, fs(across, 1) == 1, fs strictly increasing in down, 0 ≤ fs ≤ 1
@Test func valuesAreClampedAndRounded() {
    #expect(PictureCorrection(straighten: 2, level: -1) == PictureCorrection(straighten: 0.60, level: -0.40))
    #expect(PictureCorrection(straighten: 0.404, level: 0.151).straighten == 0.40)
    #expect(PictureCorrection(straighten: .nan, level: .infinity) == .off)
    #expect(PictureCorrection(straighten: 0, level: 0).isOff && !PictureCorrection(straighten: 0.01).isOff)
}
@Test func decodingNeverFails() throws {
    // {} → .off; {"straighten": 0.4} → (0.40, 0); {"straighten": "x", "level": 0.15} → (0, 0.15); {"straighten": 9} → (0.60, 0)
}
@Test func backyardStretchesAboutTwoPointSevenTimes() {
    // (0.40, 0.15): landing ≈ 0.766667, horizon(across: 0) == 0.35, largestStretch ≈ 2.71496 (the ground just below the
    // horizon near the middle, where the horizon sits lowest); (0.10, 0): largestStretch ≈ 1.13157
}
@Test func theStaticProviderIsNilWhenOff() { #expect(StaticPictureCorrection(.off).current == nil) }
```

- [ ] **Step 4: Run them to see them fail**

Run: `cd Packages/CameraBridgeKit && swift test --filter PictureCorrectionTests`
Expected: FAIL (`cannot find 'PictureCorrection' in scope`).

- [ ] **Step 5: Implement `PictureCorrection`, `PictureCorrectionProviding` and `StaticPictureCorrection` in `PictureCorrection.swift`**
  (the formula exactly as in Global Constraints; decoding follows `TimestampOverlaySettings.init(from:)`'s "every unreadable key falls
  back" style). Add `exclude: ["Fixtures"]` to the MediaCoreTests target. Describe the type in `Sources/MediaCore/README.md`.

- [ ] **Step 6: Run the tests and the fixture-usage check**

Run: `swift test --filter "PictureCorrectionTests|FixtureUsageTests"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Tools/picture-correction-vectors.py Packages/CameraBridgeKit/Package.swift Packages/CameraBridgeKit/Sources/MediaCore Packages/CameraBridgeKit/Tests/MediaCoreTests
git commit -m "Straighten the picture: the formula (PictureCorrection) and its shared test vectors"
```

---

### Task 2: The camera's setting, its API and in-place updates

**Files:**
- Modify: `Packages/CameraBridgeKit/Sources/BridgeEngine/Configuration/Configuration.swift` (property near line 110, `CodingKeys` line 183,
  decoding near line 223)
- Modify: `Packages/CameraBridgeKit/Sources/BridgeEngine/BridgeEngine.swift` (`needsRestart` near line 2615)
- Modify: `Packages/CameraBridgeKit/Sources/BridgeWeb/WebApp+Routes.swift` (`CameraPatch` near line 398, applying it near line 479)
- Modify: `docs/CONTRACT_CHANGES.md`, `Packages/CameraBridgeKit/Sources/BridgeEngine/README.md`
- Test: `Packages/CameraBridgeKit/Tests/BridgeEngineTests/PictureCorrectionEngineTests.swift` (new),
  `Packages/CameraBridgeKit/Tests/BridgeWebTests/CameraAPITests.swift`

**Interfaces:**
- Consumes: `PictureCorrection` (Task 1).
- Produces: `CameraConfiguration.pictureCorrection: PictureCorrection` (default `.off`, JSON key `pictureCorrection`); the camera
  resource carries it; `PATCH /api/v1/cameras/:id` accepts `{"pictureCorrection": {"straighten": 0.4, "level": 0.15}}` (the whole value);
  `needsRestart` ignores it (Task 4 applies it to the running camera).

- [ ] **Step 1: Write the failing tests**

```swift
// PictureCorrectionEngineTests
@Test func aConfigurationWrittenBeforeTheSettingExistedLoadsWithItOff()   // decode a camera JSON without the key → .off
@Test func theSettingRoundTrips()                                          // (0.40, 0.15) encode → decode equal
@Test func changingOnlyTheCorrectionNeverRestartsTheRuntime() {
    var new = old; new.pictureCorrection = PictureCorrection(straighten: 0.4, level: 0.15)
    #expect(!BridgeEngine.needsRestart(old, new, paired: true) && !BridgeEngine.needsRestart(new, old, paired: false))
}
// CameraAPITests
@Test func patchingTheCorrectionSavesItAndTheCameraShowsIt()   // PATCH (0.4, 0.15) → 200; GET camera → pictureCorrection {0.4, 0.15}
@Test func anOutOfRangeCorrectionIsClampedNotRefused()          // PATCH {"straighten": 5, "level": -5} → saved (0.60, -0.40)
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "PictureCorrectionEngineTests|CameraAPITests"`
Expected: FAIL (no member `pictureCorrection`).

- [ ] **Step 3: Implement**
  - `CameraConfiguration.pictureCorrection` with a doc comment pointing at the spec and CONTRACT_CHANGES; add to `CodingKeys` and
    `value(.pictureCorrection, default: .off)` in `init(from:)`.
  - `needsRestart`: `comparable.pictureCorrection = old.pictureCorrection` with the comment "applied in place (`updatePictureCorrection`):
    a restart would close the camera's NVR file".
  - `CameraPatch.pictureCorrection: PictureCorrection?`; applied as a whole value.
  - CONTRACT_CHANGES: a 2026-10-18 row (the field, its range, the PATCH shape, "applied in place, never restarts the camera").

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "PictureCorrectionEngineTests|CameraAPITests|TimestampOverlayEngineTests"`
Expected: PASS.

- [ ] **Step 5: Commit** (`git commit -m "Straighten the picture: the camera's setting, its API, applied in place"`)

---

### Task 3: The warp on the box (ffmpeg `remap`) in the Linux transcoder

**Files:**
- Create: `Packages/CameraBridgeKit/Sources/MediaCore/PictureCorrection+Remap.swift`
- Create: `Packages/CameraBridgeKit/Sources/PlatformLinux/Codecs/RemapScratch.swift`
- Modify: `Packages/CameraBridgeKit/Sources/MediaCore/Codecs.swift` (protocol + defaults)
- Modify: `Packages/CameraBridgeKit/Sources/PlatformLinux/Codecs/FFmpegArguments.swift` (`VideoPipelineSpec`, `transcoder`, `videoFilters`)
- Modify: `Packages/CameraBridgeKit/Sources/PlatformLinux/Codecs/FFmpegVideoTranscoder.swift`
- Modify: `Packages/CameraBridgeKit/Sources/PlatformLinux/Codecs/FFmpegMediaCodecs.swift`, `Sources/PlatformLinux/Codecs/README.md`
- Test: `Tests/MediaCoreTests/PictureCorrectionTests.swift`, `Tests/PlatformLinuxCodecsTests/ArgumentTests.swift`,
  `Tests/PlatformLinuxCodecsTests/FakeTranscoderTests.swift`, `Tests/PlatformLinuxCodecsTests/VideoTranscoderTests.swift`

**Interfaces:**
- Consumes: `PictureCorrection`, `PictureCorrectionProviding` (Task 1).
- Produces:
  - MediaCore: `static let remapSupersample = 2`; `PictureCorrection.remapMaps(width: Int, height: Int) -> (x: Data, y: Data, chromaX: Data, chromaY: Data)`:
    16-bit PGM images (`P5\n<w> <h>\n65535\n`, big-endian). Luma maps are `width × (2·height)`: x map = column index; y map at (x, r) =
    `clamp(floor(sourceFraction(across: (x+0.5)/width, down: (r+0.5)/(2·height)) · 2·height), 0, 2·height − 1)`. Chroma maps are
    `(width/2) × height` (width even): chroma x = column index; chroma y at (cx, cr) =
    `clamp(floor(sourceFraction(across: (cx+0.5)/(width/2), down: (cr+0.5)/height) · height), 0, height − 1)`.
    `PictureCorrection.ffmpegRemapChain(input: String, width: Int, height: Int, xMap: String, yMap: String, chromaXMap: String, chromaYMap: String, output: String) -> String`
    (labels are filter-graph pad names, without brackets) returning exactly
    `[<input>]scale=<w>:<2h>:flags=bicubic,format=yuv420p,extractplanes=y+u+v[cbpy][cbpu][cbpv];[<xMap>]format=gray16[cbx];[<yMap>]format=gray16[cby];[<chromaXMap>]format=gray16,split[cbcx1][cbcx2];[<chromaYMap>]format=gray16,split[cbcy1][cbcy2];[cbpy][cbx][cby]remap=format=gray[cbry];[cbpu][cbcx1][cbcy1]remap=format=gray[cbru];[cbpv][cbcx2][cbcy2]remap=format=gray[cbrv];[cbry][cbru][cbrv]mergeplanes=map0s=0:map0p=0:map1s=1:map1p=0:map2s=2:map2p=0:format=yuv420p,scale=<w>:<h>:flags=area[<output>]`
    (warp at twice the height, then shrink: plain `remap` at the output size stair-steps power lines on the Backyard frame. Each 4:2:0
    plane is warped as gray, because `remap` takes no subsampled formats: on the box's N150 this adds about 18 ms per 1920×852 picture,
    half of what a 4:4:4 warp costs, at the same quality; ruling R6, 2026-10-18).
  - `MediaCodecs`: `var supportsPictureCorrection: Bool { get }` (default `false`);
    `func makeVideoTranscoder(output: VideoEncoderSettings, overlay: (any TimestampOverlayProviding)?, correction: (any PictureCorrectionProviding)?) throws -> any VideoTranscoding`
    (default: ignores `correction`, calls `makeVideoTranscoder(output:overlay:)`).
  - PlatformLinux: `struct RemapStage: Equatable, Sendable { var xMap: String; var yMap: String; var chromaXMap: String; var chromaYMap: String; var width: Int; var height: Int }`;
    `VideoPipelineSpec.correction: RemapStage?`; `FFmpegArguments.fittedSize(sourceWidth:sourceHeight:width:height:) -> (width: Int, height: Int)`
    (aspect kept, fits inside, even, ≥ 2; the size `force_original_aspect_ratio=decrease` gives);
    `final class RemapScratch` (`init(parent: URL?) throws`, private 0700 directory like `OverlayScratch`,
    `func stage(for correction: PictureCorrection, width: Int, height: Int) throws -> RemapStage` writing the four maps atomically only
    when (correction, size) changed, `remove()` in `deinit`). `FFmpegMediaCodecs.supportsPictureCorrection == true`.

- [ ] **Step 1: Write the failing tests**

```swift
// PictureCorrectionTests (MediaCore)
@Test func theMapsAreTwiceAsTallAndFollowTheFormula() {
    let maps = PictureCorrection(straighten: 0.4, level: 0.15).remapMaps(width: 64, height: 32)
    // header "P5\n64 64\n65535\n"; x(10, r) == 10; y(0, 63) == 63 (bottom row stays); y(32, 0) == 0 (top row stays);
    // y(x, r) == clamp(floor(fs·64)) for 20 sampled (x, r)
}
@Test func offMapsAreTheIdentity()   // y(x, r) == r for every pixel of a 16×8 map pair
@Test func theRemapChainIsExact() {
    #expect(PictureCorrection.ffmpegRemapChain(input: "0:v:0", width: 1920, height: 852, xMap: "1:v", yMap: "2:v", chromaXMap: "3:v", chromaYMap: "4:v", output: "cbw")
        == "[0:v:0]scale=1920:1704:flags=bicubic,format=yuv420p,extractplanes=y+u+v[cbpy][cbpu][cbpv];[1:v]format=gray16[cbx];[2:v]format=gray16[cby];[3:v]format=gray16,split[cbcx1][cbcx2];[4:v]format=gray16,split[cbcy1][cbcy2];[cbpy][cbx][cby]remap=format=gray[cbry];[cbpu][cbcx1][cbcy1]remap=format=gray[cbru];[cbpv][cbcx2][cbcy2]remap=format=gray[cbrv];[cbry][cbru][cbrv]mergeplanes=map0s=0:map0p=0:map1s=1:map1p=0:map2s=2:map2p=0:format=yuv420p,scale=1920:852:flags=area[cbw]")
}
// ArgumentTests (PlatformLinux)
@Test func aCorrectedTranscoderReadsTheMapsAndUsesAFilterGraph()
    // spec 1920×1080 from a 1920×1080 source, correction maps "/s/x.pgm" "/s/y.pgm" "/s/cx.pgm" "/s/cy.pgm": arguments contain
    // ["-f", "flv", "-i", "pipe:0", "-i", "/s/x.pgm", "-i", "/s/y.pgm", "-i", "/s/cx.pgm", "-i", "/s/cy.pgm"], "-filter_complex" (no "-vf"), and ["-map", "[cbv]"];
    // the graph starts with the select filter, then the remap chain, then format=yuv420p
@Test func aLetterboxedPictureIsStraightenedBeforeItIsPadded()
    // source 4256×1888 → output 1920×1080: the graph has "scale=1920:1704" and "scale=1920:852:flags=area" before
    // "pad=1920:1080:(ow-iw)/2:(oh-ih)/2"; fittedSize(4256, 1888, 1920, 1080) == (1920, 852)
@Test func theLabelIsDrawnAfterTheWarp()     // with overlay and correction: "remap" index < "drawtext" index in the graph
@Test func withoutACorrectionTheArgumentsAreUnchanged()   // correction nil → byte-identical to today's (golden of the current output)
@Test func vaapiStillUploadsLast()           // .vaapi backend + correction: the graph ends "format=nv12,hwupload[cbv]"
// VideoTranscoderTests (real ffmpeg; skip when !FFmpegTesting.available)
@Test func aCorrectedTranscoderMakesVideoOfTheRequestedSize()   // sourceFrames 320×180 → 320×180 with (0.4, 0.15): output frames, keyframe first
// FakeTranscoderTests (fake launcher, like theTimestampOverlayIsADrawtextFilterAndRestartsWhenItsLayoutChanges)
@Test func aRunningTranscoderRestartsOnceWhenTheCorrectionChanges()
    // a mutable provider: off → (0.4, 0.15) between two GOPs: exactly one new child whose arguments have "remap"; no restart when the
    // same value is set again
@Test func withoutAScratchDirectoryTheTranscoderRunsUncorrected()
    // like anOverlayWithoutAScratchDirectoryIsLeftOutWithoutRestartingTheChild: frames still come out, no "remap", one warning, no restart loop
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "PictureCorrectionTests|ArgumentTests|FakeTranscoderTests|VideoTranscoderTests"`
Expected: FAIL (missing `remapMaps`, `correction`).

- [ ] **Step 3: Implement**
  - The MediaCore pieces and the `MediaCodecs` additions with their defaults.
  - `FFmpegArguments.transcoder`: when `spec.correction` is set, add the two map inputs after `pipe:0` and build the graph
    `[0:v:0]<select,>…` → remap chain at the fitted size → `pad`/`setsar` when the fitted size differs from the output → `drawtext` →
    `format=yuv420p` (or `format=nv12,hwupload`) → `[cbv]`, then `-map [cbv]`; everything else (`-copyts`, `-fps_mode passthrough`,
    `-force_key_frames`, encoder options) stays. Without a correction the arguments are exactly today's. `rawEncoder` ignores `correction`.
  - `FFmpegVideoTranscoder`: a `correction: (any PictureCorrectionProviding)?` init parameter next to `overlay`; `Run` keeps the
    `PictureCorrection?` it was started with; the restart check (`overlayKey(state:) != run.overlayKey`) gains
    `currentCorrection() != run.correction`; the start makes the stage through a lazily made `RemapScratch` in
    `runtime.configuration.scratchDirectory` (a failure sets `correctionUnavailable`, warns once, and runs uncorrected, as
    `overlayUnavailable` does). The start log line gains ", straightened" when a stage is used.
  - `FFmpegMediaCodecs`: `supportsPictureCorrection = true` and the three-argument `makeVideoTranscoder`. README rows updated.

- [ ] **Step 4: Run the tests (macOS and Linux)**

Run: `swift test --filter "PictureCorrectionTests|ArgumentTests|VideoTranscoderTests"` and
`sh Tools/linux-test.sh test --filter "PictureCorrectionTests|ArgumentTests|VideoTranscoderTests|FakeTranscoderTests"`
Expected: PASS.

- [ ] **Step 5: Commit** (`git commit -m "Straighten the picture: the Linux transcoder warps with ffmpeg remap"`)

---

### Task 4: The engine uses it (Apple Home live view and HKSV)

**Files:**
- Create: `Packages/CameraBridgeKit/Sources/BridgeEngine/Runtime/PictureCorrectionControl.swift`
- Modify: `Sources/BridgeEngine/Delegates/MediaFit.swift` (lines 72-125, 190-215)
- Modify: `Sources/BridgeEngine/Delegates/LiveStreamPipeline.swift` (context near line 152; lines 702, 835-860, 899-935)
- Modify: `Sources/BridgeEngine/Delegates/RecordingProducer.swift` (lines 60-80, 300-310, 395-410), `Sources/BridgeEngine/Delegates/RecordingHandler.swift`
- Modify: `Sources/BridgeEngine/Runtime/CameraRuntime.swift` (near line 242 and `updateTimestampOverlay` near line 807)
- Modify: `Sources/BridgeEngine/BridgeEngine.swift` (the in-place branch near line 565)
- Modify: `Sources/BridgeEngine/README.md`
- Test: `Tests/BridgeEngineTests/PictureCorrectionEngineTests.swift`, `Tests/BridgeEngineTests/MediaFitTests.swift` (or wherever
  `theOverlayForcesALiveTranscodeThatWouldOtherwisePassThrough` lives: `TimestampOverlayEngineTests.swift`)

**Interfaces:**
- Consumes: `CameraConfiguration.pictureCorrection` (Task 2); `MediaCodecs.supportsPictureCorrection`, the three-argument
  `makeVideoTranscoder` (Task 3).
- Produces: `final class PictureCorrectionControl: PictureCorrectionProviding` (`init(_ correction: PictureCorrection, supported: Bool)`,
  `func update(_ correction: PictureCorrection)`, `var isOn: Bool`, `var current: PictureCorrection?`: nil when off or unsupported);
  `MediaFit.live(…, pictureCorrection: Bool = false)` and `MediaFit.recording(…, pictureCorrection: Bool = false)` returning
  `.transcode(MediaFit.pictureCorrectionReason)` with `static let pictureCorrectionReason = "straightened picture"` (the overlay's reason wins
  when both are on); `nonisolated func CameraRuntime.updatePictureCorrection(_ correction: PictureCorrection)` → `control.update`, called from
  the engine's in-place branch: `if old.pictureCorrection != camera.pictureCorrection, let runtime = runtimes[camera.id] { runtime.updatePictureCorrection(camera.pictureCorrection) }`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theCorrectionForcesALiveTranscodeThatWouldOtherwisePassThrough()       // same inputs as the overlay test → .transcode("straightened picture")
@Test func theCorrectionForcesARecordingTranscodeThatWouldOtherwisePassThrough()
@Test func withOriginalQualityTheTranscodeKeepsTheCamerasSize()   // liveEncoderSettings(… timestampOverlay: true) path used for the correction
@Test func aCameraWithTheCorrectionOnHandsItToTheTranscoder()
    // engine with a recording fake MediaCodecs (supportsPictureCorrection = true), camera (0.4, 0.15), a live session:
    // the fake saw makeVideoTranscoder(…, correction:) with current == (0.4, 0.15)
@Test func onCodecsWithoutSupportTheCorrectionIsOff()
    // same with supportsPictureCorrection = false: passthrough, correction argument nil
@Test func changingTheCorrectionReachesARunningStreamWithoutARestart()
    // update via PATCH path: the provider handed to the transcoder now returns the new value; the runtime was not stopped
    // (the NVR detach count stays 0)
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "PictureCorrectionEngineTests|TimestampOverlayEngineTests"`
Expected: FAIL.

- [ ] **Step 3: Implement**
  - `CameraRuntime` makes `PictureCorrectionControl(configuration.pictureCorrection, supported: dependencies.…codecs.supportsPictureCorrection)`
    next to the overlay control and hands it wherever `overlay` goes (LiveStreamPipeline context `correction`, RecordingHandler,
    RecordingProducer).
  - Every `MediaFit` call that passes `timestampOverlay:` also passes `pictureCorrection: correction?.isOn ?? false`; the two encoder-setting
    helpers get `timestampOverlay: overlayOn || correctionOn`; `passthroughIsSafe` refuses while either is on; every `makeVideoTranscoder`
    call passes `correction: correctionOn ? control : nil`.
  - A correction turned on while a session already passes the camera's stream through takes effect at that session's next start (a
    new Home live view or the next HKSV recording); a transcoding session picks it up at its next picture (Task 3's restart). Write this
    in the README section "Straighten the picture" next to the timestamp overlay's.

- [ ] **Step 4: Run the engine tests**

Run: `swift test --filter "BridgeEngineTests"`
Expected: PASS (all, not only the new ones: the overlay paths changed).

- [ ] **Step 5: Commit** (`git commit -m "Straighten the picture: Apple Home live view and HKSV transcode with the correction"`)

---

### Task 5: Snapshots (Apple Home's tiles and notifications, the web's stills)

**Files:**
- Create: `Packages/CameraBridgeKit/Sources/BridgeEngine/Delegates/CorrectedSnapshots.swift`
- Modify: `Sources/MediaCore/Codecs.swift` (`correctJPEG` + default), `Sources/PlatformLinux/Codecs/FFmpegPictures.swift`,
  `Sources/PlatformLinux/Codecs/FFmpegArguments.swift` (Pictures section), `Sources/PlatformLinux/Codecs/FFmpegMediaCodecs.swift`
- Modify: `Sources/BridgeEngine/Runtime/CameraRuntime.swift` (`snapshot(width:height:)` near line 769), the StreamingHandler snapshot path
  (`Sources/BridgeEngine/Delegates/StreamingHandler.swift:175`), `Sources/BridgeEngine/BridgeEngine.swift:1478`
- Modify: `Sources/BridgeWeb/BridgeBackend.swift` (lines 60, 171), `Sources/BridgeWeb/WebApp+Routes.swift` (`snapshot`, near line 503),
  `Sources/BridgeDaemon/Daemon.swift:358`, `Sources/BridgeDaemon/NoArchiveBackend.swift:41`,
  `Tests/BridgeWebTests/NVRTestRig.swift:133`, `Tests/BridgeWebTests/Support.swift:133`
- Test: `Tests/PlatformLinuxCodecsTests/PicturesAndSourceTests.swift`, `Tests/BridgeEngineTests/PictureCorrectionEngineTests.swift`,
  `Tests/BridgeWebTests/CameraAPITests.swift`

**Interfaces:**
- Consumes: `PictureCorrection.remapMaps`, `ffmpegRemapChain` (Task 3), `PictureCorrectionControl` (Task 4).
- Produces: `MediaCodecs.correctJPEG(_ jpeg: Data, correction: PictureCorrection) throws -> Data` (default throws
  `MediaCodecError.unsupported`); `FFmpegPictures.correctJPEG(_:correction:runtime:)` (size from `FFmpegPictures.imageSize`, the four maps of ruling R6 in a
  private temporary directory removed afterwards, one ffmpeg child: image in → remap chain → `scale=out_range=pc,format=yuvj420p` →
  mjpeg `-q:v 5`); `actor CorrectedSnapshots` (`init(provider: SnapshotProvider, correction: PictureCorrectionControl, correct: @escaping @Sendable (Data, PictureCorrection) async throws -> Data)`,
  `func snapshot(_ request: SnapshotRequest, original: Bool = false) async throws -> Data`, caching the last (input JPEG, correction) →
  output pair; a failed correction serves the original and warns once per failure streak);
  `CameraRuntime.snapshot(width:height:original:)`, `BridgeEngine.snapshot(cameraID:original:)`,
  `BridgeBackend.snapshotJPEG(cameraID: UUID, original: Bool) async -> Data?`; `GET /api/v1/cameras/:id/snapshot?original=1`.

- [ ] **Step 1: Write the failing tests**

```swift
// PicturesAndSourceTests (real ffmpeg)
@Test func aCurvedHorizonComesOutFlat() throws {
    // a 640×284 black picture with a 3-pixel white line along y = horizon(across)·284 for (0.4, 0.15), made a JPEG with
    // FFmpegPictures.jpeg(from:); correctJPEG; decode the result to gray (ffmpeg -f rawvideo -pix_fmt gray): for every column
    // from 5 % to 95 % the brightest row is within 3 rows of landing·284; the result is 640×284
}
// PictureCorrectionEngineTests
@Test func snapshotsAreCorrectedUnlessTheOriginalIsAskedFor()     // fake correct() marks the bytes; original: true returns the provider's
@Test func aCachedPictureIsNotReusedAfterTheCorrectionChanges()  // same input JPEG, new correction → correct() called again
@Test func aFailedCorrectionServesTheOriginal()                  // correct() throws → the provider's JPEG, one warning
@Test func offNeverRunsTheCorrection()                          // correct() never called
// CameraAPITests
@Test func theSnapshotRouteHandsOnOriginal()   // ?original=1 → backend saw original == true; no query → false
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "PicturesAndSourceTests|PictureCorrectionEngineTests|CameraAPITests"`
Expected: FAIL.

- [ ] **Step 3: Implement** the pieces above; Apple Home's snapshots (StreamingHandler) and `runtime.snapshot` both go through
  `CorrectedSnapshots`; the web route passes `original` through.

- [ ] **Step 4: Run the tests** (macOS, then `sh Tools/linux-test.sh test --filter "PicturesAndSourceTests"`)
Expected: PASS.

- [ ] **Step 5: Commit** (`git commit -m "Straighten the picture: snapshots for Apple Home and the web"`)

---

### Task 6: Saved clips, straightened by default

**Files:**
- Modify: `Packages/CameraBridgeKit/Sources/BridgeWeb/WebApp+NVRClipLabels.swift` (becomes the processed-clip path)
- Modify: `Packages/CameraBridgeKit/Sources/BridgeWeb/WebApp+NVRClip.swift` (near line 119)
- Modify: `Packages/CameraBridgeKit/Sources/BridgeEngine/NVR/ClipExporter.swift` (size accessor)
- Modify: `linux/web/js/nvr/clip.js` (lines 36-41, 68, 185-208)
- Test: `Packages/CameraBridgeKit/Tests/BridgeWebTests/ClipLabelTests.swift`, `linux/web-tests/clip.test.mjs`

**Interfaces:**
- Consumes: `PictureCorrection.remapMaps`, `ffmpegRemapChain` (Task 3); `CameraConfiguration.pictureCorrection` (Task 2).
- Produces: `ClipExporter.pictureSize(_ plan: ClipPlan, part: Int) async throws -> (width: Int, height: Int)` (from the part's
  `ClipPartTables`); `WebApp.clipArguments(input: String, textFiles: [(LabelRun, String)], style: TimestampOverlaySettings?, font: String?, correction: (xMap: String, yMap: String, width: Int, height: Int)?, vaapiDevice: String?) -> [String]`
  (replaces `labelArguments`; `style == nil`: no label; the correction tuple also carries `chromaXMap`/`chromaYMap` per ruling R6); `GET …/clip?…&straighten=1`; `clipUrl(cameraId, fromMs, toMs, part, zone, labels, straighten)` in clip.js.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aStraightenedClipWarpsThenLabels()
    // correction (x.pgm, y.pgm, cx.pgm, cy.pgm, 1920, 852) + a label: arguments have "-i", input, then the four maps; "-filter_complex" whose graph has
    // the remap chain then drawtext then format; "-map", "[cbv]", "-map", "0:a:0?"
@Test func aStraightenedClipWiderThan3840IsShrunkFirst()   // 4256-wide part: the chain's size is 3840×(even height in proportion)
@Test func labelsAloneAreUnchanged()                       // correction nil: today's labelArguments output, byte for byte
@Test func straightenWithTheCorrectionOffIsACopy()         // route: straighten=1, camera off → the plain copy path (no ffmpeg)
```

```js
// clip.test.mjs
test('clipUrl asks for straightening only when told', () => {
  assert.match(clipUrl('c', 0, 1000, 1, 'UTC', false, true), /&straighten=1$/);
  assert.doesNotMatch(clipUrl('c', 0, 1000, 1, 'UTC', true, false), /straighten/);
});
```

- [ ] **Step 2: Run them to see them fail** (`swift test --filter BridgeWebTests`; `sh linux/web-tests/run.sh --test-name-pattern=clip`)
Expected: FAIL.

- [ ] **Step 3: Implement**
  - The route re-encodes when `labels=1`, or when `straighten=1` and the camera's correction is on; the maps are written in the
    clip's private temporary folder; the log line says "with its label", "straightened" or both.
  - clip.js: for a camera whose correction is on, the dialog shows a second checkbox **Straightened** (checked by default, title
    "Saves the clip straightened, as you see it. Takes longer to save; unchecked saves it as recorded."), remembered in
    `localStorage` key `cb.clip.straighten` (read/write in try/catch like `cb.clip.labels`); hidden for other cameras.

- [ ] **Step 4: Run the tests** (both commands above)
Expected: PASS.

- [ ] **Step 5: Commit** (`git commit -m "Straighten the picture: saved clips straightened by default, as recorded on request"`)

---

### Task 7: The formula and the renderer in the browser

**Files:**
- Create: `linux/web/js/live/straighten.js`
- Create: `linux/web-tests/straighten.test.mjs`
- Modify: `linux/web/style.css`

**Interfaces:**
- Consumes: the vectors file (Task 1), read by the test from `Packages/CameraBridgeKit/Tests/MediaCoreTests/Fixtures/picture-correction-vectors.json`.
- Produces (ES module, importable in plain Node: no DOM access at import):
  - `isOn(c)` (`c` is `{ straighten, level }` or undefined), `sourceFraction(c, across, down)`, `horizon(c, across)`, `landing(c)`,
    `largestStretch(c)`: the same results as Task 1.
  - `GLSL_STRAIGHTEN`: a GLSL ES 1.0 snippet declaring `uniform vec2 straighten;` and `float sourceDown(float across, float down)` (the formula).
  - `stripPlan(c, width, height, step = 2)` → `[{ sx, sy, sw, sh, dx, dy, dw, dh }]`: for each `step`-wide column strip, two `drawImage`
    rectangles (above and below the landing row) that reproduce the formula exactly (the formula is linear on each piece of a column).
  - `createStraightenedView({ source, correction })` → `{ canvas, set(correction), destroy() }`: a canvas inserted right after `source`
    (a `<video>` or `<img>`) with the source's classes plus `straightened`; the source gets class `straighten-source` (CSS
    `opacity: 0`, so video keeps decoding and `requestVideoFrameCallback` keeps firing). Draws with WebGL (`sourceDown` in the fragment
    shader, bilinear texture sampling), else, or after `webglcontextlost`, with the 2D strip plan. Video: redraws on
    `requestVideoFrameCallback` (rAF fallback); image: on `load` and on `set`. The canvas's backing size is the source's intrinsic size
    capped at its displayed size × `devicePixelRatio`, and it copies the source's computed `object-fit`/`object-position`, so the
    picture sits exactly where the source's would. `set(off)` removes the canvas and the class (zero cost); `destroy()` likewise.

- [ ] **Step 1: Write the failing tests**

```js
test('every shared vector matches', () => { for (const v of vectors) assert.ok(Math.abs(sourceFraction(v, v.across, v.down) - v.source) < 1e-9); });
test('off is off', () => { assert.equal(isOn(undefined), false); assert.equal(isOn({ straighten: 0, level: 0 }), false); assert.equal(isOn({ straighten: 0.01, level: 0 }), true); });
test('stripPlanCoversEveryColumnOnce', () => {
  // (0.4, 0.15), 640×284, step 2: 320 strips × 2 rects; dx runs 0,2,…,638; above: dy 0, dh = landing·284, sy 0, sh = horizon(centre)·284;
  // below continues to 284 in both; every source rect stays inside the picture
});
test('stripPlan of off is one rectangle', () => { /* one rect, identity */ });
test('aViewFallsBackTo2DWhenWebGLIsRefused', () => {
  // fake-browser: getContext('webgl') returns null → the view draws through a 2D context fake, recording drawImage calls == stripPlan
});
test('largestStretch matches Swift', () => { /* (0.4, 0.15) → 2.71496 ± 1e-5; (0.1, 0) → 1.13157 ± 1e-5 */ });
```

- [ ] **Step 2: Run them to see them fail**

Run: `sh linux/web-tests/run.sh --test-name-pattern="straighten|vector|strip"`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement `straighten.js`** and the two CSS rules (`.straighten-source { opacity: 0 }`, `canvas.straightened` placed
  exactly over the source: the same positioning as the source's class gives it).

- [ ] **Step 4: Run all web tests** (`sh linux/web-tests/run.sh`; `import-all` and `lint` must stay green)
Expected: PASS.

- [ ] **Step 5: Commit** (`git commit -m "Straighten the picture: the formula and a WebGL/2D renderer for the web page"`)

---

### Task 8: The card on the camera's page, with its live preview

**Files:**
- Modify: `linux/web/js/screens/camera.js` (`previewCard` lines 123-215, `qualityCard` near line 310, after `overlayCard` near line 324,
  `renderAll` near line 445)
- Test: `linux/web-tests/` (a new `camera-straighten.test.mjs` using `support/fake-browser.mjs`)

**Interfaces:**
- Consumes: `straighten.js` (Task 7); `PATCH cameras/:id` with `pictureCorrection` (Task 2); `snapshot?original=1` (Task 5).

- [ ] **Step 1: Write the failing tests**

```js
test('the card shows two sliders at the saved values and Reset', () => {
  // camera.pictureCorrection {0.4, 0.15}: card titled "Straighten the picture"; range "Straighten" min -60 max 60 value 40;
  // range "Level" min -40 max 40 value 15; a "Reset" button; the exact line from Global Constraints
});
test('moving a slider previews without saving; releasing saves once', () => {
  // 'input' events: no PATCH, the view's set() saw the new value; 'change': one PATCH {pictureCorrection: {straighten: 0.42, level: 0.15}}
});
test('Reset saves off', () => { /* PATCH {pictureCorrection: {straighten: 0, level: 0}} and both sliders read 0 */ });
test('the preview asks for the original picture', () => { /* the picture stream's URLs carry original=1 */ });
test('a strong setting says how much it stretches', () => {
  // (0.4, 0.15): a line "At this setting parts of the picture are stretched up to 2.7×."; (0.1, 0): no such line (below 2×)
});
```

- [ ] **Step 2: Run them to see them fail** (`sh linux/web-tests/run.sh --test-name-pattern=Straighten`)
Expected: FAIL.

- [ ] **Step 3: Implement**
  - `previewCard`: the snapshot `img` loads `/api/v1/cameras/${id}/snapshot?original=1&t=…`; one `createStraightenedView` for the
    `img` and one for the `video` (only while the camera's correction, or the card's unsaved slider values, are on); both destroyed in
    `previewStop`.
  - A guide: a thin dashed horizontal line over the preview's picture at `landing(c)` of the picture's height (the straightened horizon
    lands there), shown while either slider is non-zero.
  - `straightenCard()` placed right after `overlayCard()`: the two sliders (`input` → preview only, `change` → save with `now: true`),
    their numbers, Reset, the exact line, and the stretch line when `largestStretch ≥ 2` (one decimal, "×"). Saving must not rebuild the
    page (the preview keeps running), as the Record switch already does.
  - `qualityCard`: when the correction is on, add " Straighten the picture is on, so Apple Home's live view and recordings always use
    the video encoder." next to the timestamp sentence.

- [ ] **Step 4: Run the web tests** (`sh linux/web-tests/run.sh`)
Expected: PASS.

- [ ] **Step 5: Check it in the browser**: start `bridge-preview` (`.claude/launch.json`; rebuild its binary first), open a camera's
  page, set Straighten 40 / Level 15: the preview bends live, one PATCH on release (network panel), Reset restores. Screenshot.

- [ ] **Step 6: Commit** (`git commit -m "Straighten the picture: the camera page card with live preview"`)

---

### Task 9: Everywhere else the web shows the camera

**Files:**
- Modify: `linux/web/js/screens/nvr.js` (live tile video near line 191; the zoom hookup near line 572)
- Modify: `linux/web/js/nvr/cell.js` (the `video`/`holdCanvas` made near lines 179-191; removed near line 707)
- Modify: `linux/web/js/screens/watch.js` (video near line 71)
- Modify: `linux/web/js/live/zoom.js` (`FRAGMENT`, `createGLDrawer.draw`, the 2D path near line 239, `drawMap` near line 253)
- Test: `linux/web-tests/monitor-wall.test.mjs`, `linux/web-tests/player-cell.test.mjs`, a zoom test next to them

**Interfaces:**
- Consumes: `createStraightenedView`, `GLSL_STRAIGHTEN`, `stripPlan`, `isOn` (Task 7); `store.cameras.get(id).pictureCorrection`.

- [ ] **Step 1: Write the failing tests**

```js
test('a corrected camera's tile draws through a straightened view; others do not', () => { /* nvr wall with two cameras, one (0.4, 0.15) */ });
test('a playback cell of a corrected camera straightens its video and its hold picture', () => {
  // the hold canvas is drawn from the straightened canvas, not the raw video
});
test('the watch screen straightens a corrected camera's recording', () => {});
test('zoom samples through the correction', () => {
  // the zoom fragment shader source contains GLSL_STRAIGHTEN and calls sourceDown; with the correction off its uniform is (0, 0)
});
test('a correction saved on the camera page reaches an open Monitor', () => {
  // store update of the camera → the tile's view.set() called with the new value, no tile rebuild
});
```

- [ ] **Step 2: Run them to see them fail** (`sh linux/web-tests/run.sh --test-name-pattern="tile|cell|watch|zoom|Monitor"`)
Expected: FAIL.

- [ ] **Step 3: Implement**
  - nvr.js live tiles, cell.js and watch.js wrap their `<video>` in `createStraightenedView` when the camera's correction is on, `set()`
    it when the store's camera changes, and destroy it with the tile/cell.
  - cell.js: the hold picture copies the straightened canvas when there is one.
  - zoom.js: the fragment shader samples `vec2(uv.x, sourceDown(uv.x, uv.y))` (view rectangle math stays in corrected coordinates; the
    correction's uniform is (0, 0) when off, which is the identity); the 2D path and the overview map draw through `stripPlan`.
  - Labels, PTZ pad and other HTML over the picture need no change: the canvas occupies the video's box.

- [ ] **Step 4: Run the web tests** (`sh linux/web-tests/run.sh`)
Expected: PASS.

- [ ] **Step 5: Check it in the browser** (`bridge-preview`): the Monitor wall, one-camera zoom (drag a box over the straightened
  horizon: it stays straight), playback and Watch for a corrected camera; an uncorrected camera has no extra canvas
  (`document.querySelectorAll('canvas.straightened').length` equals the corrected tiles). Screenshot.

- [ ] **Step 6: Commit** (`git commit -m "Straighten the picture: Monitor, playback, Watch and zoom straighten corrected cameras"`)

---

### Task 10: Docs, release notes, and the check on the box

**Files:**
- Modify: `linux/web/js/release-notes.js` (an entry for the next build; written now, released only with the owner's yes)
- Modify: the web manual help if it lists camera page cards (`linux/web/js/screens/manual-help.js`)
- Modify: `Packages/CameraBridgeKit/Sources/BridgeEngine/README.md` (if Task 4 did not finish the section), `docs/CONTRACT_CHANGES.md`

- [ ] **Step 1: Write the release note** (plain words, the owner's style: what it does, that recordings keep the original, that Apple
  Home then always converts that camera's video, that saved clips are straightened unless "Straightened" is unchecked).

- [ ] **Step 2: Run everything**

Run: `swift test` (Packages/CameraBridgeKit), `sh Tools/linux-test.sh test`, `sh linux/web-tests/run.sh`, `sh linux/os/test-static.sh`
Expected: all PASS (rerun `test-static.sh` once if only its repart checks fail: they flake on Docker loop devices).

- [ ] **Step 3: Commit** (`git commit -m "Straighten the picture: release notes and docs"`)

- [ ] **Step 4: Ask the owner** before publishing. After his yes: publish (dry run first), tag `os-v…`, wait for the "Camera Bridge OS
  image" workflow, `cb-update check` / `cb-update apply` / `systemctl reboot` on the box, then on the box with the owner: set Backyard to
  about Straighten 40 / Level 15 on its page and check the page preview, the Monitor, a playback, a saved clip, a Home tile snapshot and
  Home live view; read the transcoder's CPU while Home live view runs (`top -b -n 3 -p <ffmpeg pid>`) and report it with the numbers.
