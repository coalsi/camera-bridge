# Camera Bridge for Apple TV, the Box Side (beta 0.1.132) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything the Apple TV app needs from the box in beta 0.1.132: a TV pairs with a code the owner enters in Settings, gets a key
that can only watch (and move cameras that pan and tilt), reads `GET viewer`, and finds the box by `_camera-bridge._tcp`.

**Architecture:** Pairing requests live in memory in a pure value, `ViewerPairing` (codes, limits, expiry), held by `AuthStore`, which also
keeps the TVs (the SHA-256 of their keys) and the box's identity in `auth.json` beside the browser sessions. A third route access level,
`viewer`, lets either a browser session (as today) or a TV's `Authorization: Bearer` key through on eleven routes. `ViewerAnnouncer`
registers `_camera-bridge._tcp` through the platform's `ServiceAdvertiser` once the web port listens; the daemon hands it the advertiser on
Camera Bridge OS only. The page gets an Apple TV card in Settings › Security and the `#/pair/<code>` address.

**Tech Stack:** Swift 6.4 / Swift Testing (`Packages/CameraBridgeKit`: BridgeWeb, BridgeDaemon), swift-crypto (SHA-256), avahi through
`PlatformLinux.DNSSDServiceAdvertiser`; the vanilla JS page (`linux/web`) and Node's test runner (`linux/web-tests`); bash and Python 3
(standard library) in `linux/os/test-vm.sh`.

**Spec:** `docs/superpowers/specs/2026-11-01-apple-tv-app-design.md`, sections "The box side (beta 0.1.132)" and the box half of
"Testing". The app itself is planned in `docs/superpowers/plans/2026-11-01-apple-tv-app.md`; the HTTP and Bonjour contract in the
Interfaces of Tasks 3 to 6 is the interface between the two plans, and neither renames anything in it.

`K` = `Packages/CameraBridgeKit`. Mac tests: `cd K && swift build --build-tests && swift test --skip-build --filter <Suites>`. Linux:
`CB_CPUS=6 sh Tools/linux-test.sh test --filter <Suites>`. Web: `sh linux/web-tests/run.sh` and `node linux/web-dev/lint.mjs`.

## Global Constraints

- "Box changes ship in a beta (at most one a day; 0.1.131 went out 2026-11-01, so the box side is 0.1.132 at the earliest, 2026-11-02)."
- "The engine package stays portable (Linux and macOS only; tvOS is not added to it)." Apple-only frameworks stay in PlatformApple, and
  BridgeDaemon's import graph (`Tests/PortabilityTests`) does not change.
- The code: "8 letters from a consonant-only alphabet (`BCDFGHJKLMNPQRSTVWXZ`, no vowels so no words), shown as `ABCD-EFGH`"; "Codes match
  ignoring case, spaces and the dash"; "At most 3 open requests per address and 20 in all (429 otherwise); a request lasts 10 minutes and
  lives only in memory."
- "The token is 32 random bytes (hex). The box keeps only its SHA-256 (in the same file as the browser sessions), with the TV's name, device
  model, when it was added, when and from where it was last used. A key unused for a year stops working. At most 20 TVs (409
  `too_many_viewers`). Changing the admin password does not remove TVs; a factory reset does."
- "A key never works in the address (`?token=`) and never on any other route (401)." "No admin password typed into or kept on a TV; a TV's
  key cannot change anything on the box except where a camera points."
- "The daemon announces `_camera-bridge._tcp` on the web port with TXT `id` …, `name` …, `v` … and `api=1`. Not in development runs. The old
  `_http._tcp` announcement stays for browsers."
- "Nothing leaves the home network: no cloud relay, no analytics, no crash reporting service."
- "Documentation addresses (192.0.2.x) in code, tests and docs" (2001:db8::/32 for IPv6); fixtures are synthetic.
- The page: no build step, the house rules of `linux/web-dev/lint.mjs` (DOM API only, network only through `js/api.js`), the page's plain
  voice, the product is "Camera Bridge". Every API error is `{error, code, message, field?}`.
- Builds only in `K/.build` and the Linux script's `cb-linux-build` volume. Commits stay local on `apple-tv` (one per task, plain sentence
  subjects like the log's, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`): no push, tag or release, nothing on the
  owner's box; publishing the beta waits for the owner's yes.

## Rulings (what the spec left open, decided here)

1. **The box's identity** is `auth.json`'s `bridgeID`: 16 random bytes as 32 lowercase hex, made the first time it is asked for (the web
   interface asks at start, to announce it), kept across restarts and password changes, gone with a factory reset. It lives in the same
   file as the TVs, so a fallback to `auth.json.bak` restores both together.
2. **Formats.** `request` is 32 lowercase hex (16 bytes), `secret` 64 lowercase hex (32 bytes), the key 64 lowercase hex; a viewer's `id` is
   32 lowercase hex and signs nobody in. `code` in JSON is the display form, `"BCDF-GHJK"`. Dates are ISO 8601 UTC in whole seconds
   (`2026-11-02T14:03:07Z`), as every answer outside the NVR routes (which keep epoch milliseconds).
3. **Statuses.** `pair` 200, `pair/status` 200 or 404, `approve` 201 `{viewer}`, `viewers` 200, `DELETE viewers/:id` 204 or 404. The 429 is
   `too_many_pairings`, with `Retry-After` = whole seconds until the oldest request it counted ends (at least 1). "Per address" is
   `LoginLimiter.key(for:)`: an IPv6 address counts by its /64, as for wrong passwords.
4. **Approval** creates the TV at once (its key's hash is saved, so the limit of 20 is checked there) and keeps the plain key in memory for
   one status answer. An approved request waits at least 60 s for its TV (an approval in the last seconds of the 10 minutes still reaches
   the TV's next poll); an approval nobody collects removes its TV when the request ends. Removing a TV drops its waiting approval
   (`pairing_gone`). An approval that cannot be saved is undone (`500 storage`): a TV that would vanish at the next restart is never added.
5. **Codes that open nothing.** Unknown, expired, already approved or malformed: all `404 no_such_code`. A missing `code` field is `400`.
6. **The key on the wire.** `Authorization: Bearer <key>` decides alone when it is there: a wrong one is `401 viewer_key` with
   `WWW-Authenticate: Bearer` (no cookie is cleared), even next to a session cookie. Without it, a viewer route applies exactly the session
   rules. `token=` or `access_token=` in the query of a viewer route is `400 invalid` (field `token`), as on `GET monitor`, even with a good
   header. On every other route the key is never looked at (`401 unauthorized`).
7. **A TV removed while it watches** loses its live view within 5 s (`WebConfiguration.viewerRecheckInterval`): the live stream checks that
   its key is still listed. Other viewer routes are short requests and fail on the next one.
8. **`GET viewer`.** `recordingNow` is the box's own recorder writing the camera now (its NVR state `recording`, what the TV's timeline
   plays), not Apple Home's recording (`CameraStatus.recordingNow` means Home's). `sound` is the camera's "Camera audio" switch
   (`audioEnabled`), the page's own rule for its speaker. `codec` is `h264` or `hevc`. A camera without a status yet is `idle` (`disabled`
   when turned off), with `false` and `null` elsewhere. `version` is what About shows (`SystemInfo.version`: 0.1.132 on the box, 0.1 on a
   development Mac). `secureURL` is the secure address report's `url` while its `state` is `ready`.
9. **Names.** The TV's `name` and `device` are cleaned as the bridge's name is (control characters out, trimmed, at most 60 characters);
   an empty name is "Apple TV", an empty device is null. The box shows `device` as the TV sends it (the app sends a model a person reads,
   like "Apple TV 4K (3rd generation)"); it never interprets it. Pairing may start before first-run setup; only approval needs the owner.
10. **Bonjour.** The instance name is the bridge's name cut to 63 UTF-8 bytes on a character boundary ("Camera Bridge" when nothing is
    left); TXT `name` is the whole name. A rename registers again. Registration starts once the web port listens, never delays the start,
    and is retried after a failure (1 s doubling to 60 s), as HAP's is. Announced on Camera Bridge OS only: never with `--dev`, never for
    `--preview`, never on a Mac.
11. **The Mac development daemon** serves every route of this plan and announces nothing (the spec's "Not in development runs"); there is
    no new flag. The tvOS simulator shares the Mac's network, so the app reaches it by typed address, `127.0.0.1:8080`, and the owner
    approves on the page or with curl. To try the app's Bonjour discovery, the developer runs `--dev --lan` and announces it by hand with
    macOS's `dns-sd -R` (the recipe goes in `K/Sources/camerabridged/README.md`, Task 6). A flag would need PlatformApple in BridgeDaemon (a
    change to the contract's module graph), and it would put a second "Camera Bridge" on every Apple TV in the house.
12. **The fake server and the conformance checker do not change.** `linux/web-dev/dev-archive-server.mjs` is the NVR stand-in and does not
    serve `auth/sessions` either; the card is developed against the real dev daemon and tested with injected functions, like the
    Signed-in browsers card. `conformance.mjs` checks the NVR contract, which stays as it is for browsers (401 `unauthorized` without
    credentials, 403 `csrf` without the token).
13. **`#/pair/<code>`** opens Settings at the Apple TV card with the code filled in and the keyboard on Add, after signing in if needed (the
    login keeps the address). It never approves by itself: a link alone must not add someone else's TV. After an approval from it the
    address becomes `#/settings`. The menu marks Settings for it, and Cameras still for `#/pair/sensors`.
14. **Docs.** `SECURITY.md` gets the key handling; the user guide waits until the app is on the owner's TVs (the app's plan may add it).

## Review Focus

1. **The update must not lock the owner out.** An `auth.json` written by 0.1.131 has no `viewers` and no `bridgeID`. A synthesized
   `Decodable` throws on a missing non-optional key even when the property has a default, and `AuthStore` takes a file it cannot decode for
   a damaged one: nobody could sign in. The new fields are optionals. Test: Task 2 `aPasswordFileFromBeforeAppleTVsReadsAsItWas`.
2. **A TV removed while it watches live.** The owner removes a TV that has a live view open: its key is refused at once, and the open stream
   ends too. Test: Task 5 `aTVRemovedWhileWatchingLiveIsCutOff`.
3. **Approved at the last moment, or never collected.** An approval 10 s before the request ends still reaches the TV's next poll; an
   approval the TV never collects leaves no TV in the list. Tests: Task 1 `anApprovalWaitsAMinuteForItsTV`, Task 2
   `anApprovalNobodyCollectsLeavesNoTV`.
4. **A bridge name DNS-SD cannot take, and a rename.** 60 accented letters or emoji are more than DNS-SD's 63 bytes; the box must still be
   found, and found under its new name after a rename. Tests: Task 6 `instanceNamesFitDNSSD`, `aRenameAnnouncesAgainUnderTheNewName`.
5. **A TV that asks again and again, or a network of IPv6 privacy addresses.** The 4th open request from one address is 429 with a
   `Retry-After` the app can wait out, and the addresses of one /64 count as one. Tests: Task 1 `threeOpenPerAddressAndTwentyInAll`,
   Task 3 `aFourthRequestFromOneAddressIs429WithRetryAfter`.

---

### Task 1: Pairing codes and requests (`ViewerPairing`)

**Files:**
- Create: `K/Sources/BridgeWeb/ViewerPairing.swift`
- Modify: `K/Sources/BridgeWeb/AuthStore.swift` (only the public value types below, under a new `// MARK: Apple TVs`)
- Test: `K/Tests/BridgeWebTests/ViewerPairingTests.swift`

**Interfaces:**
- Produces, in `AuthStore` (public, nested, `Sendable, Equatable`):
  - `struct ViewerInfo { var id: String; var name: String; var device: String?; var created: Date; var lastSeen: Date?; var address: String? }`
  - `struct PairingStart { var request: String; var secret: String; var code: String; var expiresIn: Int; var interval: Int }`
  - `enum PairingStatus { case waiting; case approved(token: String, viewer: ViewerInfo); case gone }`
  - `enum PairingFailure: Error { case busy(retryAfter: Int); case noSuchCode; case tooManyViewers }`
- Produces, internal, a value type like `LoginLimiter` (every time is passed in):
  - `struct ViewerPairing: Sendable` with `struct Policy { var lifetime: TimeInterval = 600; var collectWindow: TimeInterval = 60;
    var maximumPerAddress = 3; var maximumOpen = 20; var interval = 2 }`, `var policy`, and
    `struct Request: Sendable, Equatable { var id, secret, code: String; var name: String; var device: String?; var address: String;
    var expires: Date; var approval: Approval? }` (`code` without the dash), `struct Approval: Sendable, Equatable { var token: String;
    var viewer: AuthStore.ViewerInfo }`.
  - `static let alphabet: [Character]` (`BCDFGHJKLMNPQRSTVWXZ`), `static func randomCode() -> String` (8 letters),
    `static func displayed(_ code: String) -> String` ("BCDF-GHJK"), `static func normalized(_ typed: String) -> String?` (upper-cased,
    whitespace and `-` removed; nil unless exactly 8 letters of the alphabet), `var makeCode: @Sendable () -> String = ViewerPairing.randomCode`.
  - `mutating func expire(now: Date) -> [String]`: drops every request whose `expires` passed; returns the viewer ids of approvals nobody collected.
  - `mutating func open(name: String, device: String?, address: String, now: Date) throws -> Request` (throws `PairingFailure.busy`).
  - `func waiting(code: String, now: Date) -> Request?`: the open, not yet approved request with this normalized code.
  - `mutating func approve(requestID: String, token: String, viewer: AuthStore.ViewerInfo, now: Date)`: sets `approval` and
    `expires = max(expires, now + collectWindow)`.
  - `mutating func status(request: String, secret: String, now: Date) -> AuthStore.PairingStatus`: `.gone` for an unknown or ended request
    and for a wrong secret (the request is left as it is); `.approved` removes the request; else `.waiting`.
  - `mutating func forget(viewerID: String)`, `var openCount: Int`.

- [ ] **Step 1: Write the failing tests** (`@Suite struct ViewerPairingTests`, `t0 = Date(timeIntervalSince1970: 1_800_000_000)`):

```swift
@Test func codesAreEightLettersWithoutVowels()   // 2_000 randomCode(): each matches ^[BCDFGHJKLMNPQRSTVWXZ]{8}$ and all 20 letters
    // appear; displayed("BCDFGHJK") == "BCDF-GHJK"
@Test func typedCodesMatchIgnoringCaseSpacesAndTheDash()   // "bcdf-ghjk", " BCDF GHJK ", "bcdfghjk" → "BCDFGHJK";
    // "BCDFGHJ", "BCDFGHJKL", "ABCD-EFGH" (vowels), "BCDF_GHJK", "" → nil
@Test func anOpenRequestsCodeIsNeverHandedOutAgain()   // makeCode answers "BCDFGHJK", "BCDFGHJK", "LMNPQRST": the second open gets
    // LMNPQRST; id is 32 and secret 64 lowercase hex, and two opens never share either
@Test func threeOpenPerAddressAndTwentyInAll()   // 3 opens from 192.0.2.40 at t0; a 4th at t0+100 throws .busy(retryAfter: 500);
    // ::ffff:192.0.2.40 counts as 192.0.2.40; 2001:db8:1:2::1, ::2, ::3 open, 2001:db8:1:2::99 is busy (one /64), 2001:db8:1:3::1 opens;
    // with 20 open the 21st, from a new address, is busy(retryAfter: ≥ 1); at t0+601 (the first ones ended) 192.0.2.40 opens again
@Test func aRequestLastsTenMinutes()   // open at t0: waiting(code:, t0+599) finds it; at t0+601 nil, status → .gone, expire drops it
@Test func theKeyIsHandedOutOnceToTheRightSecret()   // approve; waiting(code:) is nil from then on; a wrong secret → .gone and the
    // right one still gets .approved(token, viewer); asked again → .gone; openCount 0
@Test func anApprovalWaitsAMinuteForItsTV()   // open at t0, approved at t0+590: status at t0+640 → .approved; another opened at t0,
    // approved at t0+10, never collected: expire(now: t0+601) returns its viewer id
@Test func forgettingATVDropsItsWaitingApproval()   // approve, forget(viewerID:) → status .gone
```

- [ ] **Step 2: Run them to see them fail** — `swift test --skip-build --filter ViewerPairingTests` → FAIL (types missing).

- [ ] **Step 3: Implement** in `ViewerPairing.swift`, with a header comment in the codebase's voice ("Modeled on how TV apps sign in (RFC 8628's
  device flow), local only…"). `randomCode()` draws each letter with `Int.random(in: 0..<20, using: &SystemRandomNumberGenerator)`; ids and
  secrets are `Secrets.hex(Secrets.randomBytes(16 / 32))`; the secret is compared with `Secrets.constantTimeEqual`. `open` counts by
  `LoginLimiter.key(for: address)`, then in all; `retryAfter` is `Int(oldest.expires.timeIntervalSince(now).rounded(.up))`, at least 1;
  it redraws a code equal to an open one.

- [ ] **Step 4: Run the tests** — same filter → PASS.

- [ ] **Step 5: Commit** — `git commit -m "Apple TV pairing: eight-letter codes without vowels, ten-minute requests and their limits"`

---

### Task 2: The TVs and the box's identity in `AuthStore`

**Files:**
- Modify: `K/Sources/BridgeWeb/AuthStore.swift` (`Stored` at line 197, the type's doc comment at 163, `// MARK: Apple TVs` before
  `// MARK: Storage` at 569)
- Test: `K/Tests/BridgeWebTests/ViewerStoreTests.swift`

**Interfaces:**
- Consumes: Task 1's `ViewerPairing` and the `AuthStore` value types.
- Produces (all on the actor, public unless noted):
  - `struct StoredViewer: Codable, Equatable { var id: String; var tokenHash: String; var name: String; var device: String?; var created: Date;
    var lastSeen: Date?; var address: String? }` (internal); `Stored.bridgeID: String?` and `Stored.viewers: [StoredViewer]?` (optionals:
    see Review Focus 1); `static let maximumViewers = 20`, `static let viewerIdleLifetime: TimeInterval = 365 * 86_400`.
  - `func bridgeID() -> String`
  - `func beginPairing(name: String?, device: String?, address: String) throws -> PairingStart` (`PairingFailure.busy`)
  - `func approvePairing(code: String) throws -> ViewerInfo` (`PairingFailure.noSuchCode`, `.tooManyViewers`, `Failure.storageFailed`, `.unreadable`)
  - `func pairingStatus(request: String, secret: String) -> PairingStatus`
  - `func viewers() -> [ViewerInfo]` (the one used last first, by `lastSeen ?? created`)
  - `func viewer(token: String, address: String?) -> ViewerInfo?` (records the use)
  - `func removeViewer(id: String) -> Bool`, `func isViewerListed(_ id: String) -> Bool`

- [ ] **Step 1: Write the failing tests** (`@Suite struct ViewerStoreTests`, the clock and `makeStore` of `AuthStoreTests`, 1_000 iterations):

```swift
@Test func theBoxKeepsOneIdentityForLife()   // bridgeID() is 32 lowercase hex, the same when asked again, the same from a new store on the
    // directory, after changePassword too; another directory → another id
@Test func aPasswordFileFromBeforeAppleTVsReadsAsItWas()   // web/auth.json written with JSONSerialization as 0.1.131 wrote it:
    // {bridgeName: "Hallway", password: the four fields of StoredPassword.make(password: "long enough", iterations: 1_000), sessions: [],
    // version: 1}; a store on it: isConfigured, !isDamaged, verify("long enough"), viewers() empty; bridgeID() then writes the id, and a
    // new store still verifies the password and has the same id
@Test func aTVPairsOnceAndTheFileHoldsOnlyItsKeysHash()   // beginPairing(name: "Living Room", device: "Apple TV 4K (3rd generation)",
    // address: "192.0.2.40") → code matches ^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$, expiresIn 600, interval 2; status .waiting;
    // approvePairing(code: the code lower-cased, a space for the dash) → ViewerInfo(name, device, created now, lastSeen nil, address
    // "192.0.2.40"); status → .approved(token 64 lowercase hex, viewer); again → .gone; viewer(token:) finds it; web/auth.json and
    // auth.json.bak contain sha256Hex(token) and none of: the token, the secret, the code
@Test func atMostTwentyTVsAndTheCodeStaysUsable()   // 20 pairs (addresses 192.0.2.1…20) approved and collected; the 21st approve throws
    // .tooManyViewers and adds nothing; removeViewer of one, then the same code approves
@Test func aKeyUnusedForAYearStopsWorking()   // used at t0+364 d → works; at that use + 365 d + 1 s → nil, gone from viewers() and from a
    // new store on the directory; one approved and never used: at created + 365 d + 1 s → nil
@Test func aKeysUseIsKeptAndWrittenAtMostHourly()   // use at t0+10 from 192.0.2.41 → viewers() says lastSeen t0+10 and 192.0.2.41, the
    // file still says lastSeen absent and 192.0.2.40; a use at t0+3_700 writes both
@Test func removingATVEndsItsKeyAndItsWaitingApproval()   // removeViewer → true, viewer(token:) nil, isViewerListed false, false the
    // second time; approved but not collected, then removed → status .gone
@Test func anApprovalNobodyCollectsLeavesNoTV()   // approved at t0+10, nobody asks; at t0+601 viewers() is empty, on disk too
@Test func anApprovalThatCannotBeSavedIsUndone()   // web/ 0500 (skip as root, as aSignInWorksWhileTheFileCannotBeWritten does):
    // approvePairing throws Failure.storageFailed, viewers() empty, the code still waits
@Test func changingThePasswordKeepsTheTVs()   // a paired key still works after changePassword
@Test func namesAndModelsAreCleaned()   // name "  Den\u{7}  " → "Den"; "" or nil → "Apple TV"; 80 characters → 60; device "  " → nil
@Test func malformedRequestsAndKeysAreRefusedWithoutWork()   // pairingStatus with non-hex or short values → .gone; viewer(token:) with
    // "", "abc", 64 uppercase hex or 500 characters → nil
```

- [ ] **Step 2: Run them to see them fail** — `swift test --skip-build --filter ViewerStoreTests` → FAIL.

- [ ] **Step 3: Implement.** Each entry point first calls `pairing.expire(now:)` and removes the TVs it returns (saved). `bridgeID()` makes
  `Secrets.hex(Secrets.randomBytes(16))` and saves (`do { try persist() } catch { unsaved = true }`). `approvePairing`: the waiting request,
  prune year-old TVs, count < 20, `token = Secrets.hex(Secrets.randomBytes(32))`, append `StoredViewer` (id 16 random bytes hex,
  `tokenHash = Secrets.sha256Hex(token)`, the request's name, device and address), `persist()`; on failure restore `stored` and rethrow;
  then `pairing.approve`. `viewer(token:address:)`: 64 lowercase hex only, constant-time match on the hash, a year since
  `lastSeen ?? created` removes it, else sets `lastSeen` and `address` (64 characters at most) and saves on the sessions' throttle
  (`unsaved || now − lastPersisted > persistInterval`). Names go through `cleaned`. Log at notice "an Apple TV was added (Living Room)",
  "… removed", "an Apple TV unused for a year was removed (…)"; never a key, code, request or secret. The type's doc comment says what
  `auth.json` now holds.

- [ ] **Step 4: Run the tests** — `swift test --skip-build --filter "ViewerStoreTests|AuthStoreTests|ViewerPairingTests"` → PASS; Linux,
  `CB_CPUS=6 sh Tools/linux-test.sh test --filter "ViewerStoreTests|AuthStoreTests"` → PASS (the read-only test skips there: root).

- [ ] **Step 5: Commit** — `git commit -m "Apple TVs are kept in auth.json as the hash of their keys, with the box's identity for life"`

---

### Task 3: Pairing, the list and removal over HTTP

**Files:**
- Create: `K/Sources/BridgeWeb/WebApp+Viewers.swift`
- Modify: `K/Sources/BridgeWeb/WebApp+Routes.swift:97` (`+ viewerRoutes`), `K/Tests/BridgeWebTests/Support.swift` (the helper below),
  `docs/linux/ARCHITECTURE.md` ("Web API" rows after `GET /api/v1/monitor`; "Security", the first-boot line)
- Test: `K/Tests/BridgeWebTests/ViewerPairingAPITests.swift`

**Interfaces:**
- Consumes: Task 2's `AuthStore` methods.
- Produces: `static let viewerRoutes: [Route]`; `func startPairing(_:)`, `func pairingStatus(_:)`, `func approveViewer(_:)`,
  `func listViewers()`, `func removeViewer(_:)`; `func pairingError(_ failure: AuthStore.PairingFailure) -> APIError`; test helper
  `extension Harness { struct PairedTV { var key: String; var id: String; var name: String }; func pairAppleTV(owner: Session,
  name: String = "Living Room", device: String? = "Apple TV 4K (3rd generation)", from address: String = "192.0.2.40") async throws -> PairedTV }`.
- The contract shared with the app (requests and answers are `application/json`):

```
POST /api/v1/viewers/pair             open (no sign-in)
  {"name": "Living Room", "device": "Apple TV 4K (3rd generation)"}          both optional strings; the body is required ({} is fine)
  200 {"request": "<32 hex>", "secret": "<64 hex>", "code": "BCDF-GHJK", "expiresIn": 600, "interval": 2}
  429 too_many_pairings + Retry-After: <seconds>
POST /api/v1/viewers/pair/status      open
  {"request": "<32 hex>", "secret": "<64 hex>"}
  200 {"state": "waiting"}
  200 {"state": "approved", "token": "<64 hex>", "viewer": {"id": "<32 hex>", "name": "Living Room"}}   once; the request is gone after it
  404 pairing_gone          ended, unknown, a wrong secret, collected already, or the TV removed meanwhile
POST /api/v1/viewers/approve          signed in, X-CSRF-Token
  {"code": "bcdf ghjk"}
  201 {"viewer": VIEWER}
  404 no_such_code · 409 too_many_viewers · 500 storage
GET /api/v1/viewers                   signed in
  200 {"viewers": [VIEWER, …]}        the one used last first
DELETE /api/v1/viewers/:id            signed in, X-CSRF-Token
  204 · 404 not_found
VIEWER = {"id": "<32 hex>", "name": "Living Room", "device": "Apple TV 4K (3rd generation)" | null,
          "created": "2026-11-02T14:03:07Z", "lastSeen": "2026-11-02T14:05:00Z" | null, "address": "192.0.2.40" | null}   every key always there
```

  Messages: `too_many_pairings` "Too many Apple TVs are asking for a code right now. Try again in a few minutes."; `pairing_gone` "This code
  ran out or was removed. Ask for a new one."; `no_such_code` "No Apple TV is waiting with this code. Check the code on the TV: it shows a
  new one every 10 minutes."; `too_many_viewers` "20 Apple TVs are added already. Remove one you no longer use, then try again.";
  `not_found` "That Apple TV isn’t added any more."; `storage` "The Apple TV couldn’t be saved. The disk may be full or read-only."

- [ ] **Step 1: Write the failing tests** (`@Suite(.timeLimit(.minutes(1))) struct ViewerPairingAPITests`, the Harness):

```swift
@Test func aTVPairsWithACodeTheOwnerEnters()   // pair without a cookie from 192.0.2.40 → 200, keys exactly {request, secret, code, expiresIn,
    // interval}; status → {state: "waiting"} (keys exactly {state}); approve without a session → 401, without CSRF → 403 csrf; approve with the
    // code lower-cased and spaced → 201, viewer keys exactly {id, name, device, created, lastSeen, address}, lastSeen null, address
    // "192.0.2.40"; status → keys exactly {state, token, viewer}, viewer keys {id, name}; again → 404 pairing_gone; GET viewers lists it
@Test func codesThatOpenNothingAre404NoSuchCode()   // "ZZZZ-ZZZZ", "ABCD-EFGH", the same code a second time → 404 no_such_code; {} → 400
@Test func aFourthRequestFromOneAddressIs429WithRetryAfter()   // 3 pairs from 192.0.2.40 → 200; the 4th → 429 too_many_pairings, Retry-After
    // an integer in 1…600; from 192.0.2.41 → 200
@Test func twentyTVsAtMost()   // 20 pairAppleTV from 192.0.2.1…20; the 21st approve → 409 too_many_viewers
@Test func aTVIsRemovedFromTheList()   // DELETE → 204; again → 404 not_found; GET viewers no longer lists it; DELETE without a session → 401
@Test func pairingIsOpenButNotToOtherSites()   // pair with Origin http://evil.example → 403 cross_origin; as text/plain → 415
```

- [ ] **Step 2: Run them to see them fail** — `swift test --skip-build --filter ViewerPairingAPITests` → FAIL.

- [ ] **Step 3: Implement** `WebApp+Viewers.swift` with a header comment listing the routes (as `WebApp+Sessions.swift` does): `Route("POST",
  "viewers/pair", .open, takesBody: true)`, `Route("POST", "viewers/pair/status", .open, takesBody: true)`, `Route("POST",
  "viewers/approve", takesBody: true)`, `Route("GET", "viewers")`, `Route("DELETE", "viewers/:id")`; bodies decoded with `decode` into
  private `Decodable` structs; addresses from `ctx.request.remoteAddress`; `ViewerResource` encodes `device`, `lastSeen` and `address` as
  `OrNull`. In ARCHITECTURE's "Web API", rows for the five routes in the block's style; in "Security", the first-boot line also names
  `/viewers/pair` and `/viewers/pair/status` (open, but they only make a code a signed-in owner must approve).

- [ ] **Step 4: Run the tests** — `swift test --skip-build --filter "ViewerPairingAPITests|SignedInBrowsersTests|AuthAPITests"` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "Apple TVs pair over HTTP: a code from the TV, approval in Settings, a key collected once"`

---

### Task 4: `GET viewer`

**Files:**
- Modify: `K/Sources/BridgeWeb/WebApp+Viewers.swift` (route and resources), `docs/linux/ARCHITECTURE.md` (its row),
  `K/Tests/BridgeWebTests/Support.swift` (`FakeBackend.State.withoutStatus: Set<UUID>`: cameras its overview gives no status for)
- Test: `K/Tests/BridgeWebTests/ViewerOverviewTests.swift`

**Interfaces:**
- Consumes: `auth.bridgeID()`, `auth.bridgeName`, `system.info().version`, `secureAddress.report()`, `backend.overview()`,
  `BridgeSettings.orderedIDs(of:)`.
- Produces: `Route("GET", "viewer")` in `viewerRoutes` (session access here; Task 5 makes it `.viewer`), `func viewerOverview() async ->
  HTTPResponse`, `static func secureURL(from report: SecureAddressService.Report) -> String?`. The answer, every key always there:

```json
{"bridge": {"id": "<32 hex>", "name": "Camera Bridge", "version": "0.1.132", "secureURL": "https://k7f2q9.box.camera-bridge.app" | null},
 "cameras": [{"id": "<UUID>", "name": "Front Door", "kind": "camera" | "doorbell", "enabled": true,
              "connection": "online" | "connecting" | "idle" | "disabled" | "offline", "motion": false, "recordingNow": true,
              "panTilt": false, "zoom": false, "sound": true,
              "main": {"width": 2560, "height": 1440, "codec": "h264" | "hevc"} | null, "sub": {"width": 640, "height": 360, "codec": "h264"} | null,
              "lastEvent": {"kind": "Doorbell ring", "date": "2026-11-02T14:03:07Z"} | null}]}
```

  `cameras` in the owner's order (`overview.settings.orderedIDs(of: overview.configurations)`); `kind` is `CameraKind.rawValue`;
  `connection` `StatusText.connectionName`; `motion` `motionActive`; `recordingNow` `status.nvr.state == .recording`; `main`/`sub` from
  `mainStreamInfo`/`subStreamInfo`; `lastEvent` from `lastEvent` and `lastEventDate` when both are there (its `kind` is the name
  `nvr/events` uses). No address, user name, stream URL, setting, token or setup code.

- [ ] **Step 1: Write the failing tests** (`@Suite struct ViewerOverviewTests`, read with the owner's session):

```swift
@Test func theAnswerHasExactlyTheSpecsKeys()   // top {bridge, cameras}; bridge {id, name, version, secureURL}; a camera exactly
    // {id, name, kind, enabled, connection, motion, recordingNow, panTilt, zoom, sound, main, sub, lastEvent}; bridge.id ==
    // await app.auth.bridgeID(), name "Hallway", version "0.1" (FakeSystem), secureURL null (no secure address)
@Test func camerasComeInTheOwnersOrder()   // cameras B, A, C with settings.cameraOrder [C, A] → C, A, B
@Test func eachCameraSaysWhatAViewerNeeds()   // a doorbell with a statusOverride: online, motionActive true, recordingNow false (Home's)
    // and nvr .recording, panTilt true, zoom false, mainStreamInfo hevc 2560×1440, no sub, lastEvent "Doorbell ring" at a date → kind
    // "doorbell", motion true, recordingNow true, panTilt true, zoom false, main {2560, 1440, "hevc"}, sub null, lastEvent {kind:
    // "Doorbell ring", date: ISO 8601}; sound true with audioEnabled, false without; then nvr .waiting and Home recording → recordingNow false
@Test func aCameraWithoutAStatusIsIdleOrDisabled()   // withoutStatus holds both cameras: the enabled one → "idle", the turned-off one →
    // "disabled"; motion, recordingNow, panTilt, zoom false; main, sub, lastEvent null
@Test func noAddressesUserNamesOrSecrets()   // camera host 192.0.2.20, username "admin", password "hunter2-camera", mainStreamURL
    // rtsp://192.0.2.20:554/main, webhook and monitoring tokens set: the answer's text contains none of them and no "rtsp"
@Test func secureURLIsTheReportsURLOnlyWhenReady()   // Report(state: "ready", url: "https://k7f2q9.box.camera-bridge.app") → that URL;
    // states "waiting", "off", "error" → nil
```

- [ ] **Step 2: Run them to see them fail** — `swift test --skip-build --filter ViewerOverviewTests` → FAIL.

- [ ] **Step 3: Implement** with private `Encodable` structs (`ViewerAnswer`, `ViewerBridgeResource`, `ViewerCameraResource`,
  `ViewerStreamResource`, `ViewerEventResource`), `OrNull` for every nullable key; ARCHITECTURE row: `GET /api/v1/viewer` with the shape
  above and the meanings of `recordingNow`, `sound` and `secureURL` (Ruling 8).

- [ ] **Step 4: Run the tests** — same filter → PASS.

- [ ] **Step 5: Commit** — `git commit -m "GET viewer: the bridge and its cameras as an Apple TV needs them, with no addresses or secrets"`

---

### Task 5: The `viewer` access level

**Files:**
- Modify: `K/Sources/BridgeWeb/WebApp.swift` (`WebConfiguration`: a property and its default near line 76; `RequestContext` at 86; the type's
  security list at 151; `api(_:)` at 325-346; `Route.Access` at 458), `K/Sources/BridgeWeb/WebApp+Routes.swift:29,31,35`,
  `K/Sources/BridgeWeb/WebApp+NVR.swift:10,24-30` (the header's "Every route needs a session" and the seven reading routes),
  `K/Sources/BridgeWeb/WebApp+Viewers.swift` (`GET viewer` → `.viewer`), `K/Sources/BridgeWeb/WebApp+LiveVideo.swift` (the recheck),
  `K/Sources/BridgeWeb/WebApp+Monitor.swift:110-111` (use the shared Bearer reader), `K/Sources/BridgeWeb/README.md` ("Security notes"),
  `docs/linux/ARCHITECTURE.md` ("Web API" paragraph and the eleven rows marked "viewer"; "Security", a bullet on the keys)
- Test: `K/Tests/BridgeWebTests/ViewerAccessTests.swift`

**Interfaces:**
- Consumes: `auth.viewer(token:address:)`, `auth.isViewerListed(_:)`, `Harness.pairAppleTV`.
- Produces: `enum Access { case open, session, viewer }`; `RequestContext.viewer: AuthStore.ViewerInfo?` (the TV a key belongs to, nil for a
  browser); `public var WebConfiguration.viewerRecheckInterval: Duration` (default 5 s); `static func bearerToken(in request: HTTPRequest) ->
  String?`; `static let addressTokenNames: Set<String> = ["token", "access_token"]`; `static let keyInTheAddress: APIError` and
  `static let viewerKeyRefused: APIError` (the two answers below).
- The viewer routes, exactly: `GET viewer`, `GET cameras/:id/snapshot`, `GET live`, `GET nvr/cameras`, `GET nvr/activity`, `GET nvr/events`,
  `GET nvr/cameras/:id/fragments`, `GET nvr/cameras/:id/fragments/:fid`, `GET nvr/cameras/:id/fragments/:fid/init`,
  `GET nvr/cameras/:id/keyframe`, `POST cameras/:id/pan-tilt`. A TV sends `Authorization: Bearer <64 hex>` (no cookie, no X-CSRF-Token; a
  POST body is still `Content-Type: application/json`). A wrong, expired or removed key: `401 viewer_key`, "This Apple TV was removed from
  Camera Bridge. Pair it again.", `WWW-Authenticate: Bearer`. `token=`/`access_token=` in a viewer route's query: `400 invalid`, field
  `token`, "Send the key in the Authorization header (Bearer), never in the address." The key on any other route: `401 unauthorized`.

- [ ] **Step 1: Write the failing tests** (`@Suite(.timeLimit(.minutes(1))) struct ViewerAccessTests`):

```swift
@Test func theViewerRoutesAreTheSpecsList()   // Set(WebApp.routes.filter { $0.access == .viewer }.map { "\($0.method) \($0.pattern.joined(separator: "/"))" })
    // == the eleven above
@Test func aKeyOpensExactlyTheViewerRoutes()   // every route in WebApp.routes but .open ones, ":id" → a real camera's id, ":fid" →
    // "0123456789ab.1", any other parameter → "x", a POST/PATCH/DELETE with {} as JSON, only the key: a .viewer route answers neither 401 nor
    // 403; every .session route answers 401 unauthorized
@Test func aKeyNeedsNoCSRFAndABrowserStillDoes()   // pan-tilt {pan: 0, tilt: 0} with the key, no CSRF → 204; with the cookie and no CSRF →
    // 403 csrf; with the key and Origin http://evil.example → 403 cross_origin
@Test func aKeyInTheAddressIsRefused()   // GET viewer?token=<key> with no header → 400 field "token"; with the header too → 400;
    // GET live?cameras=<id>&access_token=<key> → 400; GET settings?token=<key> → 401 unauthorized
@Test func aWrongOrRemovedKeyIs401ViewerKey()   // 64 hex nobody holds → 401 viewer_key, WWW-Authenticate Bearer, no Set-Cookie; the same
    // with a valid session cookie as well; after DELETE viewers/:id the real key → 401 viewer_key; a session alone still reads GET viewer
@Test func aTVRemovedWhileWatchingLiveIsCutOff()   // viewerRecheckInterval 20 ms; GET live?cameras=<id> with the key (the fake backend has
    // no live video: the stream stays open, saying "unavailable"); DELETE the TV → the stream finishes within 2 s; a browser's live stream
    // started the same way is not ended by it
@Test func aKeyIsUsedFromWhereItCameAndWhen()   // GET viewer with the key from 192.0.2.41 → GET viewers says address "192.0.2.41" and a lastSeen
```

- [ ] **Step 2: Run them to see them fail** — `swift test --skip-build --filter ViewerAccessTests` → FAIL.

- [ ] **Step 3: Implement.** The `.session` block of `api(_:)` moves into `private func requireSession(_ context: RequestContext, unsafe: Bool,
  configured: Bool) throws` unchanged; the access check becomes:

```swift
switch route.access {
case .open: break
case .session: try requireSession(context, unsafe: unsafe, configured: configured)
case .viewer:
    if request.query.contains(where: { Self.addressTokenNames.contains($0.name) }) { throw Self.keyInTheAddress }
    if let key = Self.bearerToken(in: request) {   // the key decides alone (Ruling 6)
        guard let viewer = await auth.viewer(token: key, address: request.remoteAddress) else { throw Self.viewerKeyRefused }
        context.viewer = viewer
        context.session = nil
        context.sessionToken = nil
        movesCookie = false
    } else {
        try requireSession(context, unsafe: unsafe, configured: configured)
    }
}
```

  `bearerToken(in:)` is the monitor's reading ("bearer " prefix, case ignored, trimmed; nil when absent or empty) and the monitor uses it.
  `liveVideo` adds, for a request with `ctx.viewer`, a task to its group that returns once `await auth.isViewerListed(id)` is false (checked
  every `viewerRecheckInterval`), which ends the group like a writer that stopped. The ARCHITECTURE paragraph under "Web API": rows marked
  "viewer" also take an Apple TV's key, with the rules above; the Security bullet: the key's storage, reach, lifetime and removal; the
  README's "Security notes": the same two points, and "every NVR route needs a session" gains "the seven reading ones also take a TV's key".

- [ ] **Step 4: Run the tests** — `swift test --skip-build --filter "ViewerAccessTests|ViewerOverviewTests|ViewerPairingAPITests|MonitorAPITests|LiveVideoRouteTests|PanTiltAPITests|ArchiveSecurityTests|ArchiveMediaRoutesTests|AuthAPITests"` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "An Apple TV's key opens the eleven viewer routes and nothing else, never in the address"`

---

### Task 6: `_camera-bridge._tcp`

**Files:**
- Create: `K/Sources/BridgeWeb/ViewerAnnouncer.swift`
- Modify: `K/Sources/BridgeWeb/WebApp.swift` (`WebConfiguration.viewerAdvertiser`, `WebApp.announcer`, `startAnnouncing`, `stopAnnouncing`),
  `K/Sources/BridgeWeb/WebService.swift` (`start`, `stop`), `K/Sources/BridgeWeb/WebApp+Bridge.swift:62-69` (a rename),
  `K/Sources/BridgeDaemon/Daemon.swift:118` (the advertiser), docs: `docs/linux/ARCHITECTURE.md` ("Processes on the box", the avahi line),
  `linux/os/README.md` (the hostname bullet), `linux/os/mkosi.extra/etc/avahi/avahi-daemon.conf` (its first comment line),
  `K/Sources/BridgeDaemon/README.md` ("Platforms"), `K/Sources/camerabridged/README.md` (the development recipe below)
- Test: `K/Tests/BridgeWebTests/ViewerAnnouncerTests.swift`, `K/Tests/BridgeDaemonTests/DaemonTests.swift` (macOS), and a test in
  `K/Tests/BridgeDaemonTests/DevelopmentFlagsTests.swift`

**Interfaces:**
- Consumes: `ServiceAdvertiser`, `ServiceAdvertisement`, `AdvertisedService` (BridgeSupport); `auth.bridgeID()`, `auth.bridgeName`,
  `system.info().version`.
- Produces:
  - `actor ViewerAnnouncer` with `struct Announcement: Sendable, Equatable { var id: String; var name: String; var version: String; var port: UInt16 }`,
    `static let serviceType = "_camera-bridge._tcp"`, `init(advertiser: any ServiceAdvertiser, retryDelay: Duration = .seconds(1),
    maximumRetryDelay: Duration = .seconds(60))`, `func start(_ announcement: Announcement) async`, `func rename(to name: String) async`,
    `func stop()`, `private(set) var announced: Announcement?`, `static func txt(for: Announcement) -> [String: String]`,
    `static func instanceName(for bridgeName: String) -> String`.
  - `public var WebConfiguration.viewerAdvertiser: (any ServiceAdvertiser)?` (default nil: nothing is announced);
    `let WebApp.announcer: ViewerAnnouncer?`; `func WebApp.startAnnouncing(port: UInt16)` (returns at once; a task gathers the id, name
    and version and starts the announcer); `func WebApp.stopAnnouncing() async`.
  - `static func Daemon.viewerAdvertiser(options: DaemonOptions, environment: BridgeEnvironment) -> (any ServiceAdvertiser)?`:
    `environment.platform.advertiser` when `!options.development`, `options.preview == nil` and `environment.advertise`; else nil.
- The contract shared with the app: type `_camera-bridge._tcp`, instance name = the bridge's name (Ruling 10), port = the web port (80 on
  the box), TXT `id` = `GET viewer`'s `bridge.id`, `name` = the bridge's name, `v` = `bridge.version`, `api` = `1`.

- [ ] **Step 1: Write the failing tests** (a `fileprivate` fake advertiser in the test file records advertisements and cancellations,
  fails the next N `advertise` calls on request, and can yield a later failure, like `HAPTests/Support/RecordingAdvertiser.swift`):

```swift
@Test func itAnnouncesItselfOnceTheWebPortListens()   // a WebService (FakeBackend, FakeSystem, FakeNetworkTransport(), the Harness's
    // configuration with viewerAdvertiser = fake) whose service.app.auth is configured with bridgeName "Hallway"; start() → eventually one
    // advertisement: type "_camera-bridge._tcp", name "Hallway", the port start() returned, txt == ["id": await service.app.auth.bridgeID(),
    // "name": "Hallway", "v": "0.1", "api": "1"]; stop() → it is cancelled
@Test func aRenameAnnouncesAgainUnderTheNewName()   // Harness(modify: viewerAdvertiser = fake), signed in; app.startAnnouncing(port: 8080);
    // PATCH settings {bridgeName: "Garage"} → the first registration cancelled, a second with name "Garage" and txt name "Garage"
@Test func aRegistrationThatFailsIsTriedAgain()   // retryDelay 10 ms; the first two advertise calls fail → a third registers; a later
    // failure on the service → it is cancelled and registered again; stop() → cancelled, no attempt afterwards
@Test func aStopDuringRegistrationWins()   // advertise held open by the fake, stop(), then let it finish → that service is cancelled
@Test func instanceNamesFitDNSSD()   // "Camera Bridge" unchanged; 60 × "é" (120 bytes) → ≤ 63 bytes and a prefix of it; 10 × "👨‍👩‍👧‍👦" →
    // ≤ 63 bytes, whole characters only; "   " → "Camera Bridge"
@Test func withoutAnAdvertiserNothingIsAnnounced()   // a default Harness: app.announcer == nil
// DevelopmentFlagsTests:
@Test func onlyCameraBridgeOSAnnouncesForAppleTVs()   // BridgeEnvironment.testing(directory:) with advertise false → nil; with advertise
    // true: no flags → that environment's advertiser (===), --dev → nil, --preview → nil
// DaemonTests (macOS):
@Test @MainActor func theDevelopmentDaemonPairsAnAppleTV()   // --dev over real HTTP: setup; pair (no cookie) → code; approve with the
    // cookie and CSRF → 201; status → token; GET /api/v1/viewer with only the key → 200, bridge.version "0.1", secureURL null;
    // GET /api/v1/settings with only the key → 401
```

- [ ] **Step 2: Run them to see them fail** — `swift test --skip-build --filter "ViewerAnnouncerTests|DevelopmentFlagsTests|DaemonTests"` → FAIL.

- [ ] **Step 3: Implement.** The actor keeps the announcement it wants and the one registered: `start` and `rename` set the wanted one and
  register when nothing is under way; after each `advertise` returns, a `stop()` meanwhile cancels the new service, and a rename meanwhile
  registers again; a failure (thrown, or later on `failures`) cancels what is left and retries after the delay, doubling up to the
  maximum, logging a failure only when it differs from the last. Notice on success: "Apple TVs can find this bridge: “Hallway”
  (_camera-bridge._tcp) on port 80". `instanceName(for:)` drops trailing characters until `utf8.count <= 63`, trims, and falls back to
  `AuthStore.defaultBridgeName`. `WebService.start()` calls `app.startAnnouncing(port:)` after `server.start()` returns the port;
  `stop()` awaits `app.stopAnnouncing()` first. `patchSettings` calls `await announcer?.rename(to: await auth.bridgeName)` after a saved
  `bridgeName`. The daemon sets `configuration.viewerAdvertiser = Self.viewerAdvertiser(options: options, environment: bridgeEnvironment)`.
  Docs: avahi "mDNS (HomeKit advertising, and `_camera-bridge._tcp` for the Apple TV app)"; the OS README's hostname bullet adds the
  announcement and its TXT; `camerabridged/README.md` gets "An Apple TV against a development daemon":

```
swift run camerabridged --dev --data-dir /tmp/cb-dev        # http://127.0.0.1:8080: set a password, add the demo camera
# tvOS simulator: Enter the address → 127.0.0.1:8080 (the simulator shares this Mac's network). Approve its code on the page
# (Settings › Apple TV, or http://127.0.0.1:8080/#/pair/<code>) or with curl:
curl -s -c /tmp/cb-dev.cookies -H 'Content-Type: application/json' -d '{"password":"<password>"}' http://127.0.0.1:8080/api/v1/auth/login
curl -s -b /tmp/cb-dev.cookies -H 'Content-Type: application/json' -H 'X-CSRF-Token: <csrfToken from the line above>' \
     -d '{"code":"<code>"}' http://127.0.0.1:8080/api/v1/viewers/approve
# The app's own discovery: --dev announces nothing, so announce by hand (with the id GET /api/v1/viewer gives) on a daemon that
# listens on the network; stop both afterwards, every Apple TV in the house sees it:
swift run camerabridged --dev --lan --data-dir /tmp/cb-dev
dns-sd -R "Camera Bridge (dev)" _camera-bridge._tcp local 8080 id=<bridge.id> name="Camera Bridge (dev)" v=0.1 api=1
```

- [ ] **Step 4: Run the tests** — same filter plus `PortabilityTests` → PASS; Linux, `CB_CPUS=6 sh Tools/linux-test.sh test --filter
  "ViewerAnnouncerTests|DevelopmentFlagsTests|ViewerStoreTests|ViewerAccessTests|PortabilityTests"` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "The box announces _camera-bridge._tcp for the Apple TV app; development runs announce nothing"`

---

### Task 7: The page: the Apple TV card and `#/pair/<code>`

**Files:**
- Create: `linux/web/js/screens/viewers-card.js`
- Modify: `linux/web/js/screens/settings.js` (the card beside `sessions.el` at line 209, made once like it at line 21; `wanted`
  `'apple-tv'` in `showWanted`; `destroy`), `linux/web/js/app.js` (NAV lines 38 and 42, a ROUTES entry after line 88),
  `linux/web/README.md` (the `js/screens/` line)
- Test: `linux/web-tests/viewers-card.test.mjs`

**Interfaces:**
- Consumes: the routes of Task 3; `get`, `post`, `del` (`js/api.js`); `confirmDialog`, `h`, `replace` (`js/dom.js`); `dateTime`
  (`js/format.js`); `relativeTime` (`js/notifications.js`); `field` (`screens/common.js`).
- Produces (exports of `viewers-card.js`):
  - `PAIR_ROUTE = /^pair\/([A-Za-z]{4}[- ]?[A-Za-z]{4})$/` and `isPairPath(path) -> boolean`
  - `tidyCode(text) -> string`: 8 letters, upper case, as `ABCD-EFGH`, whatever spaces and dashes were typed; `''` for anything else
  - `viewerTitle(viewer) -> string`: "Living Room · Apple TV 4K (3rd generation)" (no device: the name alone)
  - `viewerUse(viewer, now) -> string`: "Added Oct 28, 2026, 2:00 PM · last used 2 min ago from 192.0.2.40", "… · last used just now …",
    "… · not used yet" (times in the bridge's zone)
  - `createViewersCard({ load = () => get('viewers'), approve = (code) => post('viewers/approve', { code }), remove = (id) =>
    del('viewers/' + encodeURIComponent(id)), confirm = confirmDialog, now = () => Date.now(), onApproved = () => {} } = {})` →
    `{ el, refresh(), fill(code), destroy() }`
- Copy: heading "Apple TV"; description "Apple TVs with the Camera Bridge app. Each one can watch your cameras, live and recorded, and move
  cameras that pan and tilt. It can’t change anything else, and it never needs the password."; empty list "No Apple TV is added yet.";
  field "Add an Apple TV" (placeholder `BCDF-GHJK`, `autocomplete=off`, `autocapitalize=characters`), hint "Open Camera Bridge on the
  Apple TV and enter the code it shows.", button "Add"; without 8 letters "Enter the 8 letters the Apple TV shows."; after an approval
  "Living Room can watch your cameras now."; Remove asks `{ title: 'Remove Living Room?', body: '<viewerTitle>. It stops showing your
  cameras at once and needs a new code to come back.', confirm: 'Remove', danger: true }`; failures show the API's `message`, else "The
  Apple TVs can’t be read right now." / "That Apple TV couldn’t be removed." No new CSS: the generic classes (`card`, `desc`, `field`,
  `row`, `btn small`) as the Signed-in browsers card uses them, with `viewer-list`, `viewer-item`, `viewer-problem` as hooks.

- [ ] **Step 1: Write the failing tests** (the fake browser and helpers of `security-cards.test.mjs`; the bridge's zone America/Phoenix):

```js
test('each Apple TV is its name and model, then when it was added and last used, and from where', …)   // viewerTitle and viewerUse as above;
  // lastSeen null → 'not used yet'; the card lists the TVs of load() in the order given
test('a code is 8 letters shown as ABCD-EFGH, however it was typed', …)   // 'bcdfghjk', 'BCDF-GHJK', ' bcdf ghjk ' → 'BCDF-GHJK';
  // 'BCDFGHJ', 'BCDF-GHJK-L', '1234-5678' → ''
test('the address in the TV’s QR code is #/pair/<code>, and #/pair/sensors stays the sensors bridge’s', …)   // 'pair/BCDF-GHJK' and
  // 'pair/bcdfghjk' match with the code as group 1; isPairPath('pair/sensors') and ('pair/BCDF-GHJ') false
test('Add sends the code, says the TV can watch, and lists it; a code the bridge does not know is said on the card', …)   // approve gets
  // 'BCDF-GHJK' for typed 'bcdf ghjk'; the field empties, the status line says it, load() runs again; a 404 no_such_code → its message in
  // .viewer-problem, the list unchanged
test('Add without 8 letters asks for them and sends nothing', …)
test('Remove asks first: No sends nothing, Remove takes the TV off the list', …)   // and a 404 counts as removed
test('Settings opened from #/pair/<code> shows the card with the code filled in and the keyboard on Add', …)   // renderSettings({ params:
  // ['apple-tv', 'bcdfghjk'] }) with GET settings mocked as in settings-ai-address.test.mjs: once drawn, the input says 'BCDF-GHJK', Add
  // has the focus, the card was scrolled to; nothing was approved
```

- [ ] **Step 2: Run them to see them fail** — `node --test linux/web-tests/viewers-card.test.mjs` → FAIL (no module).

- [ ] **Step 3: Implement** after `sessions-card.js` (header comment with the routes and the answer it reads). Settings: `const viewers =
  createViewersCard({ onApproved: () => { if (location.hash.startsWith('#/pair/')) history.replaceState(null, '', '#/settings'); } })`;
  `section('Security', passwordCard(), sessions.el, viewers.el, accountCard())`; `showWanted()` for `'apple-tv'` scrolls to `viewers.el`
  and calls `viewers.fill(params[1])`. app.js: `{ pattern: PAIR_ROUTE, title: 'Settings', render: (context) => renderSettings({ ...context,
  params: ['apple-tv', context.params[0]] }) }`; Cameras' match keeps `pair/…` only when `!isPairPath(p)`, Settings' adds `isPairPath(p)`.
  README: the screens line names viewers-card (the routes it calls) and `#/pair/<code>`.

- [ ] **Step 4: Run the tests** — `node --test linux/web-tests/viewers-card.test.mjs`, then `sh linux/web-tests/run.sh` and
  `node linux/web-dev/lint.mjs` → PASS, no findings. Try it against the dev daemon (`swift run camerabridged --dev --data-dir /tmp/cb-dev`):
  pair with curl as in Task 6, approve on the page, open `http://127.0.0.1:8080/#/pair/<code>` signed out.

- [ ] **Step 5: Commit** — `git commit -m "Settings › Security has an Apple TV card, and the TV's QR code opens it with the code filled in"`

---

### Task 8: The record, the release note and the check on the box

**Files:**
- Modify: `K/Sources/BridgeWeb/README.md` (the Layout table; a new entry at the top of "Additions beyond the contract"),
  `K/Sources/BridgeDaemon/README.md` ("Additions beyond the contract"), `docs/CONTRACT_CHANGES.md` (a row at the end of the table),
  `SECURITY.md` ("Scope" and "What Camera Bridge does with secrets"), `linux/web/js/release-notes.js` (the newest entry),
  `linux/os/test-vm.sh` (the `daemon` group, before the sandbox check at line 705)

- [ ] **Step 1: Write the record.** BridgeWeb README: a Layout row for `ViewerPairing.swift`, `WebApp+Viewers.swift`, `ViewerAnnouncer.swift`,
  and an entry "Apple TVs (2026-11-02, docs/CONTRACT_CHANGES.md; spec docs/superpowers/specs/2026-11-01-apple-tv-app-design.md)" naming
  every public symbol of Tasks 1 to 6: `AuthStore.ViewerInfo`, `AuthStore.PairingStart`, `AuthStore.PairingStatus`, `AuthStore.PairingFailure`,
  `AuthStore.bridgeID`, `AuthStore.beginPairing`, `AuthStore.approvePairing`, `AuthStore.pairingStatus`, `AuthStore.viewers`,
  `AuthStore.viewer`, `AuthStore.removeViewer`, `AuthStore.isViewerListed`, `WebConfiguration.viewerAdvertiser`,
  `WebConfiguration.viewerRecheckInterval`, with the routes, the access level and the announcement in one paragraph each. BridgeDaemon
  README: `Daemon.viewerAdvertiser(options:environment:)` (internal) and where it announces. CONTRACT_CHANGES row: `| 2026-11-02 | BridgeWeb,
  BridgeDaemon (+ page, Camera Bridge OS) | Apple TVs: pairing codes, viewer keys, GET viewer and _camera-bridge._tcp (BridgeWeb README,
  "Apple TVs"; docs/linux/ARCHITECTURE.md, "Web API" and "Security"; linux/web/README.md; linux/os/README.md; SECURITY.md): <the routes,
  the access level and the announcement in a sentence each>. **Additive API:** <the fourteen symbols above, backticked>. Internal:
  `ViewerPairing`, `ViewerAnnouncer`, `Route.Access.viewer`, `Daemon.viewerAdvertiser`. | The owner's Apple TV app (spec
  docs/superpowers/specs/2026-11-01-apple-tv-app-design.md). | additive |`, with no bare `|` inside a cell (write "or":
  `DocsConsistencyTests` counts cells) and no wording that asks for approval.
  SECURITY.md scope: "the web interface, its sign-in and the Apple TVs' keys"; a bullet: the box keeps only the SHA-256 of a TV's key
  (256 random bits) with its name, model and last use; the key only watches (live and recorded video, stills, events) and moves cameras
  that pan and tilt, is sent in a header and never in an address, stops working after a year unused, and Remove stops it at once.

- [ ] **Step 2: Write the release note** (newest first, exactly):

```js
  {
    version: '0.1.132',
    date: '2026-11-02',
    title: 'Ready for the Apple TV app',
    items: [
      'Settings › Security has an Apple TV card. Enter the code the Camera Bridge app shows on an Apple TV, and that TV can watch every camera, live and recorded, in the camera’s full quality. Each TV is listed with when and where it was last used, and Remove stops it at once.',
      'An Apple TV never needs the password, and it can only watch and move cameras that pan and tilt: it can’t change anything else.',
      'The box tells Apple TVs on your network that it is there, so the app finds it by itself.',
    ],
  },
```

- [ ] **Step 3: Add the VM check.** After the auto-update lines of the `daemon` group, a Python client (`$work/viewer-client.py`, standard
  library, in the style of `api-client.py`: requests without a cookie for the TV, the admin password for the owner) prints one line per
  step; the shell checks each with `ok`/`no`:

```
pair 200 <CODE> 600 2                      ^pair 200 [BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4} 600 2$
waiting 200 waiting
approve 201 VM test TV                     the code sent lower case, with a space for the dash
collect 200 approved 64                    then: again 404 pairing_gone
viewer 200 <32 hex id> <version> <n>       GET /api/v1/viewer with only "Authorization: Bearer <key>"
elsewhere 401 unauthorized                 GET /api/v1/settings with only the key
inaddress 400 token                        GET /api/v1/viewer?token=<key>
removed 204                                then: gone 401 viewer_key
```

  Then the announcement, through avahi on the box (`busctl` is systemd's; the image has no avahi-utils):
  `ssh_run "busctl --json=short call org.freedesktop.Avahi / org.freedesktop.Avahi.Server ResolveService iisssiu -1 -1 'Camera Bridge'
  _camera-bridge._tcp local -1 0"`, read with `python3 -I` on the host (`data[8]` is the port, `data[9]` the TXT as byte arrays):
  `ok "avahi resolves _camera-bridge._tcp on port 80 with the id GET viewer gives, name Camera Bridge, v and api=1"`. The VM sets no
  bridge name, so the instance is "Camera Bridge".

- [ ] **Step 4: Run everything** — `cd K && swift build --build-tests && swift test --skip-build --filter "BridgeWebTests|BridgeDaemonTests|PortabilityTests"`;
  `CB_CPUS=6 sh Tools/linux-test.sh test --filter "BridgeWebTests|BridgeDaemonTests|PortabilityTests"`; `sh linux/web-tests/run.sh`;
  `node linux/web-dev/lint.mjs`; `bash -n linux/os/test-vm.sh` (and `linux/os/test-static.sh` where shellcheck is installed) → all PASS.
  The VM group itself runs with the beta's image (`linux/os/test-vm.sh --image … --tests daemon`, docs/linux/BUILDING.md); building an
  image here is not required (several GB; `build.sh --clean` afterwards if one is built).

- [ ] **Step 5: Commit** — `git commit -m "Apple TVs: the contract record, the security notes, the release note of 0.1.132 and the VM check"`

- [ ] **Step 6: Stop.** Publishing beta 0.1.132 is the owner's call (one beta a day; no push before he says so).

### Task 9: The key picture alone (`keyframe?at=…&picture=1`)

Added by the controller on 2026-11-01 after the app's plan found that `GET nvr/cameras/:id/keyframe` answers the whole key fragment (up to
2.5 s of video, about 5 MB at 4K) when the Apple TV only needs its first picture, for scrubbing and for the 4×–16× speeds. Run it after
Task 7 and before Task 8 (Task 8's release note and records then mention it).

**Files:**
- Modify: `K/Sources/BridgeEngine/NVR/ArchiveMedia.swift` (a sibling of `videoSegment`/`soundSegment`), `K/Sources/BridgeWeb/WebApp+NVRMedia.swift`
  (`nvrKeyframe`), `docs/linux/ARCHITECTURE.md` (the keyframe row), `K/Sources/BridgeWeb/README.md` (if it lists the route's parameters),
  `linux/web/js/nvr/thumbs.js` (where the page only shows the first picture)
- Test: the existing ArchiveMedia tests file (add cases) and the existing NVR media route tests (add cases); the web test that covers thumbs.js

**Interfaces:**
- Produces: `package static func keyPictureSegment(_ fragment: Data) throws -> Data` in `ArchiveMedia`: the fragment's `moof` + `mdat` with the
  video track's first sample only (no `prft`, no sound): `trun` sample count 1 with only that sample's entry (size, flags, composition offset,
  duration as the original run carries them), `trun` data offset and `mdat` size rewritten to match. Throws `malformed` when the first video
  sample is not a sync sample (the caller only hands it key fragments).
- The contract shared with the app: `GET /api/v1/nvr/cameras/:id/keyframe?at=<ms>&picture=1` answers exactly as without `picture` (status,
  `video/mp4`, `X-CB-Part`, the 404 `gap` with `X-CB-Next`, every limit), except that the body is `keyPictureSegment` of the key fragment and
  `X-CB-Part.end` is the key picture's own end (start + its duration, ms). `picture=0` or absent: today's answer, byte for byte. Any other
  value: `400 invalid`, field `picture`. A viewer key may use it (the route is already a viewer route after Task 5).

- [ ] **Step 1: Write the failing tests**
  - ArchiveMedia: `keyPictureSegmentKeepsOnlyTheFirstPicture` (a fragment of several frames from the existing test helpers: the result parses,
    has one `traf` for the video track, `trun` sample count 1, `mdat` payload equal to the first sample's bytes, and the `trun` data offset
    points at it); `keyPictureSegmentDropsSoundAndPrft` (a fragment with sound and a `prft`: neither survives); `keyPictureSegmentRefusesANonKeyStart`.
  - Route: `aKeyPictureAnswerHoldsOneFrame` (same `X-CB-Part` keys; `end` = start + one frame; body smaller than without `picture`);
    `withoutPictureTheKeyFragmentIsUnchanged` (byte-for-byte equal to today's answer); `pictureMustBeZeroOrOne` (400, field `picture`).
- [ ] **Step 2: Run them to see them fail** (Mac: `cd K && swift build --build-tests && swift test --skip-build --filter "<the suites>"`).
- [ ] **Step 3: Implement** `keyPictureSegment` by reusing `ArchiveMedia`'s own box and `TrackRun` parsing (as `soundSegment` does), and the
  `picture` parameter in `nvrKeyframe`.
- [ ] **Step 4: The page.** Where `linux/web/js/nvr/thumbs.js` only decodes the key fragment's first picture, ask with `&picture=1`. Leave any
  caller that plays on from the key fragment as it is. Update or add the web test; run `sh linux/web-tests/run.sh` and `node linux/web-dev/lint.mjs`.
- [ ] **Step 5: Run** the suites on Mac and on Linux (`CB_CPUS=6 sh Tools/linux-test.sh test --filter "<the suites>"`), all passing.
- [ ] **Step 6: Commit** ("The key picture alone: keyframe?at=…&picture=1 answers one frame instead of the whole key fragment", with the
  Co-Authored-By line).
