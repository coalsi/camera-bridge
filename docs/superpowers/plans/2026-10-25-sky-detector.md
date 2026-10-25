# Sky Detector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Sky detector on Camera Bridge OS, all three phases. A camera that looks at the sky gets these:
- every light that crosses it is detected and tracked;
- what can be explained is explained: planes from a flight feed, satellites by orbit, stars, planets and the Moon from a catalogue and an ephemeris, meteors, bugs and birds by rules and then a model trained on the box, and the AI for what is left over;
- a morning sky log, where the person can correct any entry with one tap;
- an alert (a toast, the Notifications page and an Apple Home sensor), only for what stays unexplained and is unusual.

**Architecture:**
- **The maths.** All sky maths is portable Swift in a new folder, `BridgeEngine/Sky/`: the geometry, the ephemerides, the camera model with lens distortion, aim fitting, detection, tracking, SGP4, matching, the rules and the classifier.
- **Pictures.** A `SkyMonitor` in `CameraRuntime` decodes the stream it chooses (the sub stream, or the main stream on the GPU) into luma pictures, five a second. Each camera's `SkyCameraDetector` turns those pictures into tracks, and those tracks into log entries.
- **The service.** A `SkyService` on the engine owns everything that is shared: the flight sources, the orbits, the weather and the AI queue. It runs only while at least one camera has the detector on.
- **The log.** It lives beside the recordings, in `.sky/` (the pattern of `ArchiveEventLog`). What the box learns lives in the data directory.
- **The camera profiles.** They reuse the Clean-picture backup pattern.

**Tech Stack:**
- Swift 6.4 and Swift Testing, in `Packages/CameraBridgeKit`. Foundation only outside PlatformApple.
- ffmpeg decoder child processes with VA-API (PlatformLinux).
- The existing `AuthenticatingHTTPClient`.
- Hikvision ISAPI and ONVIF imaging (CameraAdapters).
- The HAP sensors bridge.
- A vanilla JS page (`linux/web`), tested with Node's built-in test runner.
- The mkosi image (`linux/os`).

**Spec:** `docs/superpowers/specs/2026-10-25-sky-detector-design.md` (binding), read with two additions from the coordinator on 2026-10-25:
- **Star maps**, in Task 10: a bright-star catalogue and an on-box ephemeris. Known lights are ignored, the aim is refined from stars, and new points become candidates.
- **Lens distortion**, in Tasks 1 and 2: radial terms and a model of the stitched panorama, fitted robustly and freed gradually, with a residual in pixels.

The owner said "build it all all phases, test it once": every task is built and tested in turn, and the box is tested once, at the end (Final section).

`K` = `Packages/CameraBridgeKit`. `S` = `K/Sources/BridgeEngine/Sky`. `W` = `linux/web`. Swift commands run in `K`; `sh Tools/…` and `linux/…` commands run at the repository root.

## Global Constraints

**Platform and dependencies**
- Portable Swift: Apple-only frameworks only in PlatformApple. Everything must build and pass on Linux with Swift 6.4 (`sh Tools/linux-test.sh test --filter …`).
- No new modules and no new package dependencies. SGP4, the tracker, the camera model, the classifier and all JSON parsing are written here in Swift.
- Downloads use the existing `AuthenticatingHTTPClient`, through one shared client (`URLSessionSkyHTTP`, Task 4).

**Privacy and the network**
- Nothing is sent off the box while the detector is off: no camera has `skyDetector.enabled`.
- Online flight data and weather are fetched only while it is on, and only for a wide box around the location. The centre is rounded to the nearest 0.5° (about 50 km), and flights are asked for within 150 NM of it.
- Satellite orbits are downloaded from CelesTrak at most once a day, and only while the detector is on.
- The star catalogue is bundled, so it is never downloaded (Task 10).
- The AI gets only stills, and only of leftovers. No video, ever.
- The location is kept only on the box. It never appears in the following:
  - logs;
  - the diagnostics report;
  - notifications;
  - AI requests;
  - online requests, which carry only the rounded centre.

**The camera**
- Never touch a camera's network settings. Change it only through its own interface (Hikvision ISAPI) or ONVIF imaging.
- The detector works on the camera's **original** picture. It never sees the picture straightened by `PictureCorrection`: the sky decoder never applies a correction, and the camera model describes the camera's own picture, so turning Straighten on or off changes no aim.
- The night-sky profile changes the whole camera, so its night recordings change too. The owner accepted this.
- Every setting the profile changes is backed up before the first change. Turning the detector off puts the camera back **exactly** as it was.

**Budget**
- One sky camera uses under about 25 % of one N150 core, measured on the box (Final).
- Analysis runs at most 5 pictures a second, on luma at most 1920 px wide.

**Values from the design (exact)**
- Plane sources are tried in this order: a network feed (dump1090, readsb, tar1090 or PiAware `aircraft.json`, its address set in Settings, the box offering ones it finds), then a USB ADS-B receiver on the box, then free online data (adsb.fi).
- A match is labelled "probable plane" until the aim is good.
- Satellites count as visible only while they are sunlit and the observer is in darkness.
- Stars, planets and the Moon are ignored.
- **Stream.** Use the sub stream unless it is narrower than 1280 px. If it is, use the main stream decoded on the GPU at a reduced rate (VA-API). The card and the log say which.
- **Learning period.** No alerts until the camera has a baseline: 30 matched planes, plus 10 matched satellites whenever orbits are loaded. The log flags candidates meanwhile.
- **Unusual.** An object is unusual when it is unexplained (no flight, no orbit, not a bug, bird or meteor) **and** at least one of these holds:
  - it moves faster across the sky than known planes or satellites at that place in the view;
  - it looks larger or brighter than them;
  - it stops suddenly;
  - it turns sharply.
- **Alert.** An alert waits up to 60 s for the AI's answer.
  - An answer of `plane`, `bird`, `insect`, `satellite` or `meteor` suppresses it.
  - Every other answer, a reached daily limit, or no AI configured means it alerts only if the measured rule says unusual.
  - A person's later correction overrides both.
- **De-duplication.** Repeats of the same object within a short window count as one alert. This plan makes the window one alert per camera per 300 s.
- **Home sensor.** One Sky detector sensor per sky camera.
- **AI kinds:** `plane, satellite, bird, insect, meteor, balloon, drone, artifact` (a lens or reflection artifact) and `unknown`.
- **AI pictures:** start, middle, end, and a stack of the path. Its own daily limit, default **50** (range 1…1000), separate from event descriptions.
- **Camera profiles:** night-sky after sunset and day after sunrise, from the sun's times at the location.
- **The local model:** CPU only, no internet. It trains in seconds on the N150 and is retrained nightly. The person's corrections count most.

**Copy (exact)**
- Card title **Sky detector**.
- Aim states **rough → good → precise**. The aim line reads "Aim: precise, 214 stars matched, 1.8 px".
- Summary "Last night: 1 unexplained, 214 explained".
- Conditions in the form "☁︎ clear until 3 AM; sky not visible 3–5 AM".
- Speed always as "faster across the sky than…", for example "about 6× faster across the sky than planes at that height".
- Size as "looks larger than…" and "looks brighter than…".
- No real size, distance or speed is ever claimed (no km/h, mph, metres, feet or miles about an object).
- Corrections: "That was a…" with the buttons Plane, Bird, Bug, Satellite, Meteor and Not sure.

**Tests and data**
- Only made-up data: a fake `aircraft.json` and sample TLEs as Swift string fixtures in `K/Tests/BridgeEngineTests/SkyFixtures.swift`, synthetic tracks and frames, a small made-up star list, and 192.168.77.x camera and feed addresses.
- The made-up location is **latitude 40.0000, longitude −100.0000 (100° W), height 0 m**.
- No real keys: fakes like `sk-test-0000`. No personal details. No real home location.
- The owner's real flight-feed address never appears in code, tests or docs (it is set on the box). Its only allowed occurrence in the repository is the design document.
- This plan is exported publicly (only the specs are private), so it names no person's camera, host or address.

**Process**
- Swift: `swift test --filter <Suite>`. Linux: `sh Tools/linux-test.sh test --filter <Suite>`. Web: `sh linux/web-tests/run.sh`. Lint: `node linux/web-dev/lint.mjs`. Docs: `swift test --filter "DocsConsistencyTests|PortabilityTests"`.
- Every public addition gets a `docs/CONTRACT_CHANGES.md` row with 5 cells and the Status **additive**, plus a line in its module README's "Additions beyond the contract".
- Every API route goes in `K/Sources/BridgeWeb/README.md`, and every page change in `W/README.md`.
- Nothing is published or pushed to GitHub and no CI is dispatched without the owner's yes.
- Downloading a file, even at development time (the star catalogue's source, Task 10), needs the owner's OK first.
- Use the shared `.build` folders. Do not create scratch build directories; they filled the disk once.

## Decisions this plan makes (builder's calls)

| Area | Decision |
|---|---|
| Stream | Chosen at runtime by `SkyStreamChoice` (Task 6): the sub stream when it is at least 1280 px wide, else the main stream. The main stream goes through `makeSkyDecoder`: VA-API for heavy streams, scaled to 1920 px, and only every Nth picture kept on the GPU, so about 5 a second are copied back. The camera's status says which stream is in use, and the final box test records it. |
| Camera model | Two lens forms. **rectilinear:** a pinhole with Brown radial distortion `k1, k2, k3`. Security lenses up to about 120° are rectilinear designs with barrel distortion, which this form fits with 2–3 terms; an equidistant fisheye form suits ≥150° single lenses only, and those are out of scope. **panorama:** for stitched views (aspect ≥ 2:1). An equirectangular or cylindrical base, chosen by the fit. A separate quadratic 2D correction for each half, split at the seam (x = 0.5), so each lens and the seam get their own terms. |
| Aim fitting | RANSAC start (200 samples), then Levenberg–Marquardt with Huber weights (δ = 3 px of the original picture), with a ridge prior on every distortion term. Terms are freed in stages as matches accumulate (Task 2). Planes come first; stars refine (Task 10). |
| Tracker | A nearest-neighbour tracker with alpha-beta (constant-velocity) prediction. It coasts 1.5 s over blinking lights, and two aligned streaks are enough to start a meteor's track. |
| Rules before learning | Plane speed p95 2.0°/s and size p95 0.3° in every band. They are used only to flag candidates; nothing alerts before the baseline. |
| Local model | k-nearest-neighbours (k = 7, distance-weighted) on 11 standardized features. Weights: a person's correction 5, flight or orbit 1, AI 1, rule 0.5. At most 5,000 examples. Retrained 30 min after sunrise. |
| Online flights | adsb.fi open data, `https://opendata.adsb.fi/api/v2/lat/{lat}/lon/{lon}/dist/150`. At most every 10 s, backing off on 429. Only when no network feed or USB receiver answers. |
| Weather | Open-Meteo hourly `cloud_cover` at the rounded point, once an hour, combined with the camera's own measure of how much sky is visible. No weather from a Pi (no interface is known). |
| Camera profile values | **Hikvision:** `SupplementLight/supplementLightMode` `close` (infrared off). `IrcutFilter/IrcutFilterType` `night` when SupplementLight exists, else `day` (so the IR LEDs stay off). `Shutter/ShutterLevel` `1/25` (no slow shutter). `Gain/GainLevel` `80`. **ONVIF:** `IrCutFilter` `ON`, `Exposure/MaxExposureTime` 40000 µs, `Exposure/MaxGain` 0.8 × the camera's maximum. **Day:** the camera's own settings, written back from the backup. Each value is written only where the camera has it. |
| Home sensor | A MotionSensor accessory "<camera> Sky Detector" on the Camera Bridge Sensors bridge. It reads motion for 30 s per alert. It sits outside `EventRouter`, so it never moves the camera's motion or HomeKit Secure Video. |
| Clips | No separate clip file. The "short clip" is the recording itself, opened through the Watch route or the existing clip download, from start − 3 s to end + 3 s. Stills are kept in `.sky/`. Both follow the recordings' retention, so the detector needs a recordings folder. |
| Star catalogue | Bundled, not downloaded: the Yale Bright Star Catalogue, 5th revised edition (Hoffleit & Warren), from CDS V/50. CDS and NASA HEASARC distribute it without restriction, and it is credited in `NOTICE` and `THIRD_PARTY_LICENSES.md`. About 9,100 stars to magnitude 6.5, as about 220 KB of generated Swift source. That way nothing is ever fetched, and there is no gzip and no checksum logic on the box. |
| Satellites | CelesTrak `GROUP=active` TLEs, near-Earth only. Elements with a period of 225 min or more (deep space) are dropped. |
| USB receiver | `readsb` from the image's Debian release, or `dump1090-fa` if Debian has no `readsb`. It runs as an engine helper while the detector is on and a supported RTL-SDR stick is plugged in. Both write the same `aircraft.json`. |

## Review Focus

1. **Dusk, dawn and the camera's own switches.** An IR-cut flip, an exposure jump, headlights, the profile switch itself, or the Sun or Moon in view changes the whole picture. That must reset the background and make no tracks, not a burst of "unexplained" entries. Tests:
   - Task 3: `aWholePictureChangeResetsWithoutTracks`;
   - Task 14: `theSecondsAfterAProfileSwitchMakeNoTracks`.
2. **The feed host's clock is wrong, or the feed lags.** The feed's host may be minutes off, and `seen_pos` can be up to 30 s old. Matching uses the box's receive time minus `seen_pos`, never the feed's own `now`. Test in Task 4: `aFeedWithAWrongClockStillMatches`.
3. **A night across midnight, a DST night, and places where the Sun never sets or never rises.** A night is one log, named by the local date of its sunset in the bridge's zone. A 25-hour DST night is whole. Where there is no sunset or no sunrise, the day view shows the whole local day, the night view is empty, and nothing crashes. Tests:
   - Task 1: `nightWindowsAcrossMidnightDSTAndPolarDays`;
   - Task 5: `aNightIsOneFileAcrossMidnight`.
4. **The camera goes away mid-profile.** This covers a bridge restart mid-night, a camera unreachable when the detector is turned off, and the person changing the camera's own day settings. The camera is always restored to what it had before the last night, the restore is retried, and the backup is never lost. Tests in Task 14:
   - `aRestartMidProfileStillRestores`;
   - `anUnreachableCameraKeepsItsBackupAndRetries`;
   - `dayChangesByThePersonAreKept`.
5. **The stream changes under the detector.** The sub stream goes offline, the main stream changes size or codec, or the camera restarts. The detector chooses again, restarts the decoder at the next keyframe, records a gap, and makes no tracks across it. Tests:
   - Task 6: `aFormatChangeChoosesTheStreamAgain`;
   - Task 7: `aGapEndsOpenTracksWithoutEntries`.

## File map

| Where | What |
|---|---|
| `S/SkyGeometry.swift`, `S/SunEphemeris.swift`, `S/SkyCameraModel.swift` | Directions, the observer, time, the Sun and nights, the camera model with distortion (Task 1) |
| `S/SkyAim.swift`, `S/AimFitter.swift`, `S/SkyAimStore.swift` | Aim quality and status, the robust staged fit, the stored aim and its matches (Task 2) |
| `S/SkyFrameAnalyzer.swift`, `S/SkyTracker.swift`, `S/TrackMeasurer.swift`, `S/SkyVisibility.swift` | Detections, tracks, measures, how much sky is visible (Task 3) |
| `S/SkyHTTP.swift`, `S/AircraftFeed.swift`, `S/FlightHistory.swift`, `S/FlightFeedFinder.swift`, `S/FlightMatcher.swift` | Flights (Task 4) |
| `S/SkySettings.swift`, `S/SkyEntry.swift`, `S/SkyLogStore.swift`, `K/Sources/BridgeEngine/BridgeEngine+Sky.swift`, `K/Sources/BridgeWeb/WebApp+Sky.swift` | Settings, the log, its API (Task 5) |
| `K/Sources/BridgeEngine/Runtime/SkyStream.swift`, `K/Sources/BridgeEngine/Runtime/SkyMonitor.swift` | The picture stream (Task 6) |
| `S/SkyCameraDetector.swift`, `S/SkyService.swift` | The detector at work (Task 7) |
| `W/js/screens/sky-model.js`, `W/js/screens/sky-card.js`, `W/js/screens/sky-log.js`, `W/sky.css`, `linux/web-dev/lib/sky.mjs` | The page (Task 8) |
| `S/TwoLineElements.swift`, `S/SGP4.swift`, `S/OrbitCatalog.swift`, `S/OrbitMatcher.swift` | Satellites (Task 9) |
| `S/StarCatalog.swift`, `S/BrightStars+Data.swift` (generated), `Tools/make-star-catalog.sh`, `S/PlanetEphemeris.swift`, `S/MoonEphemeris.swift`, `S/PointSources.swift`, `S/PointLightWatch.swift` | Stars, planets, the Moon, point lights (Task 10) |
| `S/SkyRules.swift`, `S/SkyBaseline.swift`, `S/SkyAlertGate.swift` | Rules, the unusual rule, learning, de-duplication (Task 11) |
| `S/SkyAI.swift`, `S/AnthropicSkyClassifier.swift`, `S/OpenAICompatibleSkyClassifier.swift`, `S/SkyLeftovers.swift`, `S/SkyAlert.swift` | The AI for leftovers and the alert (Task 12) |
| `S/SkyModel.swift`, `S/SkyExampleStore.swift` | The local model (Task 13) |
| `K/Sources/CameraAdapters/Hikvision/HikvisionISAPI+Image.swift`, `K/Sources/CameraAdapters/ONVIF/CameraSettingsService+SkyProfile.swift`, `S/SkyProfiles.swift` | Camera profiles (Task 14) |
| `S/ADSBReceiver.swift`, `S/OnlineFlights.swift`, `S/SkyWeather.swift`, `linux/os/mkosi.conf`, `linux/os/mkosi.postinst.chroot` | More sources (Task 15) |
| Tests | `K/Tests/BridgeEngineTests/Sky*Tests.swift` with `SkyFixtures.swift`; `K/Tests/CameraAdaptersTests/SkyProfileTests.swift`; `K/Tests/BridgeWebTests/SkyAPITests.swift`; `K/Tests/PlatformLinuxCodecsTests/SkyDecoderTests.swift`; `linux/web-tests/sky-*.test.mjs` |

---

# Phase 1: detection, tracking, the log, network flight feed, aim from planes, corrections

### Task 1: Sky geometry, the Sun and the camera model with lens distortion

**Files:**
- Create:
  - `S/SkyGeometry.swift`
  - `S/SunEphemeris.swift`
  - `S/SkyCameraModel.swift`
- Test:
  - `K/Tests/BridgeEngineTests/SkyGeometryTests.swift`
  - `K/Tests/BridgeEngineTests/SkyCameraModelTests.swift`
  - `K/Tests/BridgeEngineTests/SkyFixtures.swift`. This one holds the made-up location `SkyFixtures.observer` and the truth models; later tasks add to it.

**Interfaces (produces):**

```swift
public struct SkyDirection: Codable, Sendable, Equatable { public var azimuth: Double; public var elevation: Double }   // degrees; azimuth from true north, clockwise
struct SkyObserver: Sendable, Equatable { var latitude: Double; var longitude: Double; var heightMeters: Double }
enum SkyMath {
    static func separation(_ a: SkyDirection, _ b: SkyDirection) -> Double                       // degrees
    static func julianDate(_ date: Date) -> Double
    static func greenwichSiderealDegrees(_ date: Date) -> Double
    static func horizontal(rightAscension: Double, declination: Double, at date: Date, observer: SkyObserver) -> SkyDirection
    static func direction(from observer: SkyObserver, toLatitude: Double, longitude: Double, altitudeMeters: Double) -> (direction: SkyDirection, rangeMeters: Double)   // WGS84 → ENU
    static func ecef(latitude: Double, longitude: Double, altitudeMeters: Double) -> SIMD3<Double>
}
enum SunEphemeris {
    static func equatorial(at date: Date) -> (rightAscension: Double, declination: Double)       // low precision (Meeus ch. 25), ≤ 0.01°
    static func direction(at date: Date, observer: SkyObserver) -> SkyDirection
    static let horizonElevation = -0.833   // sunset and sunrise
    static let darkElevation = -6.0        // "the observer is in darkness" (civil twilight's end)
}
public enum SkyLogView: String, Codable, Sendable { case night, day }
struct SkyNightWindow: Sendable, Equatable { var name: String; var sunset: Date?; var sunrise: Date? }   // name "yyyy-MM-dd": the local date of the sunset
enum SkyNight {
    static func window(named name: String, observer: SkyObserver, zone: TimeZone) -> SkyNightWindow
    static func name(containing date: Date, observer: SkyObserver, zone: TimeZone) -> String   // the night that contains `date`, or the latest one that ended before it
    static func span(_ window: SkyNightWindow, view: SkyLogView, zone: TimeZone) -> ClosedRange<Date>
}
struct PixelPoint: Codable, Sendable, Equatable { var x: Double; var y: Double }   // 0…1 of the camera's ORIGINAL picture (never straightened)
struct SkyCameraModel: Codable, Sendable, Equatable {
    enum Lens: String, Codable { case rectilinear, panorama }
    enum VerticalMapping: String, Codable { case linear, tangent }   // panorama: equirectangular or cylindrical
    struct HalfCorrection: Codable, Equatable { var dx: [Double]; var dy: [Double] }   // 6 coefficients each over (1, s, t, s², st, t²)
    var lens: Lens
    var yaw: Double; var pitch: Double; var roll: Double        // degrees: azimuth and elevation of the picture's centre, roll about the view axis
    var horizontalFOV: Double; var verticalFOV: Double
    var verticalMapping: VerticalMapping
    var radial: [Double]                                         // rectilinear: k1, k2, k3 (missing = 0)
    var halves: [HalfCorrection]                                 // panorama: [left, right] (empty = none)
    static let seam = 0.5
    func project(_ direction: SkyDirection) -> PixelPoint?       // nil behind the camera or outside 0…1
    func direction(at point: PixelPoint) -> SkyDirection?        // inverse: Newton, at most 10 steps, ≤ 1e-9 normalized
    func degreesPerPixel(at point: PixelPoint, pictureWidth: Int) -> Double
    static func initial(facing azimuth: Double, tilt: Double, pictureWidth: Int, pictureHeight: Int) -> SkyCameraModel
}
```

Notes:
- `initial`:
  - an aspect of 2.0 or more → `.panorama` with `horizontalFOV` 180 and `verticalFOV` 180 × height / width, mapping `.linear`;
  - otherwise `.rectilinear` with `horizontalFOV` 100;
  - in both cases yaw = facing, pitch = tilt, roll 0, and no distortion.
- **Panorama projection:**
  - camera-frame longitude λ and latitude φ map to u = 0.5 + λ / hFOV and v = 0.5 − m(φ) / m(vFOV / 2) / 2, where m is the identity for `.linear` and tan for `.tangent`;
  - the half is h = u < 0.5 ? 0 : 1, with local coordinates s = (u − (h == 0 ? 0.25 : 0.75)) × 4 and t = (v − 0.5) × 2;
  - add Σ dx·basis to u and Σ dy·basis to v.
- **Rectilinear:** a pinhole with focal length from hFOV, then r_d = r(1 + k1 r² + k2 r⁴ + k3 r⁶).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func separationAndHorizontalAreRight()   // Polaris-like RA 37.95°, Dec 89.26° from SkyFixtures.observer: elevation ≈ latitude ± 0.8°;
    // separation of (0,0)/(90,0) == 90 ± 1e-9
@Test func aPlaneAboveIsAtTheRightDirection()  // a point 10 km north at 10,000 m from SkyFixtures.observer → azimuth 0 ± 0.01, elevation 44.9 ± 0.2 (WGS84 curvature included)
@Test func sunMatchesMeeusExample()            // 1992-10-13 00:00 TD: RA 198.38 ± 0.01°, Dec −7.785 ± 0.01° (Meeus example 25.a)
@Test func nightWindowsAcrossMidnightDSTAndPolarDays()   // America/Chicago night of 2026-11-01 (DST ends) is one window from that sunset to the next
    // sunrise (> 12 h, its name "2026-10-31"); name(containing: 02:00 local) is the evening before's date; at latitude 78 N on 2026-06-21:
    // sunset nil, sunrise nil, span(.day) == the local day and span(.night) is empty; never traps
@Test func projectAndBackRoundTrip()           // both lenses, truth models from SkyFixtures (with distortion): a 21×11 grid of points
    // → direction → project ≤ 1e-6 normalized
@Test func panoramaEdgesAndSeam()              // directions 0.5° inside each edge map inside 0…1; points at u 0.4999 and 0.5001 map to directions
    // ≤ 0.05° apart when both halves' corrections are equal, and to the halves' own offsets when they differ
@Test func brownDistortionMatchesReference()   // k1 −0.25, k2 0.08: r = 0.8 → r_d = 0.8·(1 − 0.25·0.64 + 0.08·0.4096) ± 1e-12; inverse within 1e-9
@Test func initialModelFollowsTheCard()        // 4256×1888, facing 0, tilt 20 → panorama 180°×79.85°, centre direction (0, 20); 1920×1080 → rectilinear
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "SkyGeometryTests|SkyCameraModelTests"`. Expected: FAIL (types missing).
- [ ] **Step 3: Implement** the code as in Interfaces. There are no Apple frameworks here: use `SIMD3<Double>` and Foundation's math functions.
- [ ] **Step 4: Run the tests.** Run the same filter on macOS, then `sh Tools/linux-test.sh test --filter "SkyGeometryTests|SkyCameraModelTests"`. Expected: PASS on both.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: geometry, the Sun and nights, the camera model with lens distortion"`

---

### Task 2: Aim fitting: robust, staged, distortion freed gradually

**Files:**
- Create:
  - `S/SkyAim.swift`
  - `S/AimFitter.swift`
  - `S/SkyAimStore.swift`
- Test: `K/Tests/BridgeEngineTests/SkyAimFitterTests.swift`

**Interfaces:**
- Consumes: `SkyCameraModel`, `PixelPoint`, `SkyDirection` (Task 1).
- Produces:

```swift
public enum SkyAimQuality: String, Codable, Sendable { case rough, good, precise }
public struct SkyAimStatus: Codable, Sendable, Equatable { public var quality: SkyAimQuality; public var planes: Int; public var stars: Int; public var residualPixels: Double?; public var updated: Date? }
struct AimCorrespondence: Codable, Sendable, Equatable { enum Source: String, Codable { case plane, star }; var point: PixelPoint; var direction: SkyDirection; var source: Source; var at: Date; var object: String }   // object: hex or HR number
struct AimFit: Sendable, Equatable { var model: SkyCameraModel; var stage: Int; var quality: SkyAimQuality; var residualDegrees: Double; var residualPixels: Double; var inliers: Int; var planes: Int; var stars: Int }
enum AimFitter {
    static func fit(_ correspondences: [AimCorrespondence], starting: SkyCameraModel, pictureWidth: Int, previous: AimFit?,
                    using generator: inout some RandomNumberGenerator) -> AimFit   // the store passes SystemRandomNumberGenerator; tests a seeded one
    static func stage(for correspondences: [AimCorrespondence], lens: SkyCameraModel.Lens) -> Int
    static func matchTolerance(_ quality: SkyAimQuality) -> Double   // degrees: rough 15, good 1.5, precise 0.75
}
actor SkyAimStore {   // <data>/sky/<camera-uuid>/aim.json and matches.jsonl
    init(directory: URL, log: Log)
    func current() -> AimFit?
    func add(_ correspondences: [AimCorrespondence]) async -> AimFit?   // refits at most once per 10 new matches or per hour; returns a new fit when one was accepted
    func reset(reason: String)
}
```

**Stages.** These values are pinned. The counts for each half and each cell are of inlier correspondences.
- **Stage 0:** the card's model, quality `rough`.
- **Stage 1:** at least 8 correspondences from at least 5 objects. Frees yaw, pitch, roll and the field of view (hFOV and vFOV for a panorama, the focal length for rectilinear). For a panorama, `verticalMapping` is chosen by the lower residual.
- **Stage 2:** at least 40 correspondences.
  - Panorama, with at least 10 in each half: adds each half's constant and linear terms (1, s, t).
  - Rectilinear, with at least 10 in each quadrant: adds k1.
- **Stage 3:** at least 150 correspondences.
  - Panorama, covering at least 6 of the 8 cells of a 4×2 grid in each half: adds each half's quadratic terms.
  - Rectilinear, covering at least 6 of 9 cells on a 3×3 grid: adds k2.
- **Stage 4:** rectilinear only, at least 300 correspondences: adds k3.

**Fit.**
- Start with RANSAC: 200 samples of 3 correspondences, solving rotation only. An inlier is within `matchTolerance(previous?.quality ?? .rough)`.
- Then Levenberg–Marquardt, at most 50 iterations, over the freed parameters, on the reprojection error in original pixels. Use Huber weights with δ = 3 px.
- The ridge prior: each half-correction coefficient has σ = 0.02 normalized; k1 has σ 0.1, k2 σ 0.05 and k3 σ 0.02.
- **Acceptance.** A fit is accepted only when all three hold; otherwise the previous fit is kept, logged once:
  - at least 60 % of the correspondences are inliers;
  - its inlier RMS is at most 1.1 × the previous model's RMS on the same data;
  - no correction moves any point of a 9×5 check grid more than 3 % of the width away from the base projection.

**Quality.**
- `good`: stage 1 or more, RMS ≤ 0.8°.
- `precise`: at least 25 star correspondences in the fit, RMS ≤ 0.15°.

**Storage.**
- Keep the latest 2,000 correspondences of each source. Drop plane correspondences older than 30 days.
- **A moved camera:** 10 consecutive new plane matches each above 3 × the fit's RMS → `reset(reason:)`. The quality drops to rough, the correspondences are cleared, and the card says "The camera seems to have moved; aiming again."

- [ ] **Step 1: Write the failing tests.** Use synthetic data only. `SkyFixtures.truthPanorama` is yaw 352, pitch 24, roll 1.5, hFOV 178, `.tangent`, with each half's corrections up to ±1.5 %. `SkyFixtures.truthRectilinear` has k1 −0.25 and k2 0.08. Plane tracks are straight great-circle paths; stars are random directions above 5° elevation; both get 0.15° of noise.

```swift
@Test func recoversAimFromSyntheticPlaneTracks()     // 12 tracks × 6 samples from truthPanorama, starting from initial(facing: 0, tilt: 20):
    // stage 1; yaw/pitch/roll within 0.3°, hFOV within 1°; quality good
@Test func recoversDistortionFromSyntheticStars()    // 300 star points: stage 3; RMS ≤ 1.5 px at width 4256; quality precise
@Test func edgeOfFrameIsAccurate()                   // after that fit, points with x < 0.05, x > 0.95, y < 0.05 or y > 0.95 reproject ≤ 3 px
@Test func theStitchSeamIsAccurate()                 // points with 0.48 < x < 0.52 on both sides reproject ≤ 3 px; the halves' constants differ as in the truth
@Test func rectilinearBrownIsRecovered()             // truthRectilinear, 320 stars: k1, k2 within 0.02; corners ≤ 2 px
@Test func fewMatchesFreeFewTerms()                  // 6 correspondences → stage 0 (model unchanged); 9 from 5 planes → stage 1 with radial empty and halves empty
@Test func mismatchesDoNotSkewTheFit()               // recoversAimFromSyntheticPlaneTracks with 30 % of the samples replaced by random directions: same bounds
@Test func aWildFitIsRejected()                      // 60 correspondences all in one quarter of the picture → stage stays 1 (coverage gate)
@Test func residualIsReportedInOriginalPixels()      // residualPixels == residualDegrees / degreesPerPixel at the picture's centre ± 5 %
@Test func aMovedCameraStartsAimingAgain()           // store with a good fit; 10 plane matches 5° off → quality rough, correspondences empty
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter SkyAimFitterTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces. Solve the normal equations with a small dense Cholesky in Swift (at most 29 parameters). The tests pass a seeded generator, so they are repeatable.
- [ ] **Step 4: Run the tests.** Run `swift test --filter SkyAimFitterTests` and `sh Tools/linux-test.sh test --filter SkyAimFitterTests`. Expected: PASS. Each test should take under 10 s in debug.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: robust aim fitting with distortion freed as matches accumulate"`

---

### Task 3: Finding and following lights (analyzer, tracker, measures, visibility)

**Files:**
- Create:
  - `S/SkyFrameAnalyzer.swift`
  - `S/SkyTracker.swift`
  - `S/TrackMeasurer.swift`
  - `S/SkyVisibility.swift`
- Test:
  - `K/Tests/BridgeEngineTests/SkyDetectionTests.swift`
  - `K/Tests/BridgeEngineTests/SkyTrackMathTests.swift`

**Interfaces:**
- Consumes: `GrayImage` (MediaCore), `SkyCameraModel`, `SkyMath`, `SunEphemeris` (Task 1).
- Produces:

```swift
struct SkyDetection: Sendable, Equatable { var x: Double; var y: Double; var area: Int; var flux: Double; var peak: Double; var elongation: Double; var orientation: Double; var sharpness: Double; var brighter: Bool }   // analysis pixels
struct SkyMask: Sendable, Equatable { struct Circle: Sendable, Equatable { var center: PixelPoint; var radius: Double }   // radius normalized
    var groundPercent: Int; var belowElevation: Double?; var excluded: [Circle]; var model: SkyCameraModel? }
struct SkyFrameResult: Sendable { var detections: [SkyDetection]; var globalChange: Bool; var noisy: Bool }
final class SkyFrameAnalyzer {   // owned by one detector actor; not Sendable
    init(width: Int, height: Int)
    func process(_ image: GrayImage, mask: SkyMask, isNight: Bool) -> SkyFrameResult
    var background: GrayImage { get }
}
struct SkyTrackSample: Codable, Sendable, Equatable { var time: TimeInterval; var wallClock: Date; var point: PixelPoint; var area: Int; var flux: Double; var sharpness: Double; var elongation: Double }
struct SkyTrack: Sendable, Identifiable { var id: UUID; var samples: [SkyTrackSample]; var streakBorn: Bool }
final class SkyTracker {
    init(width: Int, height: Int)
    func update(_ detections: [SkyDetection], at time: TimeInterval, wallClock: Date) -> [SkyTrack]   // the tracks that ended
    func endAll() -> [SkyTrack]                                                                      // a gap: what was open, ended
    var activeCount: Int { get }
}
public enum SkyPathShape: String, Codable, Sendable { case straight, curved, suddenStop, sharpTurn }
public struct SkyMeasures: Codable, Sendable, Equatable {
    public var azimuth, elevation, azimuthEnd, elevationEnd: Double
    public var duration: Double; public var speed: Double; public var acceleration: Double     // s, °/s, °/s²
    public var turnRate: Double; public var maxTurn: Double; public var straightness: Double; public var shape: SkyPathShape
    public var sizeDegrees: Double; public var brightness: Double; public var blinks: Bool; public var blinkRate: Double?; public var focus: Double
}
enum TrackMeasurer {
    static func measure(_ track: SkyTrack, model: SkyCameraModel, analysisWidth: Int, pictureWidth: Int) -> SkyMeasures
    static func isStationary(_ m: SkyMeasures) -> Bool   // speed < 0.05 °/s over ≥ 2 s
}
struct SkyVisibility: Codable, Sendable { mutating func sample(_ background: GrayImage, mask: SkyMask, at: Date, isNight: Bool) -> Double?   // visible fraction, nil = unknown
}
```

**Values (pinned):**
- **The background.** A running mean with α = 0.05 per analysed picture.
- **The threshold** is max(8, 4σ). σ is a robust noise estimate (MAD × 1.4826) per 64×64 tile, refreshed every 25 pictures. At night only pixels brighter than the background count; by day, darker ones count too (birds against a bright sky).
- **Blobs.** 8-connected, with an area of 1…5000 px. More than 200 blobs in a picture → `noisy`, and the picture yields no detections.
- **Whole-picture change.** More than 20 % of the unmasked pixels over the threshold → `globalChange`. The background is reset and no detections come for 2 s.
- **Masks.**
  - the bottom `groundPercent` % of the rows;
  - every pixel below elevation 1°, once `model` is given and the aim is good (the caller decides);
  - the `excluded` circles: the Sun within 15° while it is above −6°, and later the Moon, stars and planets (Task 10).
- **Tracker.**
  - Prediction is alpha-beta (α 0.85, β 0.005).
  - The gate is max(6 px, 0.6 × the predicted displacement).
  - A track is born after 3 detections in consecutive analysed pictures, or after 2 when both detections are elongated (≥ 3:1) and lie along their displacement (±15°). The second kind is `streakBorn`.
  - It coasts up to 1.5 s, and is split at 10 min.
  - A track that ends after less than 0.6 s is dropped, unless it was streak-born.
  - At most 50 tracks are open.
- **Measures.**
  - Directions come through the model.
  - `speed` is the path length divided by the duration. `acceleration` is the regression slope of speed over time.
  - `turnRate` is the total absolute heading change per degree travelled. `maxTurn` is the largest heading change within any 1 s.
  - `straightness` is the chord divided by the path length.
  - `shape`:
    - `sharpTurn` when maxTurn ≥ 60° within ≤ 1 s, at ≥ 0.2°/s;
    - `suddenStop` when the speed falls from ≥ 0.5°/s to ≤ 10 % within ≤ 0.6 s and the object then stays for ≥ 1 s;
    - `straight` when maxTurn < 15° and straightness ≥ 0.97;
    - otherwise `curved`.
  - `sizeDegrees` is 2√(area / π) × the local degrees per pixel. `brightness` is the median flux and `focus` the median sharpness.
  - `blinks` is set when there are at least 3 dips below 30 % of the median flux. `blinkRate` is dips per second; at 5 pictures a second it is measured only up to 2.5 Hz.
- **Visibility** at night (Sun below −6°), once a minute:
  - count the local maxima of at least 5σ in each cell of an 8×4 grid over the unmasked sky;
  - each cell keeps the 90th percentile of its own counts on past nights;
  - a cell is visible at 30 % or more of that percentile;
  - the result is unknown until there have been 3 nights, and unknown by day (Task 15 adds weather).

- [ ] **Step 1: Write the failing tests.** Use synthetic frames: 640×284 noise (σ 3, seeded), dots drawn as 3×3 Gaussians, and 1-px static "stars".

```swift
@Test func aMovingDotIsDetectedAndTracked()          // a dot at 12 px/frame for 25 frames at 5 fps → one ended track of 25 ± 1 samples
@Test func staticStarsAreNotDetected()               // 40 static 1-px points: no detections after 40 frames (background settled)
@Test func aWholePictureChangeResetsWithoutTracks()   // luma +40 at frame 30 (the IR switch): globalChange once, no detections for 10 frames,
    // no track born across it; also a −40 step
@Test func theGroundMaskHidesTheBottom()             // a dot moving in the bottom 12 % → no detections
@Test func crossingObjectsKeepTheirIdentities()      // two dots crossing at 20° → two tracks, each straight
@Test func aBlinkingLightIsOneTrack()                // a plane-like dot absent 1 frame in 5 → one track, blinks true, blinkRate 1.0 ± 0.15 Hz
@Test func twoAlignedStreaksStartAMeteor()           // two 1×9 streaks 120 px apart along their axis → one streakBorn track
@Test func aFloodOfBlobsIsNoisy()                    // 300 random blobs → noisy, no detections
@Test func speedAndAccelerationAreRight()            // a track at constant 1.2 °/s through truthPanorama → speed 1.2 ± 2 %, acceleration ≈ 0
@Test func shapesAreRecognised()                     // a 90° turn within 0.4 s → sharpTurn; a stop from 1 °/s that then stays 2 s → suddenStop; an arc → curved
@Test func visibilityIsUnknownUntilThreeNights()     // then a clear night → ≥ 0.6, a blank night → < 0.3
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "SkyDetectionTests|SkyTrackMathTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces. Analysis works on `[UInt8]` and `[Float]` buffers with plain loops: no allocation per pixel, and one reused buffer for each analyser.
- [ ] **Step 4: Run the tests** on macOS and Linux. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: detection, tracking and track measures"`

---

### Task 4: Flights from a network feed

**Files:**
- Create:
  - `S/SkyHTTP.swift`
  - `S/AircraftFeed.swift`
  - `S/FlightHistory.swift`
  - `S/FlightFeedFinder.swift`
  - `S/FlightMatcher.swift`
- Modify: `K/Sources/CameraAdapters/Integrations/Wyze/NeighborTable.swift` (add `ipv4s(in:)`).
- Test:
  - `K/Tests/BridgeEngineTests/SkyFlightTests.swift`
  - `SkyFixtures.swift`: `aircraftJSON` and `adsbFiJSON`, made up, with hex `a0b1c2`, call sign `TEST123` and positions within 60 km of `SkyFixtures.observer`
  - `K/Tests/CameraAdaptersTests/` (add a test for `ipv4s(in:)`)

**Interfaces:**
- Consumes: `SkyMath`, `SkyCameraModel`, `SkyTrack`, `SkyMeasures`, `AimCorrespondence`, `AimFitter.matchTolerance`.
- Produces:

```swift
protocol SkyHTTP: Sendable { func get(_ url: URL, timeout: Duration, maximumBytes: Int) async throws -> (body: Data, status: Int) }
final class URLSessionSkyHTTP: SkyHTTP   // one shared AuthenticatingHTTPClient (no credentials, certificate checks on, followsRedirects false), like URLSessionAITransport
struct AircraftReport: Sendable, Equatable { var hex: String; var callsign: String?; var latitude: Double; var longitude: Double; var altitudeMeters: Double; var altitudeFeet: Int; var positionTime: Date; var groundSpeedKnots: Double?; var trackDegrees: Double? }
enum AircraftFeedParser {
    static let maximumBytes = 4 << 20; static let maximumAircraft = 5_000; static let maximumPositionAge: TimeInterval = 30
    static func parse(_ data: Data, receivedAt: Date) -> [AircraftReport]   // `aircraft` (dump1090/readsb/tar1090) or `ac` (adsb.fi); alt_geom else alt_baro;
                                                                             // "ground", NaN, out-of-range, seen_pos > 30 skipped; positionTime = receivedAt − seen_pos
}
actor FlightHistory { init(keep: TimeInterval = 900); func add(_ reports: [AircraftReport]); func tracks(overlapping: ClosedRange<Date>) -> [String: [AircraftReport]] }
actor FlightFeedPoller { init(url: URL, http: any SkyHTTP, history: FlightHistory, interval: Duration = .seconds(1)); func start(); func stop() async; var problem: String? { get } }
enum FlightFeedFinder {
    static let paths = ["/tar1090/data/aircraft.json", "/dump1090-fa/data/aircraft.json", "/skyaware/data/aircraft.json", ":8080/data/aircraft.json"]
    static func candidates(neighbours: String) -> [URL]          // complete IPv4 entries of private ranges only, at most 64 hosts
    static func find(http: any SkyHTTP, neighbours: String) async -> [URL]   // 1.5 s each, 8 at a time; a URL counts when it parses as a feed
}
public enum SkyLabel: String, Codable, Sendable, CaseIterable { case unexplained, plane, probablePlane, satellite, satelliteFlare, meteor, bug, bird }
struct FlightMatch: Sendable, Equatable { var hex: String; var detail: String; var score: Double; var label: SkyLabel; var correspondences: [AimCorrespondence] }
enum FlightMatcher {
    static func match(_ track: SkyTrack, measures: SkyMeasures, model: SkyCameraModel, aim: SkyAimQuality, observer: SkyObserver,
                      flights: [String: [AircraftReport]]) -> FlightMatch?
    static func detail(_ report: AircraftReport) -> String   // "TEST123 · 35,000 ft" (call sign trimmed, else the hex upper-cased; feet rounded to 100)
}
```
Also `NeighborTable.ipv4s(in table: String) -> [String]`: the complete entries.

**Matching rule.**
- **Prediction.** Each aircraft's position at each sample's `wallClock` is interpolated linearly in its history. Up to 5 s beyond the history it is extrapolated from the ground speed and track.
- **The score.** The median angular distance between the track's directions (through `model`) and the aircraft's. It matches when the score is within the tolerance for the aim, and the heading of motion agrees within 30° (for tracks of at least 1 s).
- **While the aim is rough** (tolerance 15°), it must also be the only aircraft within 15°, and its predicted angular speed must be within ±50 % of the track's.
- **The label** is `.probablePlane` while the aim is rough, else `.plane`.
- **Correspondences.** Each matched sample yields one: the track's pixel and the aircraft's direction.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func parsesBothFeedShapes()                    // aircraftJSON → 3 reports (one "ground", one seen_pos 45 s skipped); adsbFiJSON → same hex, same altitude
@Test func hostileFeedIsBounded()                    // 5 MiB body → []; 10,000 aircraft → 5,000; strings for numbers, NaN, lat 400 → skipped; never traps
@Test func aFeedWithAWrongClockStillMatches()        // feed `now` = receivedAt + 300 s: positionTime still receivedAt − seen_pos; the synthetic track matches
@Test func aSyntheticPlaneTrackMatches()             // the fixture aircraft's path projected through truthPanorama (+0.1° noise) → .plane, detail "TEST123 · 35,000 ft"
@Test func roughAimMatchesLooselyAndOnlyWhenUnique()  // initial model 8° off: matches as .probablePlane; with a second aircraft 6° away → nil
@Test func aPlaneGoingTheOtherWayDoesNotMatch()      // same positions reversed in time → nil
@Test func toleranceTightensWithTheAim()             // a track 3° off: matches at rough, not at good
@Test func findsFeedsOnTheNeighbours()               // /proc/net/arp text with 192.168.77.20 (complete), 192.168.77.21 (flags 0x0), 8.8.8.8 → candidates only for .20;
    // a fake SkyHTTP answering aircraftJSON at http://192.168.77.20/tar1090/data/aircraft.json → that one URL
@Test func thePollerStopsWhenToldAndReportsProblems()   // 404 → problem "The flight feed answered 404."; stop() → no request after
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter SkyFlightTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces. The parser uses `JSONSerialization` with tolerant reads of each field (number or numeric string), never `Decodable`, so one odd field never drops a whole feed.
- [ ] **Step 4: Run the tests.** Run `swift test --filter "SkyFlightTests|NeighborTable"` and the Linux run. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: flights from a network feed, the feed finder and plane matching"`

---

### Task 5: Settings, the sky log store and its API

**Files:**
- Create:
  - `S/SkySettings.swift`
  - `S/SkyEntry.swift`
  - `S/SkyLogStore.swift`
  - `K/Sources/BridgeEngine/BridgeEngine+Sky.swift`
  - `K/Sources/BridgeWeb/WebApp+Sky.swift`
- Modify:
  - `K/Sources/BridgeEngine/Configuration/Configuration.swift`:
    - `BridgeSettings.sky`;
    - `CameraConfiguration.skyDetector`, with CodingKeys and a lenient decode like `aiDescriptions`.
  - `K/Sources/BridgeEngine/BridgeEngine.swift`:
    - `needsRestart` ignores `skyDetector`;
    - `validate`;
    - `updateCamera` carries the engine-owned fields forward.
  - `K/Sources/BridgeEngine/NVR/ArchiveEventLog.swift`: `pruneEvents` also prunes `.sky`.
  - `K/Sources/BridgeEngine/DiagnosticsReport.swift`: "sky detector on for N cameras", with no location.
  - `K/Sources/BridgeWeb/WebApp+Routes.swift`: `CameraPatch.skyDetector` and the route table `+ skyRoutes`.
  - `K/Sources/BridgeWeb/WebApp+Bridge.swift`: `SettingsPatch.sky`.
  - `K/Sources/BridgeWeb/Resources.swift`: `SettingsResource.sky`.
  - `K/Sources/BridgeWeb/BridgeBackend.swift`: new requirements with defaults.
  - The forwarders: `K/Sources/BridgeDaemon/NoArchiveBackend.swift`, `Daemon.swift` (`DemoDiscoveryBackend`) and `K/Tests/BridgeWebTests/Support.swift`.
  - `docs/CONTRACT_CHANGES.md` and the READMEs.
- Test:
  - `K/Tests/BridgeEngineTests/SkyLogStoreTests.swift`
  - `K/Tests/BridgeEngineTests/SkySettingsTests.swift`
  - `K/Tests/BridgeWebTests/SkyAPITests.swift`

**Interfaces:**
- Consumes:
  - `SkyLabel`, `SkyMeasures`, `SkyAimStatus`, `PixelPoint` and `SkyNight` (Tasks 1–4);
  - `ArchiveEventLog`'s day-file conventions.
- Produces (public unless marked):

```swift
public struct SkyLocation: Codable, Sendable, Equatable { public var latitude: Double; public var longitude: Double; public var heightMeters: Double }   // lat −90…90, lon −180…180, not (0, 0)
public struct SkySettings: Codable, Sendable, Equatable { public var location: SkyLocation?; public var flightFeedURL: String?; public var aiDailyLimit: Int   // 50, 1…1000
    public struct Problem: Equatable, Sendable { public var field: String; public var message: String }
    public var validationProblem: Problem? }   // feed: http(s) with a host
public struct SkyDetectorSettings: Codable, Sendable, Equatable { public var enabled: Bool; public var facing: Double; public var tilt: Double; public var groundPercent: Int; public var nightProfile: Bool }
    // defaults false, 0 (north), 20, 12, true; facing 0..<360, tilt 0…90, groundPercent 0…60
// BridgeSettings.sky: SkySettings; CameraConfiguration.skyDetector: SkyDetectorSettings?
public enum SkyEntryKind: String, Codable, Sendable { case track, newLight, flash }
public enum SkyLabelSource: String, Codable, Sendable { case flight, orbit, rule, model, ai, person }
public enum SkyCorrection: String, Codable, Sendable, CaseIterable { case plane, bird, bug, satellite, meteor, notSure }
public enum SkyUnusualReason: String, Codable, Sendable { case faster, larger, brighter, suddenStop, sharpTurn }
public struct SkyPathPoint: Codable, Sendable, Equatable { public var t: Double; public var x: Double; public var y: Double }   // s from start; ORIGINAL picture 0…1; at most 64
public struct SkyAIAnswer: Codable, Sendable, Equatable { public var kind: String; public var sentence: String; public var model: String; public var at: Date }   // kind: a SkyAIKind raw value (Task 12); stored and shown from now
public struct SkyEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String; public var camera: UUID; public var kind: SkyEntryKind; public var start: Date; public var end: Date
    public var path: [SkyPathPoint]; public var measures: SkyMeasures
    public var label: SkyLabel; public var by: SkyLabelSource?; public var detail: String?
    public var unusual: [SkyUnusualReason]; public var speedVsPlanes: Double?
    public var candidate: Bool; public var alerted: Bool; public var hasStill: Bool
    public var ai: SkyAIAnswer?; public var correction: SkyCorrection?
}
public enum SkyConditionState: String, Codable, Sendable { case clear, cloudy, notVisible, unknown }
public struct SkyConditions: Codable, Sendable, Equatable { public var from: Date; public var to: Date; public var state: SkyConditionState; public var cloudCover: Int? }
public struct SkyCounts: Codable, Sendable, Equatable { public var unexplained, planes, satellites, meteors, bugsAndBirds, notSure: Int; public var explained: Int }
public struct SkyLearning: Codable, Sendable, Equatable { public var ready: Bool; public var planes: Int; public var satellites: Int; public static let planesNeeded = 30; public static let satellitesNeeded = 10 }
public struct SkyNightLog: Sendable, Equatable { public var camera: UUID; public var night: String; public var view: SkyLogView; public var from: Date; public var to: Date
    public var entries: [SkyEntry]; public var conditions: [SkyConditions]; public var counts: SkyCounts; public var aim: SkyAimStatus; public var learning: SkyLearning }
final class SkyLogStore: Sendable {   // internal; one serial queue like ArchiveEventLog
    static let directoryName = ".sky"
    func record(_ entry: SkyEntry, night: String, folder: URL?)
    func recordCorrection(_ c: SkyCorrection, entryID: String, camera: UUID, night: String, folder: URL?, at: Date)
    func recordAI(_ answer: SkyAIAnswer, entryID: String, camera: UUID, night: String, folder: URL?)
    func recordAlert(entryID: String, camera: UUID, night: String, folder: URL?)
    func recordConditions(_ c: SkyConditions, camera: UUID, night: String, folder: URL?)
    func writeStill(_ jpeg: Data, entryID: String, camera: UUID, night: String, folder: URL?)
    func read(camera: UUID, night: String, folder: URL) -> (entries: [SkyEntry], conditions: [SkyConditions])   // later lines of an id applied in order
    func still(camera: UUID, night: String, entryID: String, folder: URL) -> Data?
    static func prune(folder: URL, cutoffMs: Int64, remove: (URL) throws -> Void) -> Int
}
// BridgeEngine (public): skyNightLog(cameraID:night:view:) async throws -> SkyNightLog   (night nil: the latest)
//   correctSkyEntry(cameraID:entryID:night:label:) async throws -> SkyEntry ; skyStill(cameraID:night:entryID:) async throws -> Data
//   findFlightFeeds() async -> [URL]
public struct SkyDisplay: Sendable { public static func label(_ entry: SkyEntry) -> SkyLabel }    // correction wins: plane→.plane, bird→.bird, bug→.bug,
                                                                                                  // satellite→.satellite, meteor→.meteor, notSure → the entry's own label
```

**Layout.**
- The log is `<recordings>/.sky/<CAMERA-UUID>/<night>.jsonl`, mode 0600 in folders of 0700, written append-only.
- The lines:
  - `{"v":1,"entry":{…}}`
  - `{"v":1,"id":…,"correction":{"label","at"}}`
  - `{"v":1,"id":…,"ai":{…}}`
  - `{"v":1,"id":…,"alerted":true}`
  - `{"v":1,"conditions":{…}}`
- Stills go in `<recordings>/.sky/<CAMERA-UUID>/<night>/<id>.jpg`.
- A torn last line is skipped. No reads or writes follow a link. Pruning removes nights before the events' cutoff.

**Routes** (for a signed-in session):
- `GET sky/cameras/:id/night?date=yyyy-MM-dd&view=night|day` → `{camera, night, view, from, to, serverTime, entries, conditions, counts, aim, learning}`.
  - Times are epoch ms. Optional fields are `OrNull`.
  - Each entry carries `display` (`SkyDisplay.label`) and `watch` (the recordings' ms to open, the start − 3 s).
- `GET sky/cameras/:id/entries/:eid/still?night=…` → `image/jpeg`, or 404.
- `POST sky/cameras/:id/entries/:eid/correction {night, label}` → the entry, or 400 for an unknown label.
- `POST sky/feeds/find` → `{feeds: [url]}`.
- `PATCH settings {sky: {location: {latitude, longitude} | null, flightFeedURL, aiDailyLimit}}`.
- `GET settings` carries `sky`. The location is shown to the signed-in page only.
- `PATCH cameras/:id {skyDetector: {enabled, facing, tilt, groundPercent, nightProfile}}`.
  - Enabling needs a location and a recordings folder. Without them: 400 with `field` and the sentences "Set where the box is first." and "Choose a recordings folder first: the sky log is kept with the recordings."
  - A camera that streams only on demand gets 400 "Battery cameras can’t watch the sky: it would keep them awake."

- [ ] **Step 1: Write the failing tests**

```swift
@Test func settingsDecodeLenientlyAndValidate()      // missing sky → defaults; lat 91 → problem field "sky.location"; (0,0) → problem; feed "ftp://x" → problem
@Test func cameraSkySettingsDoNotRestartTheCamera()  // needsRestart(old, new with skyDetector changed) == false
@Test func aNightIsOneFileAcrossMidnight()           // entries at 21:00 and 02:00 local (Chicago) → one file named for the evening's date
@Test func laterLinesApplyToTheirEntry()             // entry, correction bird, ai, alerted → read gives correction .bird, ai, alerted true; SkyDisplay.label == .bird
@Test func aTornLineIsSkipped()                      // truncate the last line → the other entries read
@Test func pruningFollowsTheEventsCutoff()           // nights older than nvrKeepDays deleted with their stills; newer kept
@Test func theLocationNeverReachesDiagnosticsOrLogs()  // location 40.0000/−100.0000: the diagnostics report and every collected log line contain neither "40.0" nor "-100.0"
@Test func nightRouteAnswersTheLog() async throws    // (BridgeWebTests) fake backend log → JSON with counts, entries[].display, serverTime
@Test func correctionRouteWritesAndAnswers() async throws   // POST label "bird" → entry.correction "bird"; label "ufo" → 400
@Test func enablingNeedsALocationAndAFolder() async throws  // PATCH cameras/:id skyDetector.enabled true → 400 with the exact sentences; with both set → 200
@Test func stillRouteServesJPEGOrNotFound() async throws
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "SkyLogStoreTests|SkySettingsTests|SkyAPITests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces and Layout. Also add a CONTRACT_CHANGES row for the public types with the Status **additive**, the BridgeEngine README section "Additions beyond the contract: the sky detector", and the routes in the BridgeWeb README.
- [ ] **Step 4: Run the tests.** Run the same filter, then `swift test --filter "BridgeEngineTests|BridgeWebTests|DocsConsistencyTests"` once, and the Linux run of the filter. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: settings, the sky log beside the recordings, and its API"`

---

### Task 6: The sky picture stream (sky decoder, stream choice, monitor)

**Files:**
- Create:
  - `K/Sources/BridgeEngine/Runtime/SkyStream.swift`
  - `K/Sources/BridgeEngine/Runtime/SkyMonitor.swift`
- Modify:
  - `K/Sources/MediaCore/Codecs.swift`: a new requirement with a default.
  - `K/Sources/PlatformLinux/Codecs/FFmpegMediaCodecs.swift`, `FFmpegVideoDecoder.swift` and `FFmpegArguments.swift`.
  - `K/Sources/BridgeEngine/Runtime/CameraRuntime.swift`: the sky hookup, following the motion shadow test's sub-stream pattern.
  - `docs/CONTRACT_CHANGES.md` and the MediaCore README.
- Test:
  - `K/Tests/PlatformLinuxCodecsTests/SkyDecoderTests.swift`
  - `K/Tests/BridgeEngineTests/RuntimeSkyTests.swift`

**Interfaces:**
- Consumes: `MediaHub`, `StreamSources`, `VideoResolution`, `SnapshotDecoderPool`.
- Produces:

```swift
// MediaCore.MediaCodecs (public, additive; default → makeMotionDecoder(format:))
func makeSkyDecoder(format: VideoFormat, maxOutputWidth: Int, keepEvery: Int) throws -> any VideoDecoding
// PlatformLinux: FFmpegVideoDecoder.init(…, maxOutputWidth:, hardwareWhenHeavy: true, keepEvery: Int = 1);
//   FFmpegArguments.decoder(width:height:hardwareDevice:keepEvery:) adds select='not(mod(n\,N))' before hwdownload (GPU) or before the output (CPU);
//   decode(_:) returns nil at once for a frame whose picture is not kept, and pairs each kept picture with every Nth pts (pending sorted)
struct SkyStreamChoice: Sendable, Equatable {
    enum Stream: String, Sendable, Codable { case sub, main }
    var stream: Stream; var analysisWidth: Int; var keepEvery: Int
    static let minimumSubWidth = 1280; static let maximumAnalysisWidth = 1920; static let analysisRate = 5.0
    static func choose(sub: VideoResolution?, subFrameRate: Double?, main: VideoResolution?, mainFrameRate: Double?) -> SkyStreamChoice?   // nil: no picture yet
}
struct SkyFrame: Sendable { var image: GrayImage; var time: TimeInterval; var wallClock: Date }   // time: from the stream's pts; wallClock: the encoded frame's
protocol SkyFrameSink: Sendable { func frame(_ frame: SkyFrame) async; func gap(at: Date, reason: String) async }
actor SkyMonitor { init(hub: MediaHub, codecs: any MediaCodecs, choice: SkyStreamChoice, sink: any SkyFrameSink, log: Log); func start(); func stop() async; private(set) var analysed: Int }
// CameraRuntime
func startSky(sink: any SkyFrameSink) async -> Bool     // false: on-demand camera, or not running
func stopSky() async
var skyStream: SkyStreamChoice? { get }
func skyStill(around date: Date) async -> (jpeg: Data, at: Date)?   // the main hub's keyframe nearest `date` (ring), JPEG of the ORIGINAL picture, quality 0.8
```

**Rules.**
- `keepEvery` is max(1, round(stream fps / 5)).
- The monitor:
  - analyses at most 5 pictures a second, through `grayThumbnail(maxWidth: analysisWidth)`;
  - maps each decoded picture's pts to the wall clock of its encoded frame;
  - reports `gap` after 5 s without a picture, on a pts discontinuity, or when the format changes.
- When the format changes, the runtime chooses again, and the new decoder starts at the next keyframe.
- The runtime holds one sub-stream user while the sky uses the sub stream (`acquireSub` and `releaseSub`). The main stream always runs.
- Nothing here applies `PictureCorrection`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func skyDecoderArgumentsKeepEveryNth()          // (PlatformLinuxCodecsTests) decoder(width: 1920, height: 852, hardwareDevice: "/dev/dri/renderD128",
    // keepEvery: 4): the filter chain scales on the GPU, then a select filter keeping every 4th picture (not(mod(n\,4))), then hwdownload;
    // keepEvery 1 → no select filter
@Test func keptPicturesPairWithEveryNthPTS()         // fake ffmpeg (FakeFFmpeg) emitting 1 picture per 4 frames: decode() nil ×3 then a picture with the 4th
    // pts; no 400 ms waits for dropped frames (12 frames < 200 ms)
@Test func choosesSubOrMain()                         // sub 1280×720 → .sub width 1280; sub 704×312 + main 4256×1888 @20 → .main width 1920, keepEvery 4; no sub → main
@Test func framesReachTheSinkAtFivePerSecond() async  // demo hub at 20 fps for 3 s → 15 ± 2 frames, wallClock rising, times from pts
@Test func aFormatChangeChoosesTheStreamAgain() async  // main stream 4256×1888 → 2560×1440 mid-run: one gap, then frames at the new choice
@Test func theSubStreamIsHeldAndReleased() async      // .sub choice: subUsers +1 while running; stopSky() → released (idle stop scheduled)
@Test func onDemandCamerasCannotWatchTheSky() async   // driver streamsOnDemand → startSky false
@Test func theSkySeesTheOriginalPicture() async       // pictureCorrection on: codecs record that makeSkyDecoder was used and no transcoder with a correction was made for it
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "SkyDecoderTests|RuntimeSkyTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces and Rules. Add a CONTRACT_CHANGES row for `MediaCodecs.makeSkyDecoder(format:maxOutputWidth:keepEvery:)` (additive: a requirement with a default).
- [ ] **Step 4: Run the tests** on macOS and Linux. Also run `swift test --filter "RuntimeSoftMotionTests|RuntimeMotionShadowTests|VideoDecoderEncoderTests"`: soft motion and the shadow test must be unchanged. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: the sky decoder, the stream choice and the picture monitor"`

---

### Task 7: The detector at work (per-camera pipeline, the service, stills, status)

**Files:**
- Create:
  - `S/SkyCameraDetector.swift`
  - `S/SkyService.swift`
- Modify:
  - `K/Sources/BridgeEngine/BridgeEngine+Sky.swift`: start and stop with the bridge and with each camera's switch, the settings changes, the status.
  - `K/Sources/BridgeEngine/EngineStatus.swift`: `CameraStatus.sky`.
  - `K/Sources/BridgeWeb/Resources.swift`: `status.sky`.
  - The docs.
- Test:
  - `K/Tests/BridgeEngineTests/SkyDetectorTests.swift`
  - `K/Tests/BridgeEngineTests/SkyServiceTests.swift`

**Interfaces:**
- Consumes everything above.
- Produces:

```swift
public struct SkyCameraStatus: Sendable, Equatable { public var running: Bool; public var stream: String?; public var analysisWidth: Int?; public var picturesPerSecond: Double?
    public var aim: SkyAimStatus; public var learning: SkyLearning; public var problem: String?; public var profile: String? }   // profile set by Task 14
// CameraStatus.sky: SkyCameraStatus? (nil: detector off)
actor SkyCameraDetector: SkyFrameSink {
    struct Context: Sendable { var cameraID: UUID; var cameraName: String; var settings: SkyDetectorSettings; var observer: SkyObserver; var zone: TimeZone
        var pictureWidth: Int; var folder: () -> URL?; var still: @Sendable (Date) async -> (jpeg: Data, at: Date)? }
    init(context: Context, aim: SkyAimStore, flights: FlightHistory, log: SkyLogStore, now: @escaping @Sendable () -> Date)
    func frame(_ frame: SkyFrame) async ; func gap(at: Date, reason: String) async
    func update(_ settings: SkyDetectorSettings) ; var status: SkyCameraStatus { get }
    /// The classification pipeline of an ended track. Phase 1: flight; later tasks insert orbit, rules, model, AI in this order.
    func classify(_ track: SkyTrack, measures: SkyMeasures) async -> SkyEntry
}
actor SkyService {
    init(dataDirectory: URL, http: any SkyHTTP, logStore: SkyLogStore, now: @escaping @Sendable () -> Date)
    func update(settings: SkySettings, cameras: [UUID: SkyCameraDetector.Context]) async   // starts/stops pollers: none while no camera is on
    func detector(_ cameraID: UUID) -> SkyCameraDetector?
}
```

**Pipeline** (for each analysed picture):
- Build the mask: ground, below 1° once the aim is good, the Sun.
- Run the analyzer, then the tracker. On `globalChange`, call `tracker.endAll()` and drop what it returns.
- For each ended track:
  - drop it when it is stationary (Task 10 routes these to the point-light watch);
  - otherwise measure it and run `FlightMatcher`.
- **A match:** the entry is labelled from the match. Its correspondences go to `SkyAimStore.add`.
- **No match:** the entry is `.unexplained`. It gets a still from `context.still(middle)`, written with `writeStill`.
- The entry's path is at most 64 points, evenly picked from the samples.
- Write it to the log with `SkyNight.name(containing: start)`.
- **Conditions.** Each minute, record the visibility as a `SkyConditions` span: clear at 0.6 or more, notVisible below 0.3, cloudy in between, unknown when it is nil. A span is recorded only when the state changes, or once an hour.

**Lifecycle.** The service polls the configured feed only while at least one detector is on. Turning the last one off stops every poller, and the engine's settings changes update the service.

- [ ] **Step 1: Write the failing tests.** A fake frame source plays synthetic frames: a dot along the fixture aircraft's projected path, plus a second dot with no aircraft. A fake `SkyHTTP` serves `aircraftJSON`.

```swift
@Test func aMatchedPlaneIsLoggedAsAPlane() async     // entry label .plane (or .probablePlane while rough), by .flight, detail "TEST123 · 35,000 ft"
@Test func anUnmatchedTrackIsUnexplainedWithAStill() async   // label .unexplained, hasStill true, the still file exists
@Test func matchesImproveTheAim() async              // 12 synthetic planes → SkyAimStore quality good; status.aim.planes == 12
@Test func aGapEndsOpenTracksWithoutEntries() async  // gap mid-track → no entry for that track; a gap is never a track
@Test func nothingIsFetchedWhileTheDetectorIsOff() async   // all cameras off: 0 requests in 5 s; one on: requests to the feed; off again: none after
@Test func statusSaysWhichStreamAndHowFast() async   // status.stream "main", analysisWidth 1920, picturesPerSecond ≈ 5
@Test func conditionsAreRecordedOnChange() async     // visibility 0.8 → 0.1 → 0.8 over 3 h → spans clear, notVisible, clear
@Test func theEngineStartsAndStopsItWithTheSwitch() async   // updateCamera(skyDetector.enabled true) → runtime.startSky called, status.sky non-nil; false → stopSky
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "SkyDetectorTests|SkyServiceTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces, Pipeline and Lifecycle. The aim of each camera persists in `<data>/sky/<camera-uuid>/`. It is removed with the camera (`removeCamera`), and kept when the detector is turned off.
- [ ] **Step 4: Run the tests.** Run the same filter, then `swift test --filter "BridgeEngineTests"` once, and the Linux run. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: the per-camera pipeline, the service and the camera's sky status"`

---

### Task 8: The page: the Sky detector card, the morning sky log, corrections

**Files:**
- Create:
  - `W/js/screens/sky-model.js` (pure)
  - `W/js/screens/sky-card.js`
  - `W/js/screens/sky-log.js`
  - `W/sky.css`, linked from `W/index.html` like the `nvr-*.css` files
  - `linux/web-dev/lib/sky.mjs`: a fake night for one fake camera, with the fixture-style data from Task 5's routes
- Modify:
  - `W/js/app.js`: the route, plus the menu item **Sky** (icon `moon`), hidden while no camera has `skyDetector.enabled`.
  - `W/js/screens/camera.js`: the card in the right column after the AI card.
  - `W/js/screens/settings.js`: the location and the flight feed with **Find a feed**.
  - `linux/web-dev/lib/server.mjs`: the sky routes.
  - `W/README.md`.
- Test:
  - `linux/web-tests/sky-model.test.mjs`
  - `linux/web-tests/sky-card.test.mjs`
  - `linux/web-tests/sky-log.test.mjs`
  - `linux/web-tests/sky-server.test.mjs`

**Interfaces:**
- Consumes the Task 5 routes and Task 7 `status.sky`.
- Produces:

```js
// sky-model.js
export const SKY_TEXT;                                   // every sentence below
export function compassWord(azimuth)                     // 8 points: 'north', 'northeast', …
export function directionText(azimuth, elevation)        // (312, 8) → 'low in the northwest, 8° up'; (45, 30) → 'in the northeast, 30° up'; (10, 75) → 'high in the north, 75° up'
export function speedText(ratio)                         // 6.1 → 'about 6× faster across the sky than planes at that height'; 1.8 → 'about 1.8× faster …';
                                                         // 0.9 → 'about as fast across the sky as planes at that height'; 0.5 → 'slower across the sky than planes at that height'; null → ''
export function blinkText(blinks, rate)                  // 'Blinks about once a second' | 'Blinks about 2 times a second' | 'Blinks about once every 3 seconds' | 'Steady (doesn’t blink)'
export function shapeText(shape)                         // 'Straight' | 'Curved' | 'Stops suddenly' | 'Turns sharply'
export function summaryText(counts, view)                // 'Last night: 1 unexplained, 214 explained' | 'Today: …' (singular forms right)
export function conditionsText(conditions, zone)         // '☁︎ clear until 3 AM; sky not visible 3–5 AM'
export function aimText(aim)                             // 'Aim: rough' | 'Aim: good, 23 planes matched, 14 px' | 'Aim: precise, 214 stars matched, 1.8 px'
export function stripDots(entries, from, to)             // [{x 0…1 by time, y by elevation, kind, unexplained}]
export function groupExplained(entries)                  // [{label, title: 'Planes', entries}] in the order planes, satellites, meteors, bugs and birds, not sure
// sky-card.js
export function createSkyDetectorCard(camera, { save, settings = () => get('settings'), geolocate = navigator.geolocation }) // → { el, update(camera), destroy() }
// sky-log.js
export const SKY_ROUTE = /^sky(?:\/([0-9A-Fa-f-]{36}))?(?:\?(.*))?$/;
export function createSkyLogPage({ cameraID, query, load, correct, now, writeAddress })   // → { el, destroy() }
export function renderSkyLog(context)
```

**Copy (exact).**
- The card:
  - Title **Sky detector**; switch **Watch the sky**.
  - "For a camera that looks at the sky. Camera Bridge logs everything that crosses it — planes, satellites, meteors, bugs and birds — and tells you only about what it can’t explain. One camera can’t tell how far away something is, so it compares how things move across the sky; it never guesses a real size or speed."
  - "While it’s on, Camera Bridge downloads satellite orbits once a day and asks free online services for flights and weather in a wide area around you, never your exact spot. Still pictures of what it can’t explain go to your AI service if you set one up. Nothing leaves the box while it’s off."
  - The location: **Where the box is**, "Kept only on this box.", the button **Use this browser’s location**, and the fields Latitude and Longitude.
  - **Which way the camera faces**: N, NE, E, SE, S, SW, W, NW. **Tilt above the horizon**: 0–90°. **Ground and horizon at the bottom**: 0–60 %.
  - The aim: `aimText`, then "It gets more exact by itself over a few nights." While the aim is rough, also "Flight matching is loose until the aim is good."
  - The stream: "Watching the main stream at 1920 px, 5 pictures a second".
  - The link **Open the sky log**.
- The log:
  - The title "Sky log · <camera>", and the toggles **Night** and **Day**.
  - Under each entry, "That was a…" with the buttons **Plane**, **Bird**, **Bug**, **Satellite**, **Meteor** and **Not sure**. After a tap: "You said: bird. Camera Bridge learns from this."
  - The learning line: "Still learning this sky: 12 of 30 planes matched. No alerts until then."

**Layout A.**
- The summary line, the counts row and the conditions line.
- The strip: an SVG from sunset to sunrise, or across the day in the day view. One dot per entry, coloured by kind; the unexplained ones are larger and glowing.
- Then the unexplained entries, each with these:
  - the still, with the path drawn as an SVG polyline over it, in original-picture coordinates (the still is the original picture, so the path is drawn on it unstraightened);
  - **Watch** (`#/camera/<id>/watch/<ms>`) and **Download clip** (`nvr/cameras/<id>/clip?from=…&to=…`);
  - the time, `directionText`, the duration, `speedText`, `blinkText`, `shapeText`, and the AI's sentence when there is one.
- Then the explained entries, in `<details>` by group, each with its detail ("TEST123 · 35,000 ft" or "ISS (ZARYA)").
- The CSS uses tokens and no inline styles (CSP).

- [ ] **Step 1: Write the failing tests**

```js
test('direction, speed, blink, shape and summary words are exact', …)   // every example above, singular/plural ('1 unexplained, 1 explained')
test('no text ever claims a real size or speed', …)   // render a log with every entry kind → page text matches none of /km\/h|mph|metres|meters|feet tall|miles|\bkm\b/
test('conditions read as one line', …)                 // [{clear 22:00–03:00}, {notVisible 03:00–05:00}] → '☁︎ clear until 3 AM; sky not visible 3–5 AM'
test('the card needs a location and a folder, and says why', …)   // 400 sentences shown in place; switch returns to off
test('Use this browser’s location fills the fields; refusal says type it in', …)
test('the card shows the aim and the stream', …)       // status.sky aim good 23 planes 14 px → 'Aim: good, 23 planes matched, 14 px'
test('the log lists unexplained first, explained grouped and collapsed', …)
test('a correction is sent and shown in place', …)     // POST body {night, label: 'bird'}; text 'You said: bird. …'; no reload of the page
test('the path is drawn over the still in picture coordinates', …)   // path [[0,0.1,0.2],[1,0.3,0.25]] on a 400×177 still → polyline points '40,35.4 120,44.25'
test('the menu shows Sky only while a camera watches the sky', …)
test('the dev server serves a fake night', …)          // sky-server.test.mjs against linux/web-dev
```

- [ ] **Step 2: Run them to see them fail.** Run `node --test linux/web-tests/sky-*.test.mjs`. Expected: FAIL.
- [ ] **Step 3: Implement** the page as in Interfaces, Copy and Layout A, with the fake browser's conventions (`installFakeBrowser`). The card moves in place and the page is not rebuilt, like `createAIDescriptionsCard`.
- [ ] **Step 4: Run the tests.** Run `sh linux/web-tests/run.sh` and `node linux/web-dev/lint.mjs`. Expected: PASS, with no lint findings. Then look at it by hand: run `node linux/web-dev/dev-archive-server.mjs`, open `#/sky/<fake id>`, and check the phone width (375 px) has no sideways scroll.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: the camera card, the morning sky log and one-tap corrections"`

---

# Phase 2: satellites, stars and the Moon, meteor/bug/bird rules, alerts, the AI for leftovers

### Task 9: Satellites (TLE, SGP4, the daily download, orbit matching, flares)

**Files:**
- Create:
  - `S/TwoLineElements.swift`
  - `S/SGP4.swift`
  - `S/OrbitCatalog.swift`
  - `S/OrbitMatcher.swift`
- Modify:
  - `S/SkyCameraDetector.swift`: orbit matching after flights.
  - `S/SkyService.swift`: owns the `OrbitCatalog`.
- Test:
  - `K/Tests/BridgeEngineTests/SkySatelliteTests.swift`
  - `SkyFixtures.swift`: `sampleTLEs`, the published Spacetrack Report #3 test element set 88888, plus made-up elements generated for a pass over `SkyFixtures.observer`.

**Interfaces:**
- Consumes: `SkyMath`, `SunEphemeris`, `SkyHTTP`, `SkyTrack`, `SkyMeasures`, `SkyCameraModel` and `AimFitter.matchTolerance`.
- Produces:

```swift
struct TwoLineElements: Sendable, Equatable { var name: String; var catalogNumber: Int; var epoch: Date; var inclination, raan, eccentricity, argumentOfPerigee, meanAnomaly, meanMotion, bstar: Double
    static func parse(_ text: String) -> [TwoLineElements] }   // 2- or 3-line sets; bad checksums and malformed lines skipped
struct SGP4: Sendable { init?(_ elements: TwoLineElements)    // nil for deep space (period ≥ 225 min)
    func state(minutesSinceEpoch: Double) -> (position: SIMD3<Double>, velocity: SIMD3<Double>)? }   // km, km/s, TEME; WGS-72 constants
enum SatelliteSky { static func direction(_ teme: SIMD3<Double>, at: Date, observer: SkyObserver) -> (direction: SkyDirection, rangeKm: Double)
    static func isSunlit(_ teme: SIMD3<Double>, at: Date) -> Bool }   // cylindrical Earth shadow
struct SatelliteOrbit: Sendable { var name: String; var catalogNumber: Int; var sgp4: SGP4 }
actor OrbitCatalog {
    static let source = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle")!
    static let maximumBytes = 8 << 20; static let refreshAfter: TimeInterval = 86_400
    init(file: URL, http: any SkyHTTP, now: @escaping @Sendable () -> Date, log: Log)   // file: <data>/sky/orbits.tle
    func refreshIfDue() async                                  // called by the service only while a detector is on
    var orbits: [SatelliteOrbit] { get }; var loadedAt: Date? { get }
}
struct OrbitMatch: Sendable, Equatable { var name: String; var score: Double; var label: SkyLabel }   // .satellite or .satelliteFlare
enum OrbitMatcher { static func match(_ track: SkyTrack, measures: SkyMeasures, kind: SkyEntryKind, model: SkyCameraModel, aim: SkyAimQuality,
                                      observer: SkyObserver, orbits: [SatelliteOrbit]) -> OrbitMatch?
                    static func predicted(at: Date, model: SkyCameraModel, observer: SkyObserver, orbits: [SatelliteOrbit]) -> [(name: String, point: PixelPoint)] }   // for Task 10
```

**Rules.**
- **Visible:** the Sun below −6° at the observer, and the satellite sunlit.
- **Prefilter:** the position at the middle of the track, within 5°. The full check covers the start, middle and end within the tolerance for the aim, with heading agreement within 30°.
- **A flash** (an entry of kind `.flash`, from Task 10) or a track of at most 1.5 s at the predicted position of a sunlit satellite is labelled `.satelliteFlare`.
- **The detail** is the catalogue name as given, for example "ISS (ZARYA)".
- **The file.**
  - Refreshed when it is missing or older than 24 h, and never more often than that, even across restarts.
  - A failed download keeps the old file and is retried after 1 h.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sgp4MatchesSpacetrackReport3()            // 88888 at 0 min: X 2328.97, Y −5995.22, Z 1719.97 km; at 360 min: X 2456.11, Y −6071.94, Z 1222.90 km;
    // each within 2 km (if a value disagrees, check it against Vallado's published SGP4 verification output before changing the code)
@Test func deepSpaceElementsAreDropped()             // mean motion 1.0027 rev/day → SGP4(...) == nil
@Test func checksumsAreChecked()                     // one digit changed → that set skipped, others kept
@Test func visibleOnlyWhenSunlitAndDark()            // made-up pass at local noon → not visible; at 2 h after sunset with satellite sunlit → visible; in shadow → not
@Test func aSyntheticPassMatches()                   // made-up TLE pass over SkyFixtures.observer projected through truthPanorama (+0.1° noise) → .satellite, name
@Test func aTrackFiveDegreesOffDoesNotMatch()
@Test func aFlashAtASatelliteIsAFlare()              // 0.6 s stationary track at the predicted point → .satelliteFlare
@Test func theOrbitsAreFetchedAtMostDailyAndOnlyWhileOn() async   // fake SkyHTTP: all detectors off → 0 requests; on → 1; again within 24 h (even after
    // a new OrbitCatalog on the same file) → 0; file deleted → 1; 500 → old file kept, retry after 1 h
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter SkySatelliteTests`. Expected: FAIL.
- [ ] **Step 3: Implement** SGP4 for near-Earth orbits only, from Spacetrack Report #3 with Vallado's 2006 corrections, in plain Swift.
- [ ] **Step 4: Run the tests** on macOS and Linux. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: satellites from daily orbits, SGP4 on the box, passes and flares"`

---

### Task 10: Stars, planets and the Moon: the bundled catalogue, point lights, new lights, aim from stars

**Files:**
- Create:
  - `S/StarCatalog.swift`
  - `S/BrightStars+Data.swift`, generated
  - `Tools/make-star-catalog.sh`, which turns the CDS V/50 `catalog` into the generated file. It checks the source's SHA-256, which the script pins, and writes the source and checksum into the generated file's header.
  - `S/PlanetEphemeris.swift`
  - `S/MoonEphemeris.swift`
  - `S/PointSources.swift`
  - `S/PointLightWatch.swift`
- Modify:
  - `S/SkyCameraDetector.swift`:
    - a stack of 4 analysis pictures every 30 s at night;
    - the masks for stars, planets and the Moon;
    - stationary tracks go to the watch;
    - star correspondences go to the aim;
    - visibility comes from star matches.
  - `NOTICE` and `THIRD_PARTY_LICENSES.md`: the catalogue's credit.
- Test:
  - `K/Tests/BridgeEngineTests/SkyStarTests.swift`
  - `SkyFixtures.swift`: `madeUpStars`, about 60 stars on a made-up pattern, with magnitudes −1…5.

**Interfaces:**
- Consumes: `SkyCameraModel`, `AimCorrespondence`, `SkyAimStore`, `SkyFrameAnalyzer.background`, `SkyMask.excluded` and `OrbitMatcher.predicted`.
- Produces:

```swift
struct CatalogStar: Sendable, Equatable { var hr: Int; var rightAscension: Double; var declination: Double; var magnitude: Double }   // J2000 degrees
struct StarCatalog: Sendable { init(_ stars: [CatalogStar]); static let bright: StarCatalog   // BrightStars.packed decoded once, brightest first
    func expected(at: Date, observer: SkyObserver, model: SkyCameraModel, brighterThan: Double) -> [(star: CatalogStar, point: PixelPoint)] }   // precession to date
enum PlanetEphemeris { enum Body: String, CaseIterable { case mercury, venus, mars, jupiter, saturn }
    static func equatorial(_ body: Body, at: Date) -> (rightAscension: Double, declination: Double) }   // JPL approximate Keplerian elements (1800–2050)
enum MoonEphemeris { static func equatorial(at: Date) -> (rightAscension: Double, declination: Double, distanceKm: Double) }   // Meeus ch. 47, main terms
struct PointSource: Sendable, Equatable { var point: PixelPoint; var flux: Double; var fwhm: Double }
enum PointSourceFinder { static func find(_ stacked: GrayImage, mask: SkyMask) -> [PointSource] }   // local maxima ≥ 5σ, FWHM ≤ 4 px, at most 1500
struct StarMatchResult: Sendable { var correspondences: [AimCorrespondence]; var matchedStars: Int; var expectedStars: Int; var unmatched: [PointSource]; var known: [PixelPoint] }
enum StarMatcher { static func match(_ points: [PointSource], catalogue: StarCatalog, planets: Bool, satellites: [(name: String, point: PixelPoint)],
                                     model: SkyCameraModel, aim: SkyAimQuality, at: Date, observer: SkyObserver, pictureWidth: Int, limit: Double) -> StarMatchResult }
actor PointLightWatch { func pass(_ unmatched: [PointSource], at: Date, model: SkyCameraModel) -> [SkyEntry]   // new lights that ended
                        func stationary(_ track: SkyTrack, measures: SkyMeasures) }                                 // from the tracker
```

**Rules.**
- **The bundle.** HR, RA, Dec and V for every star with a position and V ≤ 6.5, written one line each as `hr,ra,dec,v`, with 3 decimals for the angles and 2 for V.
  - It is generated once, at development time. Ask the owner before downloading the source.
  - Nothing on the box ever downloads it, so the rule "only while on, never again unless missing" holds trivially.
- **Matching.**
  - While the aim is rough: RANSAC over the 40 brightest expected stars and the 40 brightest points (rotation only).
  - Otherwise: the nearest point within 3 × the tolerance (in px) for each expected star, brighter than `limit`.
  - `limit` is learned: the 80th percentile of the magnitudes of matched stars on clear passes, default 3.5.
  - Planets (Mercury to Saturn) and the Moon count as known. Satellites' predicted points within 1° count as known.
- **Ignored.**
  - Known points, and planets within 0.3°, are added to `SkyMask.excluded` (radius 3 px) until the next pass, so twinkling never starts a track.
  - The Moon within 4° is masked.
- **The aim.** At most every 30 min at night, with 25 or more matched stars, the correspondences (source `.star`) go to `SkyAimStore.add`. This is the design's star refinement, which arrives here as soon as the catalogue exists.
- **Visibility at night** becomes matched / expected for each cell of the 4×2 grid, which replaces Task 3's measure once 3 clear passes exist.
- **New lights** (kind `.newLight`, label `.unexplained`, `by` nil):
  - an unmatched point present in 2 consecutive passes, within 3 px or drifting at most 0.05°/s, is a new light;
  - so is a stationary tracker track;
  - one that appears, stays and vanishes is **one** entry, ended after 2 passes without it;
  - its measures are the same as a track's, with speed as its drift.
- **Flashes** (kind `.flash`): a streak-born or under-1.5-s track whose displacement is at most 3 px. A flash goes through `OrbitMatcher` (flare) first.
- **The log** shows the stars through `aim.stars`, as in "Aim: precise, 214 stars matched, 1.8 px".

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theBundledCatalogueIsComplete()           // 9,000…9,120 stars, all V ≤ 6.5; the brightest is HR 2491 at V −1.46 near RA 101.29°, Dec −16.72°
@Test func planetsMatchMeeus()                       // Venus 1992-12-20 0h TD: RA 316.17 ± 0.1°, Dec −18.89 ± 0.1° (Meeus example 33.a)
@Test func theMoonMatchesMeeus()                     // 1992-04-12 0h TD: RA 134.69 ± 0.3°, Dec 13.77 ± 0.3° (Meeus example 47.a)
@Test func madeUpStarsAreMatchedFromARoughAim()      // madeUpStars through truthPanorama → points; from initial(facing: 0, tilt: 20) → ≥ 90 % matched
@Test func starsRefineTheAimAndFreeDistortion() async   // 3 passes of 200 points → SkyAimStore stage 3, quality precise, residual ≤ 2 px
@Test func knownLightsAreIgnored()                   // a twinkling star (flux ±50 % per frame) and Jupiter's position: no track, no entry
@Test func aNewLightIsOneEntry()                     // an unmatched point present 4 passes then gone → one .newLight entry with duration ≈ 90 s
@Test func aPointThatIsAPlanetIsNotNew()
@Test func aFlashNotAtASatelliteIsUnexplained()      // and one at a predicted satellite point → .satelliteFlare
@Test func cloudsLowerTheVisibility()                // half the expected stars missing on one side → that half's cells not visible
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter SkyStarTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces and Rules. Run `sh Tools/make-star-catalog.sh <path to catalog>` once, after the owner's OK to download the CDS file, and commit the generated file. Add the credit lines to `NOTICE` and `THIRD_PARTY_LICENSES.md`.
- [ ] **Step 4: Run the tests** on macOS and Linux. The generated file must compile in under 30 s on Linux. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: bundled bright stars, planets and the Moon; known lights ignored, new lights logged, aim from stars"`

---

### Task 11: Rules, the unusual rule, learning and the alert gate

**Files:**
- Create:
  - `S/SkyRules.swift`
  - `S/SkyBaseline.swift`
  - `S/SkyAlertGate.swift`
- Modify:
  - `S/SkyCameraDetector.swift`:
    - the pipeline becomes flight → orbit → rules → (model, Task 13) → (AI, Task 12);
    - it sets `unusual`, `speedVsPlanes` and `candidate`;
    - the baseline learns from flight and orbit matches;
    - `<data>/sky/<camera>/baseline.json`.
- Test: `K/Tests/BridgeEngineTests/SkyRulesTests.swift`

**Interfaces:**
- Consumes: `SkyMeasures`, `SkyLabel`, `SkyEntry`, `SkyLearning` and `SunEphemeris`.
- Produces:

```swift
enum SkyRules { static func classify(_ m: SkyMeasures, streakBorn: Bool, sunElevation: Double) -> SkyLabel? }   // .meteor, .bug, .bird, or nil
struct SkyBaseline: Codable, Sendable {
    static let bands: [ClosedRange<Double>] = [0...10, 10...30, 30...60, 60...90]
    mutating func learn(_ m: SkyMeasures, label: SkyLabel)        // .plane / .satellite only (not probable); last 500 per band and kind
    func learning(orbitsLoaded: Bool) -> SkyLearning               // ready: ≥ 30 planes and (orbits not loaded or ≥ 10 satellites)
    func unusual(_ m: SkyMeasures) -> [SkyUnusualReason]
    func speedVsPlanes(_ m: SkyMeasures) -> Double?                // speed ÷ median plane speed in the band; nil with < 10 planes anywhere
}
enum SkyAlertDecision: Equatable { case alert, join(entryID: String), none(String) }
struct SkyAlertGate: Codable, Sendable { static let window: TimeInterval = 300
    mutating func consider(_ entry: SkyEntry, at: Date, learning: SkyLearning, skyVisible: Bool?) -> SkyAlertDecision }
```

**Values (pinned):**
- **Meteor:** a duration of at most 2.0 s, straightness ≥ 0.98, at least 4°/s, no blink. It is either streak-born or has 3 or more samples.
- **Bug:** focus ≤ 0.35 (blurred, near the lens), and either a size of at least 1.0° or at least 3 turns of 45° or more.
- **Bird:**
  - the Sun at −6° or above;
  - a size of 0.2–4°, a speed of 1–30°/s, focus > 0.35;
  - the shape is `curved` or `straight`, and it is not a meteor.
- **The unusual reasons**, measured in the entry's elevation band (a band with fewer than 10 samples uses all the bands):
  - `faster`: the speed is above 1.5 × the larger of the planes' and the satellites' p95 speeds;
  - `larger`: the size is above 1.5 × the planes' p95 size;
  - `brighter`: the brightness is above 1.5 × the p95 brightness of planes and satellites;
  - `suddenStop` and `sharpTurn`: from the shape.
  - Before learning, the defaults are a p95 speed of 2.0°/s and a p95 size of 0.3°, and no `brighter`.
- **Candidates and alerts.**
  - `candidate` = unexplained ∧ at least one unusual reason. It is logged even while learning.
  - The gate alerts only when all of these hold:
    - the entry is a candidate;
    - learning is ready;
    - `skyVisible` is not `false` (cloudy or not-visible hours never alert);
    - no alert for this camera in the last 300 s. Within the window it is `join`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func rulesTellMeteorsBugsAndBirds()            // measures fixtures for each, and a plane-like track → nil
@Test func theUnusualRuleUsesTheLearnedBaseline()    // 40 planes at ~0.8 °/s in band 0–10: a 5 °/s unexplained → [.faster], speedVsPlanes ≈ 6.2
@Test func withinTheBaselineIsNotUnusual()
@Test func aBandWithFewSamplesUsesAllBands()
@Test func nothingAlertsWhileLearning()              // 29 planes → candidate true, decision .none("learning")
@Test func satellitesAreNeededWhenOrbitsAreLoaded()  // 30 planes, 4 satellites, orbits loaded → not ready; orbits not loaded → ready
@Test func repeatsWithinTheWindowAreOneAlert()       // candidates at t, t+120 → .alert, .join(first); t+301 → .alert; another camera's gate independent
@Test func cloudyHoursNeverAlert()                   // skyVisible false → .none
@Test func planesAndBugsNeverAlert()                 // a matched plane and a rule bug with unusual-looking measures → candidate false
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter SkyRulesTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces and Values. The baseline persists, and is cleared with the aim when the camera seems to have moved (Task 2).
- [ ] **Step 4: Run the tests** on macOS and Linux. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: meteor, bug and bird rules, the unusual rule learned per camera, and the alert gate"`

---

### Task 12: The AI for leftovers, and the alert (toast, Notifications, Home sensor)

**Files:**
- Create:
  - `S/SkyAI.swift`
  - `S/AnthropicSkyClassifier.swift`
  - `S/OpenAICompatibleSkyClassifier.swift`
  - `S/SkyLeftovers.swift`
  - `S/SkyAlert.swift`
- Modify:
  - `K/Sources/MediaCore/Codecs.swift`: `jpeg(fromGray:quality:)` with a default that throws `unsupported`.
  - `K/Sources/PlatformLinux/Codecs/FFmpegMediaCodecs.swift` and `FFmpegPictures.swift`: gray to mjpeg.
  - `K/Sources/BridgeEngine/Runtime/CameraRuntime.swift`: `skyFullQuality(around:)`.
  - `S/SkyCameraDetector.swift`:
    - a ring of analysis pictures (the last 12 s, cropped around each open track);
    - leftovers go to the queue;
    - the alert flow.
  - `K/Sources/BridgeEngine/BridgeEngine+Sky.swift`: `skyAlerts` and the AI service from the AI settings and key.
  - `K/Sources/BridgeEngine/Sensors/BridgedSensor.swift` and `SensorsBridge.swift`: `.sky`.
  - `K/Sources/BridgeWeb/BridgeBackend.swift`: `BridgeOverview.skyAlerts`.
  - `K/Sources/BridgeWeb/Resources.swift`: `NoticeResource.skyNotice`, and the category `skyDetector` → "cameras".
  - `K/Sources/BridgeWeb/NotificationLog.swift`: `eventKinds` gains `skyDetector`.
  - `W/js/screens/ai-settings.js`: the field "Sky detector: up to N pictures a day". The notification's button opens `#/sky/<camera>?entry=<id>`.
  - The docs.
- Test:
  - `K/Tests/BridgeEngineTests/SkyAITests.swift`
  - `K/Tests/BridgeEngineTests/SkyAlertTests.swift`
  - `K/Tests/BridgeWebTests/SkyNotificationTests.swift`
  - `linux/web-tests/sky-notification.test.mjs`

**Interfaces:**
- Consumes:
  - `AIDescriptionSettings`, `AITransport.answer(to:)`, `AIJSON`, `AISecret`, `AIUsage`, `LabeledPicture` and `BridgeEngine.aiKey()`;
  - `SkyAlertGate` and `SkyLogStore.recordAI` / `recordAlert`.
- Produces:

```swift
public enum SkyAIKind: String, Codable, Sendable, CaseIterable { case plane, satellite, bird, insect, meteor, balloon, drone, artifact, unknown
    public var suppressesAlert: Bool }   // plane, bird, insect, satellite, meteor
// SkyAIAnswer (Task 5) keeps `kind` as SkyAIKind.rawValue; read it back with SkyAIKind(rawValue:) ?? .unknown
struct SkyAIRequest: Sendable { var cameraName: String; var localTime: String; var direction: String; var azimuth: Int; var elevation: Int; var duration: Double
    var speed: String?; var blink: String; var path: String; var nearestPlane: String?; var nearestSatellite: String?; var pictures: [LabeledPicture] }   // no location
protocol SkyAIClassifying: Sendable { var model: String { get }; func classify(_ request: SkyAIRequest) async throws -> SkyAIAnswer }
struct AnthropicSkyClassifier: SkyAIClassifying   // tool "classify_sky_object" {kind enum SkyAIKind, sentence}; max_tokens 200
struct OpenAICompatibleSkyClassifier: SkyAIClassifying   // + "Reply with only a JSON object with keys kind and sentence."
enum SkyPrompt { static let system: String; static func userText(_ r: SkyAIRequest) -> String }
actor SkyLeftoverQueue { init(usageFile: URL, now: @escaping @Sendable () -> Date)   // <data>/ai/sky-usage.json, the bridge's time zone
    func setService(_ s: (any SkyAIClassifying)?, dailyLimit: Int)
    func ask(_ r: SkyAIRequest, urgent: Bool) async -> SkyAIAnswer? }   // width 1; urgent (candidates) first; non-urgent stale after 600 s; nil: no service, limit, failure
public struct SkyAlert: Sendable, Equatable { public var id: String; public var cameraID: UUID; public var cameraName: String; public var entryID: String; public var night: String
    public var date: Date; public var title: String; public var detail: String }   // id "sky-<camera>-<entry id>"
// BridgeEngine.skyAlerts: [SkyAlert] (last 24 h, at most 20); BridgeOverview.skyAlerts; NoticeResource.skyNotice(_:) kind "skyDetector", severity "info", action "open-sky"
// BridgedSensor.sky: MotionSensor, keySuffix "skyDetector", label "Sky Detector", model "Motion Sensor"; published for cameras with skyDetector.enabled
// SensorsBridge.skyAlert(cameraID: UUID) async   // motionDetected 1 for 30 s, then 0; a joined repeat does not trip it again
// MediaCodecs.jpeg(fromGray: GrayImage, quality: Double) throws -> Data ; CameraRuntime.skyFullQuality(around: Date) async -> (gray: GrayImage, jpeg: Data, at: Date)?
```

`SkyPrompt.system` is exactly:

```
You look at still pictures from a home security camera that points at the sky, and say what crossed it. You get crops from the start,
middle and end of one object's path and a stack of the whole path, with what the camera measured. The camera cannot measure distance,
so never state a size, a height or a speed in units. Choose one kind: plane, satellite, bird, insect, meteor, balloon, drone, artifact
(a lens flare, reflection, raindrop, cobweb or anything on or in the camera), or unknown. Say unknown when the pictures do not show enough;
do not guess. Then give one plain sentence of at most 20 words about what you see.
```

`userText` is:

```
Camera: <name>. Local time: <time>. Direction: <direction> (azimuth <az>°, elevation <el>°). Duration: <d> s. Speed across the sky: <speed or "not compared yet">. Blinking: <blink>. Path: <path>. Nearest plane: <… or "none known">. Nearest satellite: <… or "none visible">.
```

**Flow** (for each unexplained entry, after the rules and the model):
- **Pictures.**
  - Three crops (start, middle, end) from the analysis ring, and a max-stack crop of the whole path. Each crop is 3 × the track's box, at least 256 px; JPEG at quality 0.7, at most 4 pictures.
  - When a full-quality main-stream keyframe falls within the track, its crop replaces the middle one. That picture also refines `sizeDegrees` and `brightness`, measured in a 64-px window.
- **Asking.** `ask(urgent: candidate)`.
  - A candidate that would pass the gate waits up to **60 s** for the answer.
  - An answer whose kind `suppressesAlert` gives the entry `label` from that kind (insect → `.bug`), `by: .ai`, and no alert.
  - Otherwise, including timeouts, `unknown`, `balloon`, `drone` and `artifact`, the gate decides.
- **An alert** writes `recordAlert`, appends a `SkyAlert` and trips `SensorsBridge.skyAlert`.
  - The title is "Something unexplained in the sky". The detail is "<camera>: <direction>, <n> s, <first reason sentence>.", for example "Sky Test: low in the northwest, 3 s, about 6× faster across the sky than planes at that height."
  - A late answer is still stored on the entry; an alert is never taken back.
  - A person's correction (Task 5) overrides both in `SkyDisplay`.
  - The alert is a notice like the Internet guard's. Every client of the event stream and of `GET notifications` gets it, in the JSON shape documented in the BridgeWeb README, so a future iOS app can receive it without new routes.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func requestShapeAndOnlyStills()               // Anthropic body: 4 image/jpeg blocks + text, tool_choice classify_sky_object; no "video", no "40.0", no "-100.0"
@Test func answersAreParsedLeniently()               // OpenAI "```json {…}```"; kind "UFO" → .unknown; sentence capped at 140 at a word
@Test func theSkyLimitIsItsOwn() async               // dailyLimit 2: third ask → nil; the event describer's usage file untouched; resets at local midnight
@Test func anAIInsectSuppressesTheAlert() async      // candidate + answer insect within 60 s → no SkyAlert, entry label .bug by .ai
@Test func unknownAlertsOnlyWhenUnusual() async      // answer unknown + unusual → alert; balloon + unusual → alert
@Test func noAIOrLimitFallsBackToTheRule() async     // no service → alert after the rule, not after 60 s; limit reached likewise
@Test func theAlertWaitsAtMostSixtySeconds() async   // a service that never answers (fake clock) → alert at 60 s
@Test func aCorrectionOverridesTheAI() async         // AI said insect; person says notSure → display label unexplained
@Test func theHomeSensorTripsAndResets() async       // (SensorsBridge) .sky published only for enabled cameras; skyAlert → motionDetected 1, 0 after 30 s; one per camera
@Test func theNoticeIsAnEventLoggedOnce() async      // (BridgeWebTests) NoticeResource kind skyDetector, category cameras, action open-sky; NotificationLog logs it once
@Test func theAlertNeverMovesCameraMotion() async    // EventRouter state of the camera unchanged; no HKSV recording request
```

```js
test('a sky notification opens the entry in the sky log', …)   // action open-sky → #/sky/<camera>?entry=<id>
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "SkyAITests|SkyAlertTests|SkyNotificationTests"` and `node --test linux/web-tests/sky-notification.test.mjs`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces and Flow. Add CONTRACT_CHANGES rows (additive) for `SkyAlert`, `SkyAIKind`, `BridgeEngine.skyAlerts`, `BridgeOverview.skyAlerts`, `MediaCodecs.jpeg(fromGray:quality:)` and `BridgedSensor.sky`, with their README lines.
- [ ] **Step 4: Run the tests.** Run the filters, `swift test --filter "SensorsBridge|NotificationLog|AIProviderTests|EventDescriberTests"` (nothing else changed), `sh linux/web-tests/run.sh` and the Linux run. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: leftovers to the AI with its own limit; alerts as a notification and an Apple Home sensor"`

---

# Phase 3: the local model, night and day camera profiles, the USB receiver and online flight data

### Task 13: The local model

**Files:**
- Create:
  - `S/SkyModel.swift`
  - `S/SkyExampleStore.swift`
- Modify:
  - `S/SkyCameraDetector.swift`: the model step between the rules and the AI. Every label adds an example.
  - `K/Sources/BridgeEngine/BridgeEngine+Sky.swift`: a correction adds a person's example; the nightly retrain.
- Test: `K/Tests/BridgeEngineTests/SkyModelTests.swift`

**Interfaces:**
- Consumes: `SkyMeasures`, `SkyLabel`, `SkyLabelSource` and `SkyCorrection`.
- Produces:

```swift
enum SkyFeatures { static let count = 11
    static func vector(_ m: SkyMeasures, isNight: Bool) -> [Double] }   // log speed, acceleration, turnRate, maxTurn, log size, log brightness, blinkRate ?? 0,
                                                                        // log duration, focus, elevation, isNight
struct SkyExample: Codable, Sendable { var features: [Double]; var label: SkyLabel; var source: SkyLabelSource; var at: Date }
struct SkyModel: Codable, Sendable { static let k = 7; static let minimumPerLabel = 20; static let minimumConfidence = 0.8
    static func train(_ examples: [SkyExample]) -> SkyModel
    func predict(_ features: [Double]) -> (label: SkyLabel, confidence: Double)? }
actor SkyExampleStore { init(directory: URL); func add(_ e: SkyExample); func all() -> [SkyExample]; func replaceLabel(entryID: String, with: SkyLabel) }   // examples.jsonl, at most 5,000
```

**Rules.**
- **Weights:** person 5, flight 1, orbit 1, AI 1, rule 0.5. A `notSure` correction removes the entry's example and adds nothing.
- **Classes:** plane, satellite, meteor, bug and bird. `.probablePlane` counts as plane at weight 0.5. Unexplained is never trained.
- **Training:** standardization and a balanced sample of at most 1,500 examples per class. It runs 30 min after sunrise, or at start when the last training is more than 24 h old.
- **Use:** only with confidence ≥ 0.8 and at least 20 examples of the predicted label. The entry gets `by: .model` and skips the AI.
- **Guard:** never for an entry whose `speedVsPlanes` is 3 or more, or that is 3× or more larger than the baseline. Those always go to the AI.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func trainsInSecondsOnFiveThousandExamples()   // synthetic clusters: train + 1,000 predictions < 2 s (debug), accuracy ≥ 90 %
@Test func aPersonsCorrectionOutweighsMatches()      // 6 corrections "bug" vs 10 AI "bird" in one cluster → predicts bug
@Test func notSureTeachesNothing()
@Test func lowConfidenceGoesToTheAI()                // a point between clusters → nil (AI asked)
@Test func theStrangestNeverStopAtTheModel()         // speedVsPlanes 4 → model not consulted
@Test func retrainsAfterSunriseAndAtStart() async    // fake clock across a sunrise → one training; restart with a 30-hour-old model → one training
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter SkyModelTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces and Rules.
- [ ] **Step 4: Run the tests** on macOS and Linux. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: a small model trained on the box from matches, rules, the AI and corrections"`

---

### Task 14: Night and day camera profiles, with exact restore

**Files:**
- Create:
  - `K/Sources/CameraAdapters/Hikvision/HikvisionISAPI+Image.swift`
  - `K/Sources/CameraAdapters/ONVIF/CameraSettingsService+SkyProfile.swift`
  - `S/SkyProfiles.swift`
- Modify:
  - `K/Sources/CameraAdapters/ONVIF/ONVIFClient+Settings.swift`: `ONVIFImagingSettings` gains `exposureMode`, `maxExposureTime` and `maxGain`, and its options gain the gain range. Parse and write them.
  - `K/Sources/BridgeEngine/Configuration/Configuration.swift`: `CameraConfiguration.skyProfileBackup`, engine-owned like `cleanPictureBackup`. It is carried by `updateCamera` and ignored by `needsRestart`.
  - `K/Sources/BridgeEngine/BridgeEngine+Sky.swift`: the switches at sunset and sunrise, restore on off, restore at start.
  - `K/Sources/BridgeWeb/Resources.swift`: `status.sky.profile`.
  - `W/js/screens/sky-card.js`: the switch and its lines.
  - The test fakes:
    - `K/Tests/CameraAdaptersTests/Support/FakeSetupCamera.swift`: the `/ISAPI/Image/channels/1/*` documents;
    - `MockONVIFCamera.swift`: imaging with exposure.
  - The docs.
- Test:
  - `K/Tests/CameraAdaptersTests/SkyProfileTests.swift`
  - `K/Tests/BridgeEngineTests/SkyProfileEngineTests.swift`
  - `linux/web-tests/sky-card.test.mjs` (extend)

**Interfaces:**
- Consumes: `CameraSettingsService`, `HikvisionISAPI.get/put/xml`, the ONVIF imaging calls, `SunEphemeris` and `SkyNight`.
- Produces:

```swift
public struct SkyProfileBackup: Sendable, Codable, Equatable { public var method: CameraConfigMethod; public var created: Date
    public var documents: [String: String]     // Hikvision: path → the whole document as the camera had it (verbatim XML)
    public var onvif: SkyONVIFImagingBackup? }  // the imaging fields used, as read: irCutFilter, exposureMode, maxExposureTime, maxGain
public struct SkyProfileChange: Sendable { public var succeeded: Bool; public var backup: SkyProfileBackup?; public var skipped: [String]; public var summary: String }
extension CameraSettingsService {
    public func readSkyProfile() async throws -> SkyProfileBackup             // reads only the documents/fields the night profile writes
    public func applySkyNightProfile() async throws -> SkyProfileChange       // writes, then reads back; a value not taken goes to `skipped`
    public func restoreSkyProfile(_ backup: SkyProfileBackup) async throws -> SkyProfileChange   // writes the backup back verbatim, then reads back
}
// BridgeEngine: CameraConfiguration.skyProfileBackup: SkyProfileBackup? ; SkyCameraStatus.profile: "night" | "day" | "restoring" | nil
enum SkyProfileSchedule { static func wanted(at: Date, observer: SkyObserver) -> SkyProfileState }   // .night when the Sun is below −0.833°, else .day
```

**Rules.**
- **Hikvision paths:** `/ISAPI/Image/channels/1/SupplementLight`, `/IrcutFilter`, `/Shutter` and `/Gain`. The values are those in the Decisions table. Only documents the camera answers are written; a 404 is skipped and reported.
- **ONVIF:** the imaging service only, using the video source token of the main profile.
- **Order** before every night:
  1. read the profile fresh, because the day settings are the camera's own and the person may have changed them;
  2. **save** the backup to the configuration;
  3. then write.
- **Day:** `restoreSkyProfile(backup)`. The backup is kept while the detector is on, for the next night.
- **Off** (the detector or `nightProfile`): restore, read back, then clear the backup.
  - If the camera does not answer, the backup is kept, the restore is retried every 5 min, and the status is `restoring`.
- **Start:**
  - a backup with the detector off → restore;
  - a backup with the detector on → follow the Sun.
- **After a switch**, the detector makes no tracks for 10 s: a gap with the reason "camera profile changed".
- **Never** write `/ISAPI/System/Network/*`, nor any ONVIF `SetNetwork*`, `SetDNS`, `SetNTP`, `SetHostname` or `SetZeroConfiguration`.
- **The card:**
  - the switch **Night settings for the sky**;
  - the text "After sunset the camera’s infrared is turned off and its exposure set for the night sky; after sunrise its own settings come back. This changes its night recordings too.";
  - the status lines "Camera profile: night since 6:42 PM" and "Putting the camera back as it was…".

- [ ] **Step 1: Write the failing tests**

```swift
@Test func nightProfileWritesExactlyTheseValues() async throws   // (CameraAdapters) PUT bodies: supplementLightMode close, IrcutFilterType night, ShutterLevel 1/25,
    // GainLevel 80; without SupplementLight → IrcutFilterType day; ONVIF: IrCutFilter ON, MaxExposureTime 40000, MaxGain 0.8 × max
@Test func restoreWritesTheDocumentsBackVerbatim() async throws  // after night + restore, every document equals the original byte for byte
@Test func networkSettingsAreNeverTouched() async throws         // no request to /ISAPI/System/Network/*, no ONVIF Set* outside imaging
@Test func aRefusedValueIsSkippedAndSaid() async throws          // Shutter answers 403 → skipped ["Shutter"], others applied
@Test func theBackupIsSavedBeforeTheFirstChange() async throws   // (engine) first PUT fails after the save → configuration.skyProfileBackup present
@Test func turningOffRestoresExactly() async throws              // detector off → documents == originals; backup nil
@Test func aRestartMidProfileStillRestores() async throws        // night applied; new engine on the same data with the detector off → restored at start
@Test func anUnreachableCameraKeepsItsBackupAndRetries() async throws   // off while unreachable → backup kept, status restoring; reachable → restored within 5 min (fake clock)
@Test func dayChangesByThePersonAreKept() async throws           // day: the person sets GainLevel 30 on the camera; night re-reads → backup has 30; off → 30
@Test func profilesFollowTheSun() async throws                   // fake clock across sunset and sunrise at SkyFixtures.observer → night once, day once
@Test func theSecondsAfterAProfileSwitchMakeNoTracks() async throws   // frames with a +60 luma jump right after the switch → no entries
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter "SkyProfileTests|SkyProfileEngineTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces and Rules. Add a CONTRACT_CHANGES row (additive) for `SkyProfileBackup`, `SkyProfileChange`, `CameraSettingsService.readSkyProfile`, `CameraSettingsService.applySkyNightProfile`, `CameraSettingsService.restoreSkyProfile` and `CameraConfiguration.skyProfileBackup`.
- [ ] **Step 4: Run the tests.** Run the filters, `swift test --filter "CameraSetupEngineTests|CameraSettingsServiceTests|ONVIFDriverTests"` (unchanged), the Linux run and `sh linux/web-tests/run.sh`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: night-sky and day camera profiles by the sun, backed up first and restored exactly"`

---

### Task 15: The USB receiver, online flight data and weather

**Files:**
- Create:
  - `S/ADSBReceiver.swift`
  - `S/OnlineFlights.swift`
  - `S/SkyWeather.swift`
- Modify:
  - `S/SkyService.swift`: the flight sources in order; weather into conditions.
  - `linux/os/mkosi.conf`: `Packages=` gains `rtl-sdr`, and `readsb` (or `dump1090-fa`).
  - `linux/os/mkosi.postinst.chroot`: link the receiver into `/usr/lib/camera-bridge/helpers/`, and add the daemon's user to `plugdev`.
  - `linux/os/test-static.sh`: the helper is present.
  - `docs/third-party/`: the receiver's licence note.
  - `linux/os/README.md`.
- Test:
  - `K/Tests/BridgeEngineTests/SkySourcesTests.swift`
  - `linux/os/test-static.sh`

**Interfaces:**
- Consumes: `HelperLaunching` (`environment.platform.helpers`), `SkyHTTP`, `AircraftFeedParser`, `FlightHistory` and `SkyConditions`.
- Produces:

```swift
struct USBDevice: Sendable, Equatable { var vendor: String; var product: String }
enum ADSBReceiver { static let supported: Set<USBDevice> = [USBDevice(vendor: "0bda", product: "2838"), USBDevice(vendor: "0bda", product: "2832")]
    static func present(_ devices: [USBDevice]) -> Bool
    static func listUSB() -> [USBDevice]                           // Linux: /sys/bus/usb/devices/*/idVendor, idProduct; elsewhere []
    static func arguments(jsonDirectory: URL) -> [String] }        // ["--device-type", "rtlsdr", "--write-json", dir, "--write-json-every", "1", "--quiet"]
actor ADSBReceiverRunner { init(helpers: any HelperLaunching, directory: URL, history: FlightHistory, log: Log); func start() async -> Bool; func stop() async }
    // the helper "readsb" (or "dump1090-fa"); reads <directory>/aircraft.json each second; no location passed to it
enum SkyPrivacy { static func roundedCentre(_ l: SkyLocation) -> (latitude: Double, longitude: Double) }   // nearest 0.5°
actor OnlineFlights { static func url(_ centre: (latitude: Double, longitude: Double)) -> URL   // https://opendata.adsb.fi/api/v2/lat/{lat}/lon/{lon}/dist/150
    init(http: any SkyHTTP, history: FlightHistory); func start(centre:) ; func stop() async }   // every 10 s; 429 → double the wait up to 300 s
actor SkyWeather { static func url(_ centre: (latitude: Double, longitude: Double)) -> URL   // https://api.open-meteo.com/v1/forecast?latitude=…&longitude=…&hourly=cloud_cover&past_days=1&forecast_days=1&timezone=GMT
    init(http: any SkyHTTP); func start(centre:); func stop() async; func cloudCover(at: Date) -> Int? }   // hourly
enum FlightSourceChoice: String, Sendable { case networkFeed, usbReceiver, online, none }
```

**Rules.**
- **Order:**
  1. the network feed, when it is set and its last answer was less than 30 s ago;
  2. else the USB receiver, when one is present and the helper runs;
  3. else online.
- Only one source runs at a time. The choice is checked every 30 s, and shown in the status as "Flights: from the network feed / the USB receiver / online data near you".
- **Conditions:** the camera's visibility below 0.3 → notVisible. Else cloud cover of 70 % or more → cloudy. Else, with visibility known or cloud cover under 30 % → clear. Else unknown.
- By day, when the camera's visibility is unknown, the weather alone decides, so cloudy daytime hours do not alert.
- No source runs while no detector is on.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sourcesAreTriedInOrder() async            // feed answering → only feed requests; feed 404 for 30 s + receiver present → helper launched, no online request;
    // neither → online requests only
@Test func onlineRequestsCarryOnlyTheRoundedCentre() async   // location 40.0123/−100.2617 → URL has lat/40.0/lon/-100.5 and dist/150; no other coordinates anywhere in the request
@Test func nothingLeavesTheBoxWhileOff() async       // all detectors off for 10 min (fake clock): zero requests to any host, helper not running
@Test func onlineBacksOffOn429() async               // 429 ×3 → waits 20, 40, 80 s
@Test func theReceiverIsFoundAndRun() async          // fake USB list with 0bda:2838 → present; fake helper launcher gets the exact arguments; its aircraft.json feeds FlightHistory
@Test func weatherMakesCloudyHoursNotAlert() async   // cloud cover 90 % at 02:00 → conditions cloudy; SkyAlertGate skyVisible false then
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter SkySourcesTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the code as in Interfaces and Rules. In the image, check `apt-cache policy readsb dump1090-fa` in the builder image. Use `readsb` if the image's release has it, and `dump1090-fa` if not, and record which in `linux/os/README.md` and `docs/third-party/`.
- [ ] **Step 4: Run the tests.** Run `swift test --filter SkySourcesTests`, the Linux run and `sh linux/os/test-static.sh` (the image checks that run without building an image). Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Sky detector: the USB receiver on the box, online flights and weather, only while it is on"`

---

## Final: test it once

- [ ] **Step 1: Run every suite once.** Run these:
  - `swift test` (all)
  - `sh Tools/linux-test.sh` (build and all tests on Linux)
  - `sh linux/web-tests/run.sh`
  - `node linux/web-dev/lint.mjs`
  - `swift test --filter "DocsConsistencyTests|PortabilityTests"`

  Expected: everything PASS.
- [ ] **Step 2: Check the privacy constraints.** These checks must hold:
  - `git grep -n "192\.168\.4\.179"` prints only the design document's line;
  - `git grep -nE "40\.0000|100\.0000" -- ':!*Tests*' ':!docs/superpowers/plans/2026-10-25-sky-detector.md'` prints nothing;
  - no test file names a real place or key.
- [ ] **Step 3: Test once on the box, with the owner's yes for this test.** Push the daemon and the web page with the usual development overrides (the box notes, not in this repository).
  - Turn the detector on for the owner's sky camera. The owner types the location and the feed address on the box; they are not written down here.
  - Record these:
    - **The stream it chose:** the sub or main stream, the width and pictures per second, from `status.sky`.
    - **The CPU:** `top -b -d 60 -n 10 -p <camerabridged pid>,<sky decoder ffmpeg pid>`. The sky's share is the difference from the same camera with the detector off. It must be under 25 % of one core.
    - **A night's log:**
      - planes matched, and the aim reaching good;
      - stars matched, and the residual in px;
      - the night profile applied at sunset and restored at sunrise;
      - no plane or bug alert.
    - **Restore:** turn the detector off and check the camera's ISAPI image documents equal the backup.
- [ ] **Step 4: Report** the stream choice, the CPU figure and anything the night showed to the owner. Nothing is published to GitHub and no CI is dispatched without his yes.
