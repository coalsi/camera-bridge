# Export clip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A person watching recorded video presses **Save clip**, moves the scrubber to where the clip should end, presses **Export clip**, and gets a normal MP4 of that stretch of that camera (several cameras at once on the all-cameras page), in the Mac app and on the box's web page.

**Architecture:** One portable `ClipExporter` in `BridgeEngine/NVR` plans (header reads only, exact size) and writes (one streaming pass, no re-encoding) a progressive MP4 on top of the existing `ArchiveReading` seam, which gains one read part, `.header`. The Mac app calls it in process and writes a file; the daemon serves it from three new `GET` routes (R13 plan, R14 one MP4, R15 a store-only ZIP); the web page and the Mac timeline share one flow and one set of words.

**Tech Stack:** Swift 6.4 (engine, daemon, app; Swift Testing), SwiftUI/AppKit (Mac), plain JavaScript ES modules tested with Node (web page and mock server), Python 3 standard library (QEMU test additions), ffprobe/ffmpeg and AVFoundation as test-only decoder gates.

**Spec:** `docs/superpowers/specs/2026-10-12-export-clip-design.md` (cited "spec N" for its section N). Evidence: `docs/superpowers/specs/2026-10-12-export-clip-survey/` (cited "survey 01" to "survey 04"; `prototypes/` holds the throwaway Python probes that cut the owner's real recordings). The NVR plan (`docs/superpowers/plans/2026-10-10-nvr/README.md`) is the authority for the rails this plan inherits; it is cited "NVR plan".

## Global Constraints

Every task's requirements include this section. Values are copied from the spec; the NVR plan's global constraints apply as well (toolchain, portability, names, API additions, security, listeners, waiting, builds, commits, publishing).

- **Container:** progressive MP4, H.264 samples copied untouched (no re-encoding), moov first. `ftyp`: major `isom`, minor version 512, compatible `isom iso2 avc1 mp41`. `mvhd` timescale 1000; `mdhd` timescale 90000; `mvhd`/`mdhd` creation and modification time = the clip's wall start in MP4 epoch seconds (since 1904-01-01). No `edts`, no `mvex`, no `udta`. `stco` becomes `co64` and the `mdat` size 64-bit when the file would be 4 GiB or larger. (spec 4)
- **Start and end:** a clip starts on the key picture at or before the requested start (no edit list; `leadIn` = requested start minus actual start); it ends at the last sample, in decode order, whose presentation time is before the requested end. (spec 1 answer 1, 3.3)
- **Gaps (wall time between consecutive fragments):** under 1 s either way: continuous; 1 s to 10 s: **hold** (the previous sample's duration is lengthened by the gap); over 10 s: **skip** (reported, not frozen); an overlap of 1 s or more: the earlier file's tail is trimmed at the later file's start. (spec 3.3)
- **Parts:** if the codec settings (the file's init bytes) differ inside the range the part ends there and a new part starts; each part is a complete MP4 named `... (part 2 of 2).mp4`. Sound is omitted (`soundOmitted`). (spec 3.3)
- **Limits:** at most 7200 s of media per camera and 20 GiB in all (`ClipLimits.standard`); the UIs warn from 2 GB on. (spec 1)
- **Names:** `<camera name> yyyy-MM-dd HH.mm.ss to HH.mm.ss.mp4` in the request's time zone (the end carries its date when the clip crosses midnight); the camera name goes through the engine's camera-directory sanitiser (`:` `/` `\` and control characters become `-`, at most 60 scalars, duplicates ` (2)`); a multi-camera export on the Mac is the folder `Clips yyyy-MM-dd HH.mm.ss`, in the browser the ZIP `Camera Bridge clips yyyy-MM-dd HH.mm.ss.zip`. (spec 4)
- **Routes:** `GET` only, authenticated like R1 to R12, `Cache-Control: no-store`; R13 `GET /api/v1/nvr/clip/plan`, R14 `GET /api/v1/nvr/cameras/:id/clip`, R15 `GET /api/v1/nvr/clip`; times are epoch milliseconds, `to - from` at least 1000; exact `Content-Length`, no `Accept-Ranges`; at most 2 exports at once and 2 per client address; HEAD is 405; every error is sent before the first body byte. (spec 6.1)
- **Reads:** one fragment in flight, `.utility` quality of service, never a temporary file, a fragment is at most 16 MiB, the export never reads beyond the fragments its plan named (a growing open file does not change a plan). (spec 3.2, 3.4)
- **Platforms:** `BridgeEngine` stays Foundation-only (no Apple-only framework outside `PlatformApple` and the app); the daemon builds on Linux; `PortabilityTests`, `ScaffoldingTests` and `DocsConsistencyTests` must pass; new public or `package` symbols are listed in their module README and in `docs/CONTRACT_CHANGES.md`.
- **Mac app:** the Save panel (one camera, one part) or a folders-only panel (several cameras, or several parts) is asked each time and starts in the last folder used (`UserDefaults` key `clipExportFolder`, Downloads the first time, never the recordings folder); the export job lives on `AppModel` and is cancelled in `prepareToTerminate`; a partial file is removed when an export fails or is cancelled.
- **Keys:** `C` starts a clip, `Esc` cancels it, `Return` exports, in the app and on the page.
- **Never:** write to `/Volumes/Elite Pro 4TB` or open the owner's live recordings folder with a second `ArchiveStore` (copy the files you need into a scratch folder first); install anything over the owner's running app; publish, tag or push.

## Review Focus

The five inputs the spec implies but its test list does not pin, most likely first. The task named in brackets owns the code and its test.

1. **A clip that ends "now" while the recorder keeps appending to the open file** (no sidecar yet, the newest fragment is up to 2.5 s behind real time). Expected: the plan names the fragments it saw, the file is exactly the planned size, and a fragment written after the plan is never read. [X04]
2. **The drive goes away or retention deletes the first file in the middle of an export.** Expected: the engine stops with a named error and no truncated file that looks complete: the Mac removes the partial file and says the drive went away, the box aborts the connection (a short body is a failed download). [X04, X06, X08]
3. **Camera names that are illegal, long, duplicated or non-ASCII** in file names, folder names and ZIP entry names. Expected: sanitised, unique, UTF-8 flagged in the ZIP, never an empty name, never a path separator. [X01, X05, X08]
4. **Sizes at the edges:** a clip under 1 s, exactly 1 s, a part just under and just over 4 GiB (`co64`, 64-bit `mdat`, ZIP64), a ZIP entry over 4 GiB. Expected: the right box widths, the exact size, no overflow. [X02, X03, X05]
5. **Abuse and concurrency:** a third export while two run (`429`), a client that disconnects in the middle of a ZIP (the lease is released), plan requests fired on every drag, a second export started on the Mac while one runs, the selection kept when the page changes. Expected: refused with a sentence, nothing leaks, nothing stalls the recorder or other viewers. [X06, X07, X09]

---

## The eleven tasks

Branches `export/xNN-<name>` are cut from the current `main` in a worktree under the session scratchpad (`wt/export-xNN`), merged into `main` fast-forward only by the merge gate (NVR plan, "Merge gate"), each with the trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

| Id | Task | Area | Depends on | Document |
|---|---|---|---|---|
| X01 | Seam and shared types: `ArchiveReadPart.header` and its implementations, `ClipTypes`, `ClipFileName`, the shared fakes | engine | none | `X01-seam-and-types.md` |
| X02 | `ClipPlanner`: fragments to sample tables, gaps, overlaps, parts, limits | engine | X01 | `X02-planner.md` |
| X03 | `ClipLayout` and `ClipWriter`: the progressive MP4 bytes, exact size, `co64` | engine | X01 | `X03-writer.md` |
| X04 | `ClipExporter` facade, end-to-end and decoder gates, live-edge and drive-loss tests, the opt-in real-data test | engine | X02, X03 | `X04-exporter-integration.md` |
| X05 | `ZipStream` (store-only, ZIP64), a streamed response with a known length, `ClipLease` | box | none | `X05-zip-and-sized-stream.md` |
| X06 | Daemon routes R13 to R15 and their wiring | box | X01, X05 (real exporter: X04) | `X06-daemon-routes.md` |
| X07 | Web page: clip controller, bar, camera check boxes, mock server, conformance additions | box | none (the route contract of this README) | `X07-web-page.md` |
| X08 | Mac models: `ClipSelection`, `ClipExportModel`, `FileClipSink`, destination and free-space seams | mac | X01 | `X08-mac-models.md` |
| X09 | Mac UI: panel clip state, `ClipBar`, `ClipBand`, camera check badges, save button, `AppModel` wiring, README, demo capture | mac | X08 (real exporter: X04) | `X09-mac-ui.md` |
| X10 | QEMU test phase, conformance, docs and contract rows, the Wednesday checklist | box + docs | X06, X07 | `X10-qemu-docs-checklist.md` |
| X11 | Final gates, the C4 image, the Mac release candidate | qa | all | `X11-final-gates-and-candidates.md` |

## The clock

Today is Monday 2026-10-12; the owner approved the spec at about 12:30. **Code freeze for the box image C4: Tuesday 2026-10-13 10:30 local**; the CI build takes about 25 minutes and its QEMU test about 8. C3 (0.1.93) is the fallback for Wednesday.

```
X01 (1 h) ──┬─> X02 ─┐
            ├─> X03 ─┴─> X04 ─┬─> X06 ─┐
            ├─> X08 ──────────┼─> X09  ├─> X10 ─> X11
X05 ────────┴─────────────────┘        │
X07 ───────────────────────────────────┘
```

- **Start at once:** X01, X05, X07 (they depend on nothing). X02, X03, X08 start when X01 has merged. X06 starts when X01 and X05 have merged and develops against a fake `ClipExporting` until X04 merges. X09 develops against a fake exporter until X04 merges.
- **Per-task gate** (the merge gate): the task's own tests, `DocsConsistencyTests|PortabilityTests|ScaffoldingTests` (51 tests), `git diff --name-only main...HEAD` inside the task's file list, the trailer on every commit. Whole-package runs are for X04 (once) and X11 only.
- **Cut lines, in this order, if Tuesday 08:00 is missed:** (1) the R16 progress record is not built (it is not in this plan); (2) R15/ZIP and the grid check boxes on the box ship in the next image; (3) the QEMU clip phase is reduced to the single-camera download; (4) the box export waits for the next image and Wednesday uses C3, with the Mac export installed on the owner's word. The single-camera export on the box ships with C4 whenever X04, X06 and X07 are merged and X11's gates pass.

## Rails (every task)

- `df -h /` first and last in every task; refuse to start below 30 GiB free; at most three Swift builders at once; each worktree builds in its own `--scratch-path` under the scratchpad (`build/export-xNN`) and deletes it when done; run heavy commands with `nice -n 10` (the owner's real NVR recording runs on this Mac).
- Linux: `sh Tools/linux-test.sh build` and `CB_CPUS=2 sh Tools/linux-test.sh test --no-parallel`, one worktree at a time under the lock in `scratchpad/locks/linux.lock` (NVR plan, "Rails"); only X04's closing run, X06's closing run and X11 use it.
- Node: `sh linux/web-tests/run.sh` and `node linux/web-tests/lint.mjs`; Chrome only headless and throwaway.
- Mac app tests: `xcodegen generate`, then `xcodebuild test -scheme CameraBridge -destination platform=macOS` with its own derived data and `-clonedSourcePackagesDirPath` copied from `$CB_REPO/build/SourcePackages` (the NVR plan's `xt.sh` pattern).
- Test data: synthetic fixtures (`ArchiveFixtureWriter`, `FMP4Muxer`, ffmpeg-generated H.264 in scratch). The owner's real recordings may be read only by the opt-in test of X04 and only from a copy in scratch.
- No task installs, quits or launches the owner's app, writes to `/Volumes/Elite Pro 4TB`, listens beyond loopback, pushes, tags or publishes.

---

## Shared contracts

Names here are the contract for the parallel build. A task may add members; it may not rename or remove these. Code is the intended shape; X01 puts the engine types in the repository exactly as written (Foundation only).

### A. Engine API (`Packages/CameraBridgeKit/Sources/BridgeEngine/NVR/ClipTypes.swift`, created by X01)

```swift
import Foundation

public struct ClipLimits: Sendable, Equatable {
    public var maxSecondsPerCamera: Int
    public var maxTotalBytes: Int64
    /// Gaps up to this long are held (frozen picture); longer ones are skipped.
    public var maxHold: TimeInterval
    /// A wall-clock difference smaller than this between fragments is continuity.
    public var continuity: TimeInterval
    public init(maxSecondsPerCamera: Int, maxTotalBytes: Int64, maxHold: TimeInterval, continuity: TimeInterval) {
        self.maxSecondsPerCamera = maxSecondsPerCamera
        self.maxTotalBytes = maxTotalBytes
        self.maxHold = maxHold
        self.continuity = continuity
    }
    public static let standard = ClipLimits(maxSecondsPerCamera: 7_200, maxTotalBytes: 20 << 30, maxHold: 10, continuity: 1)
}

public struct ClipRequest: Sendable, Equatable {
    public var camera: UUID
    public var cameraName: String
    public var start: Date
    public var end: Date
    /// Used for file names only.
    public var timeZone: TimeZone
    public init(camera: UUID, cameraName: String, start: Date, end: Date, timeZone: TimeZone = .current) {
        self.camera = camera
        self.cameraName = cameraName
        self.start = start
        self.end = end
        self.timeZone = timeZone
    }
}

public struct ClipGap: Sendable, Equatable {
    public var from: Date
    public var to: Date
    /// True: the picture freezes for the gap; false: the clip jumps over it.
    public var held: Bool
    public init(from: Date, to: Date, held: Bool) { self.from = from; self.to = to; self.held = held }
}

public struct ClipPart: Sendable, Equatable {
    /// 1-based, and the number of parts of this camera's clip.
    public var index: Int
    public var count: Int
    /// The first picture (the key picture at or before the requested start) and the end of the last picture, holds included.
    public var start: Date
    public var end: Date
    /// Requested start minus `start`, never negative.
    public var leadIn: TimeInterval
    public var byteCount: Int64
    public var sampleCount: Int
    public var fileName: String
    public init(index: Int, count: Int, start: Date, end: Date, leadIn: TimeInterval, byteCount: Int64, sampleCount: Int, fileName: String) {
        self.index = index; self.count = count; self.start = start; self.end = end
        self.leadIn = leadIn; self.byteCount = byteCount; self.sampleCount = sampleCount; self.fileName = fileName
    }
}

public struct ClipPlan: Sendable {
    public let request: ClipRequest
    public let parts: [ClipPart]
    public let gaps: [ClipGap]
    /// Some file in the range has sound; the clip is video only.
    public let soundOmitted: Bool
    /// One entry per part; empty for plans made by fakes.
    package let tables: [ClipPartTables]
    public var byteCount: Int64 { parts.reduce(0) { $0 + $1.byteCount } }
    public var duration: TimeInterval { parts.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
    /// For fakes in other targets' tests (no tables).
    public init(request: ClipRequest, parts: [ClipPart], gaps: [ClipGap], soundOmitted: Bool) {
        self.init(request: request, parts: parts, gaps: gaps, soundOmitted: soundOmitted, tables: [])
    }
    package init(request: ClipRequest, parts: [ClipPart], gaps: [ClipGap], soundOmitted: Bool, tables: [ClipPartTables]) {
        self.request = request; self.parts = parts; self.gaps = gaps; self.soundOmitted = soundOmitted; self.tables = tables
    }
}

public enum ClipError: Error, Equatable, Sendable {
    case nothingRecorded
    case notReady
    case driveGone
    case damaged(at: Date)
    case tooLong(maxSeconds: Int)
    case tooLarge(maxBytes: Int64)
    case cancelled
    case sink(String)
}

/// Where the bytes go: the Mac's file, the HTTP body, a test's counter. Each call is one write, in order.
public protocol ClipSink: Sendable {
    func write(_ bytes: Data) async throws
}

public protocol ClipExporting: Sendable {
    /// A dry run: reads fragment headers only; throws `ClipError`.
    func plan(_ request: ClipRequest) async throws -> ClipPlan
    /// Writes part `part` (1-based) of `plan` to `sink`; `progress` gets the bytes written so far.
    func export(_ plan: ClipPlan, part: Int, to sink: any ClipSink, progress: @Sendable (Int64) -> Void) async throws
}

public struct ClipExporter: ClipExporting {
    private let planner: ClipPlanner
    private let writer: ClipWriter
    public init(archive: any ArchiveReading, limits: ClipLimits = .standard) {
        planner = ClipPlanner(archive: archive, limits: limits, sizing: ClipSizing.totalBytes(of:))
        writer = ClipWriter(archive: archive)
    }
    public func plan(_ request: ClipRequest) async throws -> ClipPlan { try await planner.plan(request) }
    public func export(_ plan: ClipPlan, part: Int, to sink: any ClipSink, progress: @Sendable (Int64) -> Void) async throws {
        try await writer.write(plan, part: part, to: sink, progress: progress)
    }
}
```

`ArchiveReadPart` (in `ArchiveReading.swift`) gains `case header`: the bytes `[byteOffset, byteOffset + headerLength)` of the fragment, that is `prft` + `moof` + the 8-byte `mdat` header (`headerLength` is "the distance from `offset` to the first video byte", `CBIndexFormat`). `ArchiveStore` serves it through the same read queue and cache; `PreviewArchive` throws `ArchiveError.unreadable("The preview has no recordings to export.")`; every fake and every `switch` over `ArchiveReadPart` in the repository is updated (X01 greps for them).

`ClipFileName` (public enum, X01): `static func part(cameraName: String, start: Date, end: Date, partIndex: Int, partCount: Int, timeZone: TimeZone) -> String`, `static func folder(start: Date, timeZone: TimeZone) -> String` (`Clips yyyy-MM-dd HH.mm.ss`), `static func archive(start: Date, timeZone: TimeZone) -> String` (`Camera Bridge clips yyyy-MM-dd HH.mm.ss.zip`), `static func unique(_ names: [String]) -> [String]` (appends ` (2)`, ` (3)` before the extension).

### B. Planner to writer (package access, created by X01, filled by X02 and read by X03)

```swift
/// One video sample as it goes into the sample tables, in decode order.
package struct ClipSample: Sendable, Equatable {
    package var size: UInt32
    /// 90 kHz ticks; a held gap lengthens the last sample before it.
    package var duration: UInt32
    package var compositionOffset: Int32
    package var isSync: Bool
    package init(size: UInt32, duration: UInt32, compositionOffset: Int32, isSync: Bool) {
        self.size = size
        self.duration = duration
        self.compositionOffset = compositionOffset
        self.isSync = isSync
    }
}

/// Bytes to copy from one fragment: `length` bytes starting `skipBytes` into the fragment's `.fragment` read
/// (`skipBytes == fragment.headerLength`, so the first copied byte is the first video byte); a trimmed fragment copies a prefix.
package struct ClipCopy: Sendable, Equatable {
    package var fragment: ArchiveFragment
    package var skipBytes: Int
    package var length: Int
    package var firstSample: Int
    package var sampleCount: Int
    package init(fragment: ArchiveFragment, skipBytes: Int, length: Int, firstSample: Int, sampleCount: Int) {
        self.fragment = fragment
        self.skipBytes = skipBytes
        self.length = length
        self.firstSample = firstSample
        self.sampleCount = sampleCount
    }
}

/// Everything the writer needs for one part: no archive access, no wall-clock logic.
package struct ClipPartTables: Sendable {
    /// `ftyp` + `moov` of the part's first file (`stsd`, `hdlr`, `vmhd`, `dinf` are copied from it).
    package var initialization: Data
    package var samples: [ClipSample]
    /// In output order; one `stco` chunk per copy.
    package var copies: [ClipCopy]
    /// The first sample's wall time (creation time of the file).
    package var wallStart: Date
    package var width: Int
    package var height: Int
    package init(initialization: Data, samples: [ClipSample], copies: [ClipCopy], wallStart: Date, width: Int, height: Int) {
        self.initialization = initialization
        self.samples = samples
        self.copies = copies
        self.wallStart = wallStart
        self.width = width
        self.height = height
    }
}
```

X03 owns `struct ClipWriter: Sendable { init(archive: any ArchiveReading); func write(_ plan: ClipPlan, part: Int, to sink: any ClipSink, progress: @Sendable (Int64) -> Void) async throws }` (package access) and `ClipLayout.make(_ tables: ClipPartTables) throws -> ClipLayout` (`ftyp`, `moov`, `mdatHeader`, `payloadBytes`, `totalBytes`) and `ClipSizing.totalBytes(of:) throws -> Int64`. X02's `struct ClipPlanner: Sendable { init(archive: any ArchiveReading, limits: ClipLimits, sizing: @escaping @Sendable (ClipPartTables) throws -> Int64); func plan(_ request: ClipRequest) async throws -> ClipPlan }` (package access) takes the size function as a parameter (its tests pass a fake one); the `ClipExporter` of section A passes `ClipSizing.totalBytes(of:)`.

### C. HTTP contract (X06 serves it, X07's mock serves it, X10's conformance checks it)

Query parameters: `cameras=<uuid>[,<uuid>...]` (R13, R15), `from=<ms>`, `to=<ms>`, optional `tz=<minutes east of UTC, -720...840>` used only for file names (default: the server's zone). Every error body is the same JSON as R1 to R12: `{"error": "<code>", "message": "<one sentence>"}`.

R13 `GET /api/v1/nvr/clip/plan?cameras=...&from=...&to=...[&tz=...]` answers `200`:

```json
{
  "serverTime": 1791813900000,
  "from": 1791811200000,
  "to": 1791811500000,
  "kind": "mp4",
  "fileName": "Driveway 2026-10-12 14.02.10 to 14.05.42.mp4",
  "bytes": 214958080,
  "download": "/api/v1/nvr/cameras/41D22FF6-B96E-43EC-A46C-F0006542C6DA/clip?from=1791811200000&to=1791811500000&tz=-420",
  "limits": { "maxSeconds": 7200, "maxBytes": 21474836480 },
  "cameras": [
    { "id": "41D22FF6-B96E-43EC-A46C-F0006542C6DA", "name": "Driveway", "state": "ok", "startMs": 1791811198650, "endMs": 1791811500000,
      "leadInMs": 1350, "bytes": 214958080, "parts": 1, "soundOmitted": false, "gaps": [[1791811320000, 1791811322000, true]] }
  ]
}
```

`kind` is `"mp4"` for one camera in one part, else `"zip"` (`fileName` is then the ZIP's name and `bytes` its exact size; each camera's `bytes` is the sum of its MP4 parts). `state` is `"ok"` (the whole range), `"partial"` (clamped to the footage or a gap skipped) or `"empty"` (nothing recorded; the camera is not in the ZIP). `gaps` has at most 32 entries `[fromMs, toMs, held]`. `from`/`to` are echoed clamped. The plan takes an archive read slot and returns exactly the errors the download would.

R14 `GET /api/v1/nvr/cameras/:id/clip?from=...&to=...[&tz=...]` answers `200 video/mp4` with `Content-Length` (exact), `Content-Disposition: attachment; filename="<ASCII fallback>"; filename*=UTF-8''<percent-encoded>`, no `Accept-Ranges`, no `ETag`. Valid only when the plan's `kind` is `"mp4"`; otherwise `409 {"error":"use_zip"}`.

R15 `GET /api/v1/nvr/clip?cameras=...&from=...&to=...[&tz=...]` answers `200 application/zip`, same headers, a store-only ZIP, entries in the order of `cameras`, one `.mp4` per part of every camera that has footage, `Content-Length` exact, ZIP64 when needed.

Errors (all before the first body byte): `400 invalid` (`message` names the field), `404 not_found` (a malformed camera id on R14), `404 gap` (nothing recorded in the range; header `X-CB-Next: <ms>` when a later recording exists), `405` for HEAD (`Allow: GET`), `410 gone`, `413 clip_too_large`, `429 busy` (`Retry-After: 5`), `502 unreadable`, `503 archive_unavailable`, `504 drive_slow` (`Retry-After: 2`). After the head, any failure aborts the connection.

### D. The words (identical in the Mac app and on the page)

| Where | Text |
|---|---|
| Button | `Save clip` (tooltip `Start a clip here`) |
| Choosing, page | `Clip starts {time}. Drag or click the timeline to choose where it ends.` |
| Bar | `{start} to {end}`, `{duration}`, `about {size}`, buttons `Cancel` and `Export clip` |
| Key picture note | `Starts up to {n} s before your start: clips begin on a key picture.` |
| Under one second | `Move the end at least 1 second from the start.` |
| Sound | `Sound isn't included in clips yet.` |
| Held gap | `The picture freezes for {n} s at {time}: the camera had no recording.` |
| Skipped gap | `{camera} has no recording from {a} to {b}; the clip skips it.` |
| Empty camera | `{camera} had no recording in this time.` |
| Nothing | `Nothing was recorded in this time.` |
| Cameras | `All cameras`, `{n} of {m} cameras`, `Cameras to save`, `All`, `None` |
| Progress (Mac) | `Saving {i} of {n}: {camera}` |
| Done (Mac) | `Saved {n} clip(s)`, button `Show in Finder` |
| Done (page) | toast `Your download has started.` |
| Failure | title `Couldn't save the clip`, then one sentence from the error |
| Too big | `This clip is too long. The most is {n} hours per camera.` |

### E. Mac contract (X08 builds, X09 uses; `App/Sources/Model/`)

```swift
struct ClipSelection: Equatable, Sendable {
    var start: Date
    var end: Date
    var cameras: [UUID]
    static let minimumDuration: TimeInterval = 1
    var range: ClosedRange<Date> { min(start, end)...max(start, end) }
    var duration: TimeInterval { range.upperBound.timeIntervalSince(range.lowerBound) }
    var isExportable: Bool { duration >= Self.minimumDuration && !cameras.isEmpty }
    func clamped(oldest: Date, newest: Date) -> ClipSelection
    func toggling(_ camera: UUID) -> ClipSelection      // keeps at least one camera
    func summary(calendar: Calendar) -> String          // "Oct 12, 2026, 2:02:10 PM to 2:05:42 PM"
}

protocol ClipDestinationPicking: Sendable {
    /// One camera, one part: a Save panel with `suggestedName`; several: a folders-only panel, returns the chosen folder. nil = cancelled.
    @MainActor func pickFile(suggestedName: String, startingIn: URL?) async -> URL?
    @MainActor func pickFolder(startingIn: URL?) async -> URL?
}

@MainActor @Observable final class ClipExportModel {
    enum State: Equatable {
        case idle
        case planning
        case exporting(progress: Double, label: String)
        case finished(urls: [URL], notes: [String])
        case failed(String)
    }
    private(set) var state: State
    init(exporter: any ClipExporting, cameraNames: @escaping @Sendable () -> [UUID: String], destinations: any ClipDestinationPicking,
         freeSpace: @escaping @Sendable (URL) -> Int64?, defaults: UserDefaults, now: @escaping @Sendable () -> Date)
    func preview(_ selection: ClipSelection) async -> ClipPreview?     // exact size and notes from the engine's plan
    func export(_ selection: ClipSelection) async
    func cancel()
    func dismissResult()
}
struct ClipPreview: Equatable, Sendable { var byteCount: Int64; var actualStart: Date; var leadIn: TimeInterval; var notes: [String]; var perCamera: [UUID: Int64] }
```

---

## File map (what each task creates or changes; the task document is the authority)

- **X01:** `BridgeEngine/NVR/ArchiveReading.swift`, `ArchiveStore.swift`, `PreviewArchive.swift` (the new read part); `ClipTypes.swift`, `ClipFileName.swift` (new); every fake and switch over `ArchiveReadPart` (`BridgeWebTests/FakeArchiveReading.swift`, `App/Tests/NVRPlaybackFakes.swift`, `App/Tests/ArchiveFrameSourceTests.swift`, `BridgeEngineTests/NVRFacadeTests.swift`, and whatever the grep finds); `BridgeEngineTests/ClipFileNameTests.swift`, `ArchiveStoreHeaderReadTests.swift`; the BridgeEngine README additions.
- **X02:** `BridgeEngine/NVR/ClipPlanner.swift`; `BridgeEngineTests/ClipPlannerTests.swift` (+ fixtures helpers).
- **X03:** `BridgeEngine/NVR/ClipLayout.swift`, `ClipWriter.swift`, `ClipBoxBuilder.swift`; `BridgeEngineTests/ClipLayoutTests.swift`, `ClipWriterTests.swift`, `ClipDecoderGateTests.swift`.
- **X04:** `BridgeEngine/NVR/ClipExporter.swift`; `BridgeEngineTests/ClipExporterTests.swift`, `ClipExporterLiveEdgeTests.swift`, `ClipExporterRealDataTests.swift` (opt in); README and contract rows for the engine part.
- **X05:** `BridgeWeb/ZipStream.swift`, `ClipLease.swift`, `HTTPTypes.swift` and `HTTPServer.swift` (a sized stream); `BridgeWebTests/ZipStreamTests.swift`, `SizedStreamTests.swift`, `ClipLeaseTests.swift`.
- **X06:** `BridgeWeb/WebApp+NVRClip.swift`, `WebApp+Routes.swift` (three entries), `BridgeBackend.swift` (the exporter), `BridgeDaemon/Daemon.swift` (wiring); `BridgeWebTests/NVRClipRouteTests.swift`.
- **X07:** `linux/web/js/nvr/clip.js`, `linux/web/js/screens/watch.js`, `nvr.js`, `linux/web/css/*`, `linux/web/js/api.js` (the three calls); `linux/web-dev/` (mock routes R13 to R15, fixtures, conformance checks); `linux/web-tests/clip-controller.test.mjs`, `clip-bar.test.mjs`.
- **X08:** `App/Sources/Model/Playback/ClipSelection.swift`, `ClipExportModel.swift`, `FileClipSink.swift`, `ClipDestinations.swift`; `App/Tests/ClipSelectionTests.swift`, `ClipExportModelTests.swift`, `FileClipSinkTests.swift`.
- **X09:** `App/Sources/Viewer/ClipBar.swift`, `ClipBand.swift`, `NVRTimelinePanel.swift`, `TimelineScrubber.swift`, `SingleCameraViewer.swift`, `NVRView.swift`, `NVRParts.swift`; `App/Sources/Model/Playback/NVRPanelModel.swift`, `NVRPageModel.swift`, `App/Sources/Model/AppModel.swift`; `App/Sources/Debug/ScreenshotCapture.swift`; `App/Tests/NVRPanelClipTests.swift`; `App/README.md`.
- **X10:** `linux/os/test-nvr.py` (clip phase), `linux/web-dev/` conformance additions not owned by X07, `docs/CONTRACT_CHANGES.md`, `Packages/CameraBridgeKit/Sources/BridgeWeb/README.md`, `docs/linux/USER-GUIDE.md`, the Wednesday checklist (`docs/superpowers/plans/2026-10-10-nvr/wednesday-box-checklist.md`), the NVR design spec's non-goal line (`docs/superpowers/specs/2026-10-10-nvr-design.md:89`).
- **X11:** no source files; `docs/superpowers/plans/2026-10-12-export-clip/RESULTS.md`.

## The final run (X11) and what the owner sees

Whole Swift package on macOS (three runs, the known timing flakes pass alone), the app suite, Linux (twice in a row), Node and lints, the C4 image in the private CI repository (`PUBLIC_REMOTE=git@github.com:coalsi/camera-bridge-ci.git`, no tag, no release) with its QEMU boot test (at least the 220 checks of C3 plus the clip checks), and the Mac release build (version 1.1 build 7, signed and notarized, not installed). The owner is then asked one line before the Mac build is installed, and is given the three sample clips' test (iPhone and a Windows PC) result to confirm.
