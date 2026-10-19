# AI Event Descriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 1 of AI event descriptions on Camera Bridge OS: for each event on a camera with the switch on, the box sends up to five
small stills from around the event to the provider the owner set up (Claude, or any OpenAI-compatible service), stores one brief
description with the event, and shows it on the Monitor's activity list and the camera page.

**Architecture:** A new `BridgeEngine/AI/` area holds the pure parts (description type, prompt, two provider clients over an injectable
transport) and an `EventDescriber` actor (queue of width 1, per-camera and daily limits). The archive event log hands out the ids of the
events it starts, so the describer can append a description line to the same day file; the events API carries it to the page. Settings
hold the provider choice; the key lives only in the platform secret store.

**Tech Stack:** Swift 6.4 / Swift Testing (Packages/CameraBridgeKit), FoundationNetworking URLSession via `AuthenticatingHTTPClient`,
ffmpeg JPEG encoding through the existing snapshot decoders, vanilla JS web page (`linux/web`), Node's test runner (`linux/web-tests`).

**Spec:** `docs/superpowers/specs/2026-10-18-ai-event-descriptions-design.md` (the owner opted out of further questions, 2026-10-18).

## Global Constraints

- Opt-in: off by default for the bridge (no provider) and per camera (`aiDescriptions == false`). Nothing else depends on it; recording,
  live view, Apple Home and the Internet guard behave the same with it off, failing or slow.
- The API key is write-only: stored only in the platform `SecretStore` as account `ai.key`; never in `config.json`, any API answer (only
  `keySaved` and the last 4 characters as `keyHint`), logs, diagnostics, errors or exports.
- Description: `summary` at most about 12 words asked of the model; stored and shown at most **140 characters** (cut at a word, "…").
  `kind` ∈ `person, vehicle, animal, delivery, other, nothing`; `concern` ∈ `routine, unusual, alarm`. "nothing" shows as "Nothing notable".
- Pictures: at most **5** per event (up to 2 before, the event picture, up to 2 after), JPEG at most **768 px** wide, quality **0.7**, the
  camera's original (not straightened) picture.
- Limits: one description per camera per **60 s**; queue width **1**; a waiting event older than **60 s** is dropped; daily limit default
  **200** (1…5000), counted in the bridge's time zone and kept across restarts; request timeout **20 s**, one retry on network error or 5xx,
  none on 4xx.
- Defaults: Claude model `claude-haiku-5-5` at `https://api.anthropic.com/v1/messages` (`anthropic-version: 2023-06-01`, `max_tokens` 200);
  OpenAI-compatible needs an address (`…/v1`) and a model name; the key may be empty for a home server (no `Authorization` header then).
- Triggering kinds: "Motion", "Person", "Vehicle", "Animal", "Package", "Face", "Doorbell ring"; of several that start together on one
  camera, the most specific gets the description (Person > Package > Vehicle > Animal > Face > Doorbell ring > Motion).
- Exact copy: card titles **AI descriptions**; the camera switch **Describe events with AI**; the Settings sentence "For each event on a
  camera with AI descriptions on, up to five still pictures from around the event are sent to the service you choose. No video, no sound,
  nothing else."
- Tests use 192.168.77.x / 192.0.2.x addresses and fake keys like `sk-test-0000`; never a real key. The owner types real keys himself.
- Swift tests: `swift test --filter <Suite>` in `Packages/CameraBridgeKit`; Linux: `sh Tools/linux-test.sh test --filter <Suite>`; web:
  `sh linux/web-tests/run.sh`. Nothing is published or released without the owner's yes.

## Review Focus

1. **A key that leaks through an error.** A provider answers 401 with a body that echoes the key or the `Authorization` header: the stored
   error, logs and `GET settings` must show "The key was refused" and never the key. Test in Task 1 (`errorsNeverCarryTheKey`) and Task 3
   (`settingsNeverReturnTheKey`).
2. **The provider is slow or down during a burst.** Ten cameras fire at once while every request times out: the queue never grows past
   what 60 s allows, stale events are dropped, recording keeps going. Test in Task 5 (`aStalledProviderDropsStaleEventsAndNeverBlocks`).
3. **The model answers badly.** Prose instead of JSON, JSON in a code fence, a 400-word summary, an unknown kind: parse leniently, cap
   the summary, unknown kind → other, unknown concern → routine; pure garbage → no description and one recorded failure. Test in Task 1
   (`lenientParsing`).
4. **Midnight, restarts and time zones.** The daily count resets at the bridge's local midnight (including a DST day) and survives a
   restart. Test in Task 5 (`theDailyCountResetsAtLocalMidnightAndSurvivesRestart`).
5. **No place for recordings, or a camera that streams on demand.** Without a recordings folder no event is kept, so nothing is described
   and the card says why; an on-demand camera with an empty ring sends only the event and after pictures. Tests in Task 4
   (`anEmptyRingGivesOnlyEventAndAfterPictures`) and Task 5 (`withoutARecordingsFolderNothingIsDescribed`).

---

### Task 1: The description, the prompt and the two provider clients

**Files:**
- Create: `K/Sources/BridgeEngine/AI/EventDescription.swift`, `K/Sources/BridgeEngine/AI/DescriptionPrompt.swift`,
  `K/Sources/BridgeEngine/AI/AIProviders.swift` (protocol, transport, errors), `K/Sources/BridgeEngine/AI/AnthropicVision.swift`,
  `K/Sources/BridgeEngine/AI/OpenAICompatibleVision.swift`
- Test: `K/Tests/BridgeEngineTests/AIProviderTests.swift`
(`K` = `Packages/CameraBridgeKit`.)

**Interfaces:**
- Produces:
  - `public struct EventDescription: Codable, Sendable, Equatable { var summary: String; var kind: Kind; var concern: Concern; var model: String; var at: Date }`
    with `enum Kind: String, Codable { person, vehicle, animal, delivery, other, nothing }`, `enum Concern: String, Codable { routine, unusual, alarm }`;
    `static func parse(_ text: String, model: String, at: Date) -> EventDescription?` (lenient: the first `{…}` object anywhere in the
    text; summary trimmed, first line only, capped at 140 characters at a word with "…"; unknown kind → `.other`; unknown concern →
    `.routine`; kind `.nothing` → summary "Nothing notable"; nil when there is no summary).
  - `struct LabeledPicture: Sendable, Equatable { var label: String; var jpeg: Data }` and
    `struct DescriptionRequest: Sendable { var cameraName: String; var eventKind: String; var localTime: String; var pictures: [LabeledPicture] }`.
  - `protocol AIVisionDescribing: Sendable { var model: String { get }; func describe(_ request: DescriptionRequest) async throws -> EventDescription }`.
  - `protocol AITransport: Sendable { func send(_ request: URLRequest) async throws -> (body: Data, status: Int) }` and
    `final class URLSessionAITransport: AITransport` (one `AuthenticatingHTTPClient` with no credentials, timeout 20 s, 1 MiB body cap,
    kept for the process's life like `URLSessionWyzeTransport`).
  - `enum AIProviderError: Error, Equatable { keyRefused, notAllowed, rateLimited, unreachable, serviceFailed(Int), badAnswer }` with
    `var sentence: String` (plain words: "The key was refused.", "The service could not be reached.", …), never containing request data.
  - `struct AnthropicVision: AIVisionDescribing` (`init(key: String, model: String = "claude-haiku-5-5", transport: any AITransport)`) and
    `struct OpenAICompatibleVision: AIVisionDescribing` (`init(baseURL: URL, key: String?, model: String, transport: any AITransport)`).
  - `enum DescriptionPrompt { static let system: String; static func userText(_ request: DescriptionRequest) -> String }`.

- [ ] **Step 1: Write the failing tests** (a fake transport records the `URLRequest` and answers canned bodies):

```swift
@Test func anthropicRequestShape()   // POST https://api.anthropic.com/v1/messages; headers x-api-key "sk-test-0000", anthropic-version
    // "2023-06-01", content-type json; body: model "claude-haiku-5-5", max_tokens 200, system == DescriptionPrompt.system, one user
    // message whose content alternates text labels and base64 image/jpeg blocks in the pictures' order, then userText; a tool
    // "describe_event" with summary/kind/concern (kind and concern enums as above) and tool_choice {type: tool, name: describe_event}
@Test func anthropicAnswerIsParsed()   // content [{type: tool_use, input: {summary, kind: "delivery", concern: "routine"}}] → that description, model, at
@Test func openAIRequestShape()   // POST <base>/chat/completions; Authorization "Bearer sk-test-0000" (absent when key nil or empty);
    // messages [system, user with text + image_url "data:image/jpeg;base64,…" parts]; max_tokens 200
@Test func openAIAnswerIsParsed()   // choices[0].message.content "```json\n{…}\n```" → parsed
@Test func statusesMapToErrors()   // 401 → keyRefused, 403 → notAllowed, 429 → rateLimited, 500/529 → serviceFailed(code), URLError → unreachable
@Test func errorsNeverCarryTheKey()   // a 401 body echoing "sk-test-0000" and "Authorization: Bearer sk-test-0000": the thrown error's
    // sentence and String(describing:) contain neither
@Test func lenientParsing() {
    // prose around a JSON object → parsed; a 400-word summary → ≤ 140 chars ending "…" at a word; kind "burglar" → .other;
    // concern "high" → .routine; kind "nothing" → summary "Nothing notable"; "I cannot help with that" → nil
}
@Test func thePromptAsksForBriefPlainSentences() {
    // DescriptionPrompt.system contains "at most 12 words", "Never guess who someone is", "Nothing notable"; userText names the camera,
    // the reported kind and the local time
}
```

- [ ] **Step 2: Run them to see them fail** — `swift test --filter AIProviderTests` → FAIL (types missing).

- [ ] **Step 3: Implement.** `DescriptionPrompt.system` is exactly:

```
You describe security camera events for a home owner. You get a few still pictures from one camera, in time order, around the moment an
event began. Answer with one short sentence of at most 12 words, present tense, saying what is happening: who or what, and what they are
doing. Be plain and specific. Never guess who someone is and never describe faces in detail: say "a person", "a man in a red jacket",
"a delivery driver". If nothing worth noting is visible (shadows, trees or plants moving, rain, insects, headlights), use kind "nothing"
and summary "Nothing notable". Concern: "alarm" for a likely break-in or forced entry, a weapon, a masked or covered face at a door or
window, someone trying door or window handles, or someone tampering with the camera; "unusual" for someone lingering, looking into
windows or cars, or anyone near doors at night; otherwise "routine".
```

`userText` is "Camera: <name>. The camera reported: <kind>. Local time: <time>." OpenAI-compatible asks for "Reply with only a JSON
object with keys summary, kind and concern." appended to the system text. One retry on `unreachable` or `serviceFailed` lives in the
describer (Task 5), not here.

- [ ] **Step 4: Run the tests** — `swift test --filter AIProviderTests` → PASS; `sh Tools/linux-test.sh test --filter AIProviderTests` → PASS.

- [ ] **Step 5: Commit** (`git commit -m "AI descriptions: the description, the prompt, Claude and OpenAI-compatible clients"`)

---

### Task 2: Event ids out of the event log, descriptions stored and read

**Files:**
- Modify: `K/Sources/BridgeEngine/NVR/ArchiveEventLog.swift` (`Line` near line 31, `Stored` near 41, `record` near 99, `parse` near 299,
  the store and coordinator `recordEvents` near 399 and 495)
- Modify: `K/Sources/BridgeEngine/NVR/ArchiveReading.swift` (`ArchiveEvent` near line 37), `K/Sources/BridgeEngine/BridgeEngine.swift`
  (edge handler near line 1597), `K/Sources/BridgeWeb/WebApp+NVRCatalog.swift` (`EventResource` near line 95)
- Test: `K/Tests/BridgeEngineTests/ArchiveEventLogTests.swift`, `K/Tests/BridgeWebTests/ArchiveEventsRouteTests.swift`

**Interfaces:**
- Consumes: `EventDescription` (Task 1).
- Produces: `struct StartedEvent: Sendable, Equatable { var cameraID: UUID; var kind: String; var id: String; var date: Date }`;
  `ArchiveEventLog.record(...) -> [StartedEvent]` (one per began edge that was kept); `ArchiveStore.recordEvents(...) -> [StartedEvent]`,
  `NVRCoordinator.recordEvents(_:) -> [StartedEvent]`; `NVRCoordinator.recordDescription(_ description: EventDescription, for event: StartedEvent)`
  (appends `{"v":1,"id":"…","ai":{…}}` to the day file of `event.date`, through the same pending queue); `Line.ai: EventDescription?`;
  `Stored.description` and `public var ArchiveEvent.description: EventDescription?` (the last description line of that id wins);
  `EventResource.description: OrNull<DescriptionResource>` with `{summary, kind, concern}`. The engine's edge handler keeps the
  started events for Task 5 (`let started = nvr.recordEvents(edges)`; Task 5 hands them to the describer).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func recordHandsOutTheIdsOfTheEventsItStarts()   // two began edges, one end edge → two StartedEvents with the ids written
@Test func withoutAFolderNothingStartsAndNoIdIsHandedOut()   // folder nil → []
@Test func aDescriptionLineIsReadWithItsEvent()   // start, description, end lines → Stored.description == that description; a second
    // description line for the same id replaces it; a description for an unknown id is ignored; an old reader's Line without ai still parses
@Test func theEventsRouteCarriesTheDescription()   // GET nvr/events → description {summary, kind, concern} or null
```

- [ ] **Step 2: Run them to see them fail** — `swift test --filter "ArchiveEventLogTests|ArchiveEventsRouteTests"` → FAIL.

- [ ] **Step 3: Implement** as in Interfaces (the description line's day is `dayName(ms:)` of the event's start, so retention removes it
  with its event).

- [ ] **Step 4: Run the tests** (same filter, then `swift test --filter "BridgeEngineTests|BridgeWebTests"` once) → PASS.

- [ ] **Step 5: Commit** (`git commit -m "AI descriptions: the event log hands out event ids and keeps descriptions with their events"`)

---

### Task 3: Settings, the key, the camera switch and their API

**Files:**
- Create: `K/Sources/BridgeEngine/AI/AIDescriptionSettings.swift`, `K/Sources/BridgeWeb/WebApp+AI.swift`
- Modify: `K/Sources/BridgeEngine/Configuration/Configuration.swift` (`BridgeSettings` near line 249: property, init, CodingKeys, lenient
  decode; `CameraConfiguration` property, CodingKeys, decode), `K/Sources/BridgeEngine/BridgeEngine.swift` (`needsRestart` near 2615,
  `validate` near 2568, key methods next to `pluginSecret` near 700), `K/Sources/BridgeWeb/WebApp+Bridge.swift` (`SettingsPatch`),
  `K/Sources/BridgeWeb/Resources.swift` (`SettingsResource`), `K/Sources/BridgeWeb/WebApp+Routes.swift` (`CameraPatch`, routes),
  `K/Sources/BridgeWeb/BridgeBackend.swift` (+ `Sources/BridgeDaemon/NoArchiveBackend.swift`, `Daemon.swift` `DemoDiscoveryBackend`,
  test fakes `Tests/BridgeWebTests/Support.swift`, `NVRTestRig.swift`)
- Test: `K/Tests/BridgeEngineTests/AISettingsTests.swift`, `K/Tests/BridgeWebTests/AIAPITests.swift`

**Interfaces:**
- Produces:
  - `public struct AIDescriptionSettings: Codable, Sendable, Equatable { var provider: AIProviderKind?; var model: String; var baseURL: String?; var dailyLimit: Int }`,
    `public enum AIProviderKind: String, Codable { anthropic, openAICompatible }`; defaults `provider nil`, `model "claude-haiku-5-5"`,
    `baseURL nil`, `dailyLimit 200`; lenient decode; `BridgeSettings.ai: AIDescriptionSettings`.
  - `CameraConfiguration.aiDescriptions: Bool` (default false; `needsRestart` ignores it).
  - `BridgeEngine.setAIKey(_ key: String?) throws` (nil or "" deletes; stored as `Data(key.utf8)` at account `ai.key`),
    `BridgeEngine.aiKey() throws -> String?` (internal to the engine and the describer), `public BridgeEngine.aiKeyHint: String?`
    (last 4 characters, or nil).
  - Validation: `provider == .openAICompatible` needs `baseURL` with scheme http or https and a host; `dailyLimit` 1…5000; model 1…100
    printable characters.
  - API: `GET settings` gains `ai: {provider, model, baseURL, dailyLimit, keySaved, keyHint}` (no key); `PATCH settings` takes
    `ai: {provider (string or null), model, baseURL, dailyLimit}`; `PUT ai/key {key}` (1…500 characters, 204) and `DELETE ai/key` (204);
    `PATCH cameras/:id {aiDescriptions: bool}`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func defaultsAreOffAndAConfigWithoutAILoads()
@Test func validationRefusesABadAddressAndLimits()   // openAICompatible without baseURL, "ftp://…", dailyLimit 0 and 5001 → 400 with field
@Test func theKeyIsWriteOnly()   // PUT ai/key "sk-test-0000" → 204; secret store holds it at "ai.key"; config.json does not contain it
@Test func settingsNeverReturnTheKey()   // GET settings → ai.keySaved true, ai.keyHint "0000", body contains no "sk-test"
@Test func deletingTheKeyClearsIt()
@Test func theCameraSwitchSavesWithoutARestart()   // PATCH aiDescriptions true → saved; needsRestart false both ways
```

- [ ] **Step 2: Run them to see them fail** — `swift test --filter "AISettingsTests|AIAPITests"` → FAIL.

- [ ] **Step 3: Implement** as in Interfaces, modelled on `pluginSecret`/`setPluginSecret` and the Task-2-of-straightening
  `pictureCorrection` field pattern. Add the CONTRACT_CHANGES row (2026-10-18) and the README "Additions beyond the contract" names
  (`DocsConsistencyTests` checks them).

- [ ] **Step 4: Run the tests** (filter above, then `swift test --filter "BridgeWebTests|PortabilityTests"`) → PASS.

- [ ] **Step 5: Commit** (`git commit -m "AI descriptions: provider settings, a write-only key and the camera switch"`)

---

### Task 4: Pictures from around the event

**Files:**
- Create: `K/Sources/BridgeEngine/AI/EventPictures.swift`
- Modify: `K/Sources/MediaCore/MediaHub.swift` (a read-only accessor), `K/Sources/BridgeEngine/Runtime/CameraRuntime.swift`
- Test: `K/Tests/MediaCoreTests/MediaHubTests.swift`, `K/Tests/BridgeEngineTests/EventPicturesTests.swift`

**Interfaces:**
- Consumes: `LabeledPicture` (Task 1).
- Produces: `MediaHub.recentKeyframes() -> [EncodedVideoFrame]` (every keyframe the ring holds, oldest first; no subscription, no state
  change); `CameraRuntime.eventPictures(at date: Date) async -> [LabeledPicture]` (labels "4 s before", "2 s before", "At the event",
  "2 s after", "4 s after"; before = the held keyframes whose `wallClock` is closest to date − 4 s and date − 2 s, each at most once and
  only if earlier than `date`; event = the snapshot path with reason `.event`; after = the first keyframes at or past date + 2 s and
  date + 4 s, waited for at most 6 s in all; every picture through the snapshot decoders at `maxWidth` 768, quality 0.7, original picture).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func recentKeyframesListsTheRingsKeyframesOldestFirst()   // 3 GOPs pushed → 3 keyframes in order; the ring is unchanged
@Test func picturesAroundAnEventAreLabelledInTimeOrder()   // fake codecs and a hub fed with keyframes at t−5…t+5 s → 5 pictures,
    // labels in order, each ≤ 768 wide (fake JPEG records the requested size)
@Test func anEmptyRingGivesOnlyEventAndAfterPictures()   // on-demand camera: no before pictures, no wait beyond 6 s
@Test func aCameraThatStopsSendingStillAnswersWithinSixSeconds()   // no keyframes after the event → event picture only, ≤ 6.5 s
```

- [ ] **Step 2: Run them to see them fail** — `swift test --filter "MediaHubTests|EventPicturesTests"` → FAIL.

- [ ] **Step 3: Implement** with the existing `SnapshotDecoderPool.jpeg(fromKeyframe:maxWidth:maxHeight:)` and the `SnapshotProvider`
  event snapshot (add a `maxWidth` path or resize the event JPEG with `codecs.resizeJPEG`); the blocking ffmpeg calls run off the
  cooperative pool the way the snapshot path already runs them.

- [ ] **Step 4: Run the tests** (filter above; then `sh Tools/linux-test.sh test --filter "EventPicturesTests"`) → PASS.

- [ ] **Step 5: Commit** (`git commit -m "AI descriptions: up to five stills from around an event"`)

---

### Task 5: The describer (queue, limits, wiring, Try it)

**Files:**
- Create: `K/Sources/BridgeEngine/AI/EventDescriber.swift`, `K/Sources/BridgeEngine/AI/AIUsage.swift`
- Modify: `K/Sources/BridgeEngine/BridgeEngine.swift` (start/stop with `startServices`/`stopServices`, the edge handler),
  `K/Sources/BridgeEngine/EngineTuning.swift` (injectable transport and clock for tests), `K/Sources/BridgeWeb/WebApp+AI.swift`
  (`POST ai/try`), `GET settings` `ai` gains usage and the last error
- Test: `K/Tests/BridgeEngineTests/EventDescriberTests.swift`, `K/Tests/BridgeWebTests/AIAPITests.swift`

**Interfaces:**
- Consumes: Tasks 1–4 (`AIVisionDescribing`, `StartedEvent`, `recordDescription`, `AIDescriptionSettings`, `aiKey()`, `eventPictures(at:)`).
- Produces: `actor EventDescriber` with `nonisolated func eventsStarted(_ events: [StartedEvent])` (cheap enqueue, called from the edge
  handler), `func tryNow(cameraID: UUID) async throws -> EventDescription` (no storing, counts toward the day), `var status: AIStatus`
  (`today`, `last7Days`, `limitReached`, `lastError: String?`, `lastErrorAt: Date?`); `AIUsage` persisted at
  `<data>/ai/usage.json` (0600; per-day counts of the last 8 days by local day name in the bridge's time zone);
  `POST ai/try {cameraID}` → `{summary, kind, concern, seconds}` or `{error: sentence}` with 502.
- Rules: Global Constraints' limits and kind order; a camera whose switch is off, with no provider, or with the limit reached is skipped
  without work; `keyRefused` pauses describing until the key or provider changes (one `lastError`, no banner); the other failures are
  recorded in `lastError` and the event stays undescribed.

- [ ] **Step 1: Write the failing tests** (fake provider, fake pictures, manual clock):

```swift
@Test func aPersonEventGetsOneDescriptionStoredWithIt()
@Test func ofSimultaneousStartsTheMostSpecificIsDescribed()   // Motion + Person at one date → one description, on Person
@Test func oneDescriptionPerCameraPerMinute()
@Test func camerasWithTheSwitchOffSendNothing()   // provider never called, no pictures taken
@Test func aStalledProviderDropsStaleEventsAndNeverBlocks()   // 10 cameras fire while every call hangs 30 s: at most one in flight,
    // waiting events older than 60 s dropped, eventsStarted returns at once every time
@Test func theDailyCountResetsAtLocalMidnightAndSurvivesRestart()   // limit 2: third skipped; after local midnight (a DST day in
    // America/Los_Angeles) counting starts again; a new describer reading the same usage file sees today's count
@Test func aRefusedKeyPausesUntilTheKeyChanges()
@Test func withoutARecordingsFolderNothingIsDescribed()   // no StartedEvents → no calls; status says so for the card
@Test func tryNowAnswersWithoutStoring()
```

- [ ] **Step 2: Run them to see them fail** — `swift test --filter "EventDescriberTests|AIAPITests"` → FAIL.

- [ ] **Step 3: Implement** as in Interfaces; the engine builds the provider from settings and `aiKey()` on each change (Anthropic or
  OpenAI-compatible with `URLSessionAITransport`), and hands `started` events from the edge handler to `eventsStarted`.

- [ ] **Step 4: Run the tests** (filter above, then `swift test --filter BridgeEngineTests` once and the Linux run of the two suites) → PASS.

- [ ] **Step 5: Commit** (`git commit -m "AI descriptions: the describer with its limits, wired to events, and Try it"`)

---

### Task 6: The Settings card

**Files:**
- Modify: `linux/web/js/screens/settings.js` (a card in a new "AI" section, before "Troubleshooting"), `linux/web/style.css`
- Create: `linux/web-tests/ai-settings.test.mjs` (a pure `aiSettingsView(settings)` helper exported for the test, or the card's module)

**Interfaces:** Consumes the API of Tasks 3 and 5.

- [ ] **Step 1: Write the failing tests**

```js
test('the card shows provider, model, limit and only the key hint', () => { /* ai.keySaved true, keyHint "0000" → "Key saved (…0000)",
  no input value holds a key; Replace and Remove buttons */ });
test('saving a key sends it once and clears the field', () => { /* PUT ai/key {key}; the input is empty afterwards */ });
test('OpenAI-compatible shows the address field; Claude does not', () => {});
test('Try it shows the sentence, the seconds, or the error sentence', () => {});
test('the card says exactly what leaves the box', () => { /* the Global Constraints sentence verbatim */ });
```

- [ ] **Step 2: Run them to see them fail** — `sh linux/web-tests/run.sh --test-name-pattern="card|key|Try"` → FAIL.

- [ ] **Step 3: Implement** with the page's `field`, `selectField`, `switchRow` and the password-card pattern (`type=password`,
  `autocomplete=off`, cleared after a save); counts "Today: N of LIMIT · last 7 days: M"; the last error with its time.

- [ ] **Step 4: Run all web tests** (`sh linux/web-tests/run.sh`) → PASS; check it in the browser (`bridge-preview`) with a fake key.

- [ ] **Step 5: Commit** (`git commit -m "AI descriptions: the Settings card"`)

---

### Task 7: The camera card and the Monitor's activity list

**Files:**
- Modify: `linux/web/js/screens/camera.js` (a card next to `motionCard()`), `linux/web/js/screens/wall-events-model.js` (`gatherEvents`
  near line 47: carry `description`; the merge keeps it), `linux/web/js/screens/wall-events.js` (`rowFor` near line 102 and the `draw`
  signature near line 120), `linux/web/monitor.css`
- Test: `linux/web-tests/monitor-events.test.mjs`, a camera-card test

**Interfaces:** Consumes `EventResource.description` (Task 2), `aiDescriptions` (Task 3), `ai` status (Task 5).

- [ ] **Step 1: Write the failing tests**

```js
test('gatherEvents keeps a description and a merge does not lose it', () => {});
test('a row shows the summary under the kind; alarm red, unusual amber, nothing dimmed', () => {});
test('a description that arrives later updates the row in place', () => { /* refresh with the same id → row text changes, no new row */ });
test('the camera card switch is disabled with a link to Settings until a provider is set', () => {});
```

- [ ] **Step 2: Run them to see them fail** (`sh linux/web-tests/run.sh --test-name-pattern="description|AI"`) → FAIL.

- [ ] **Step 3: Implement** (summary text with `textContent` only; `data-concern` attribute for the colour; the camera card shows the
  camera's last description from the newest events page it already loads, or "No description yet").

- [ ] **Step 4: Run all web tests** → PASS; check the Monitor in the browser (`bridge-preview`, a fake provider via the dev tuning if
  available, else a stored description line in a test archive).

- [ ] **Step 5: Commit** (`git commit -m "AI descriptions: the camera card and descriptions on the Monitor's activity list"`)

---

### Task 8: Docs, release notes, and the check on the box

**Files:**
- Modify: `docs/linux/ARCHITECTURE.md` (security section, outbound calls), `SECURITY.md` (what leaves the box), `docs/linux/USER-GUIDE.md`
  (a short "AI descriptions" section), `linux/web/js/release-notes.js` (entry for the next build), module READMEs if Tasks 3/5 left any.

- [ ] **Step 1: Write the docs** (outbound calls: "the AI service you choose, only for cameras with AI descriptions on, and only still
  pictures"); release note in the owner's plain style.
- [ ] **Step 2: Run everything** — `swift test`, `sh Tools/linux-test.sh test`, `sh linux/web-tests/run.sh` → PASS.
- [ ] **Step 3: Commit** (`git commit -m "AI descriptions: docs and release notes"`)
- [ ] **Step 4: Ask the owner** before publishing. After his yes and the box update, he types his own Claude key in Settings, turns the
  switch on for one camera, uses "Try it", walks past the camera, and checks the description on the Monitor.
