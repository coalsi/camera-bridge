# iOS and CarPlay box side Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The box serves HLS (live and recorded) behind short-lived tickets, for AirPlay and CarPlay, with no transcoding.

**Architecture:** A pure segmenter and playlist writer in BridgeWeb take `LiveMP4Remuxer.Part`s. A per-camera packager owns a live slot and a subscription. Tickets live in memory; a `.viewer` route mints them and `.open` routes serve files by the ticket in the path.

**Tech Stack:** Swift 6, Packages/CameraBridgeKit (BridgeWeb, BridgeEngine), Swift Testing or XCTest as the neighbouring tests do.

**Spec:** docs/superpowers/specs/2026-11-06-ios-carplay-app-design.md (sections "The box side"). Code map: `.superpowers/ios-map/box-hls.md` in the worktree, git-ignored (file:line for everything here).

## Global Constraints

- Worktree `.claude/worktrees/box-hls`, branch `box-hls`. Never commit to main, push, or publish.
- BridgeWeb may not import FMP4 (PortabilityTests.swift:67). No transcoding. Packages stay portable: no Apple-only frameworks outside PlatformApple.
- Viewer key never in a URL (the `.viewer` token refusal stays). The ticket in the path is the one documented exception.
- Run tests with `cd Packages/CameraBridgeKit && swift test --filter <X>`; the whole `BridgeWebTests` and `BridgeEngineTests` before each commit. Web tests: `cd linux && node --test web-tests/*.test.mjs`.
- No LAN addresses, /Users/ paths, e-mail addresses or box labels in committed files. Commit messages are one plain sentence saying what a person gets, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never contact the owner's box. Dev daemon only, on loopback.

## Review Focus

1. A live stream that restarts mid-playlist (camera drops, format change): the playlist must stay valid, with a discontinuity, and never reuse a segment number.
2. The first GOP: audio arrives after the first init; the player must never see a video-only init replaced in place after publishing.
3. A viewer removed while a player is running: the next file request is 404, and the packager stops when nobody is left.
4. A camera with a 10 s key interval: long segments, target duration honest, first playlist answer within 20 s or a 503.
5. A recorded range starting mid-GOP, across a recording file change, with an open event (no end).

---

### Task 1: Parts carry their duration

**Files:**
- Modify: `Packages/CameraBridgeKit/Sources/BridgeEngine/LiveVideo/LiveMP4Remuxer.swift:15,:90`, callers in `Sources/BridgeWeb/WebApp+LiveVideo.swift`
- Test: `Tests/BridgeEngineTests/LiveMP4RemuxerTests.swift`

**Interfaces:**
- Produces: `LiveMP4Remuxer.Part.media(Data, keyframe: Bool, duration: Int64)` (90 kHz ticks, the frame's own duration).

- [ ] **Step 1:** Add test `mediaPartsCarryTheirFrameDuration`: frames 3000 ticks apart give `duration == 3000` on every media part.
- [ ] **Step 2:** Run it, see it fail. Add the field (`decodeTime(frame) - decodeTime(previous)`), update callers.
- [ ] **Step 3:** Run `BridgeEngineTests`, `BridgeWebTests`. Commit.

### Task 2: HLS segmenter and playlists (pure)

**Files:**
- Create: `Sources/BridgeWeb/HLS/HLSSegmenter.swift`, `Sources/BridgeWeb/HLS/HLSPlaylist.swift`
- Test: `Tests/BridgeWebTests/HLSSegmenterTests.swift`, `HLSPlaylistTests.swift`

**Interfaces:**
- Produces:
  - `struct HLSSegment { let number: Int; let initNumber: Int; let duration: Double; let data: Data; let startsDiscontinuity: Bool }`
  - `struct HLSSegmenter { init(minimumSegment: Int64 = 180_000, window: Int = 6, maximumBytes: Int = 64 << 20); mutating func add(_ part: LiveMP4Remuxer.Part); var published: [HLSSegment]; var mediaSequence: Int; var discontinuitySequence: Int; var targetDuration: Int?; var codecs: String?; var resolution: (Int, Int)?; var bandwidth: Int?; func initSegment(_ number: Int) -> Data?; func segment(_ number: Int) -> Data? }`
  - `enum HLSPlaylist { static func master(codecs: String, width: Int, height: Int, bandwidth: Int) -> String; static func live(_ s: HLSSegmenter) -> String?; static func recorded(_ items: [RecordedSegment]) -> String }`, `struct RecordedSegment { number, initNumber, duration, startsDiscontinuity }`
  - `live(_:)` returns nil until two segments are published.

- [ ] **Step 1: Write the failing tests**, exact values:
  - `cutsAtTheFirstKeyFrameTwoSecondsIn`: key frames every 1 s, 30 fps → segments of 2.0 s.
  - `neverCutsOffAKeyFrame`: key frames every 10 s → segments of 10.0 s; `targetDuration == 15`.
  - `targetDurationNeverChanges`: first interval 2 s gives 6; a later 8 s segment leaves it at 6.
  - `slidesOverSixAndCountsTheSequence`: after 9 segments, `published.count == 6`, `mediaSequence == 3`.
  - `dropsOldestPastTheByteCap`.
  - `anInitBeforePublishingReplacesIt`: init A, media, init B, key frame: no discontinuity, buffered media dropped, `initSegment(0)` is B.
  - `anInitAfterPublishingIsADiscontinuity`: new `initNumber`, `startsDiscontinuity == true`; numbers keep rising; `discontinuitySequence` rises when it slides out.
  - `liveIsNilUntilTwoSegments`.
  - Playlist golden tests: `#EXTM3U`, `#EXT-X-VERSION:7`, `#EXT-X-INDEPENDENT-SEGMENTS`, `#EXT-X-TARGETDURATION:6`, `#EXT-X-MEDIA-SEQUENCE:3`, `#EXT-X-DISCONTINUITY-SEQUENCE:1`, `#EXT-X-MAP:URI="init-0.mp4"`, `#EXTINF:2.000,`, `seg-4.m4s`, `#EXT-X-DISCONTINUITY`; no `EXT-X-ENDLIST` on live; `#EXT-X-PLAYLIST-TYPE:VOD` and `#EXT-X-ENDLIST` on recorded; master has `BANDWIDTH=`, `CODECS="hvc1...,mp4a.40.2"`, `RESOLUTION=1280x720`, then `media.m3u8`.
- [ ] **Step 2:** Run, see them fail. Implement. CODECS comes from the part's mime; BANDWIDTH is peak bits per second over finished segments.
- [ ] **Step 3:** Run, pass. Commit.

### Task 3: Tickets

**Files:**
- Create: `Sources/BridgeWeb/HLS/HLSTickets.swift`, `Sources/BridgeWeb/WebApp+HLS.swift`
- Modify: `Sources/BridgeWeb/WebApp.swift` (store), `WebApp+Routes.swift:97` (`+ hlsRoutes`)
- Test: `Tests/BridgeWebTests/HLSTicketRoutesTests.swift`, add the mint route to `ViewerAccessTests.swift:15`

**Interfaces:**
- Produces:
  - `enum HLSTicketKind: Sendable, Equatable { case live(stream: LiveStreamChoice, audio: Bool), recorded(from: Int64, to: Int64) }`
  - `actor HLSTickets { func mint(viewer: String, camera: UUID, kind: HLSTicketKind, now: Date) -> String; func touch(_ ticket: String, now: Date) -> HLSTicket?; func drop(viewer: String) }` with lifetime 300 s since last use, 21,600 s hard cap, 8 per viewer.
  - `POST hls/tickets` `.viewer` returning `{url, expiresIn}`. `GET hls/:ticket/:file` `.open`.

- [ ] **Step 1: Failing tests:** `mintNeedsAViewerKey` (401 without), `aSessionCookieMayMintToo` (the `.viewer` fallback, for the web dev page), `answersAURLWithNoKeyInIt`, `refusesAnUnknownCamera` (404), `unknownTicketIs404WithNoDetail` (body `{}`-free and same as unknown file), `expiresFiveMinutesAfterLastUse` (injected clock), `hardCapSixHours`, `eighthIsKeptAndNinthDropsTheOldest`, `removedViewerGets404AtOnce` (`auth.isViewerListed` on every request), `everyFileIsNoStore`, `ticketIsComparedInConstantTime` (uses `Secrets.constantTimeEqual`), `hostCheckStillApplies`.
- [ ] **Step 2:** Implement. Ticket = `Secrets` 32 random bytes as hex. The handler answers only from tickets; no other state leaks.
- [ ] **Step 3:** Pass, update "eleven" to "twelve" where tests pin it (see code map, section 3). Commit.

### Task 4: Live packager

**Files:**
- Create: `Sources/BridgeWeb/HLS/HLSLivePackager.swift`
- Modify: `Sources/BridgeWeb/WebApp+HLS.swift`, `WebApp+LiveVideo.swift:124-179` (share the pump through a sink closure rather than copy it)
- Test: `Tests/BridgeWebTests/HLSLiveTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 3. `takeLiveSlot()`/`releaseLiveSlot` (WebApp.swift:284-296), `pumpLiveCamera`'s remuxer loop.
- Produces: `actor HLSLivePackager` keyed by (camera, stream, audio): `func playlist(waitingUpTo: Duration) async -> String?`, `func master(waitingUpTo:) async -> String?`, `func initSegment(_:) -> Data?`, `func segment(_:) -> Data?`, `func stop()`; idle stop after 30 s without a request; one live slot each, none free → 429 `too_many_streams` with Retry-After 5 at mint.

- [ ] **Step 1: Failing tests** with the fake backend used by `LiveVideoRouteTests`: `twoTicketsShareOnePackager`, `noSlotMeansTooManyStreams`, `stopsThirtySecondsAfterTheLastRequestAndGivesItsSlotBack`, `firstPlaylistWaitsForTwoSegments`, `firstPlaylistAnswers503After20Seconds` (Retry-After), `aRestartedSubscriptionAddsADiscontinuity`, `backlogDropsThePacketsNotThePlaylist`, `audioFalseHasNoAudioTrack`, `removingTheViewerStopsAPackagerNobodyElseUses`.
- [ ] **Step 2:** Implement, tests pass. Commit.

### Task 5: Recorded playlists

**Files:**
- Create: `Sources/BridgeWeb/HLS/HLSRecorded.swift`
- Modify: `WebApp+HLS.swift`, `WebApp+NVRMedia.swift` (expose `readInit` and `segment(of:)` to it)
- Test: `Tests/BridgeWebTests/HLSRecordedTests.swift`

**Interfaces:**
- Consumes: `ArchiveReading` (`fragment(camera:containing:)`, `fragment(camera:startingAfter:)`, `read`), `ArchiveFragment.hasKeyframe/backToKey`, the rig in `NVRTestRig.swift`.
- Produces: a recorded ticket's `index.m3u8` (master), `media.m3u8` (VOD), `init-<n>.mp4` (one per recording file), `seg-<n>.m4s` (key fragment plus following continuation fragments, concatenated). Plans once per ticket and keeps the plan. At most 2 hours: a longer range is 400 `range_too_long`. No recordings in range: 404 at mint.

- [ ] **Step 1: Failing tests:** `startsOnTheKeyFragmentBeforeTheStart`, `joinsContinuationFragmentsIntoOneSegment`, `aNewFileIsADiscontinuityWithItsOwnMap`, `endsWithEndList`, `anOpenEventEndsAtNow`, `refusesMoreThanTwoHours`, `takesAnArchiveSlotPerRead` (429 `busy` as `fragments`), `sumOfExtinfMatchesTheRange` (within one GOP).
- [ ] **Step 2:** Implement, tests pass. Commit.

### Task 6: A real player opens it

**Files:**
- Create: `Tools/hls-check/main.swift` (a small macOS AVFoundation tool, excluded from the package and public export is fine)
- Docs only otherwise.

- [ ] **Step 1:** Start the dev daemon as `.claude/launch.json` and `docs/linux/DEV*` describe (loopback, demo camera). Mint tickets with curl using a viewer key made through the pairing API on that dev daemon.
- [ ] **Step 2:** The tool opens the URL in `AVPlayer` for 30 s and prints `status`, `isPlaybackLikelyToKeepUp`, the current time advancing, `asset.load(.isCompatibleWithAirPlayVideo)`, and any `errorLog` events. Expected: `readyToPlay`, time advancing, no fatal log events, for live, and for a recorded range if the demo daemon has recordings; if not, feed the recorded test fixture through a test harness and state what wasn't covered.
- [ ] **Step 3:** Fix what this shows (expect tfdt or timescale issues). `ffprobe` each `init-0.mp4` + `seg-N.m4s`. Commit fixes with tests.

### Task 7: Wording and docs

**Files:**
- Modify: `linux/web/js/screens/viewers-card.js` (:27,:31,:55-64,:98,:108,:115,:123,:129,:134), `linux/web/js/screens/settings.js`, `linux/web-tests/viewers-card.test.mjs`, `WebApp+Viewers.swift:153,:157,:159,:205,:218`, `WebApp.swift:437`, `AuthStore.swift:292`, `docs/linux/ARCHITECTURE.md`, `Sources/BridgeWeb/README.md`, `docs/CONTRACT_CHANGES.md`, `SECURITY.md:42`, `docs/linux/USER-GUIDE.md`, `linux/web/js/release-notes.js`

- [ ] **Step 1:** Card heading "Apple TV and iPhone"; sentences say "device" where they mean any viewer; hint "Open Camera Bridge on the device and enter the code it shows."; default name "Device". Anchor `apple-tv` and route `#/pair/<code>` stay. Add `#/pair/<code>` filling the code when opened from the phone itself if it doesn't already.
- [ ] **Step 2:** Docs: routes table rows for `hls/tickets` and `hls/:ticket/:file`, "twelve viewer routes", the documented path-ticket exception, CONTRACT_CHANGES row, a user-guide section on iPhone, iPad and CarPlay (home network only for now). Release note entry under the next version (not published).
- [ ] **Step 3:** All Swift and web tests pass. `Tools/publish-public.sh --dry-run` is NOT run here. Commit.
