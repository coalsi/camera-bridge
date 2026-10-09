import BridgeEngine
import CameraAdapters
import Foundation
import Testing

/// The engine side of the camera detail form: stores what an update applies, can fail or hold an update in flight.
final class FakeCameraEngine {
    var configuration: CameraConfiguration?
    var failUpdates = false
    /// While set, updates wait here (ignoring cancellation) before they apply.
    var hold: Gate?
    /// Applied to each accepted update, like engine-side normalisation.
    var normalize: (inout CameraConfiguration) -> Void = { _ in }
    private(set) var updates: [(configuration: CameraConfiguration, password: String?)] = []
    /// Failures the app showed as an alert (`showsFailure`).
    private(set) var alerts = 0

    init(_ configuration: CameraConfiguration) {
        self.configuration = configuration
    }

    func apply(_ update: CameraConfiguration, password: String?, showsFailure: Bool) async throws {
        updates.append((update, password))
        if let hold { await hold.wait() }
        guard !failUpdates else {
            if showsFailure { alerts += 1 }
            throw FakeError.unreachable
        }
        var stored = update
        normalize(&stored)
        configuration = stored
    }

    /// A long quiet period by default, so only explicit `applyPendingEdits()` calls reach the engine.
    func editor(quietPeriod: Duration = .seconds(30)) -> CameraEditor {
        CameraEditor(configuration: configuration ?? CameraEditorTests.sample, quietPeriod: quietPeriod,
                     apply: { [self] in try await apply($0, password: $1, showsFailure: $2) }, current: { [self] in configuration })
    }
}

@Suite(.timeLimit(.minutes(1))) struct CameraEditorTests {
    static let sample: CameraConfiguration = {
        var config = CameraConfiguration(id: UUID(uuidString: "CB000000-0000-4000-8000-000000000001") ?? UUID(), name: "Driveway",
                                         kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.21"), username: "admin")
        config.capabilities = CameraCapabilities(events: [.motion, .person, .vehicle], twoWayAudio: true)
        return config
    }()

    /// Review finding (W4 round 2): switching Motion Source away from Webhook hid the Person/Vehicle/Animal/Package
    /// toggles but kept them on (saved, unpublished, listed on the Sensors Bridge page, back without asking later).
    @Test func choosingAMotionSourceTurnsOffTheSensorsItHides() async {
        var camera = Self.sample
        camera.motionSource = .webhook
        camera.sensors.person = true
        camera.sensors.package = true
        let engine = FakeCameraEngine(camera)
        let editor = engine.editor()
        editor.chooseMotionSource(.cameraEvents)
        #expect(editor.draft.motionSource == .cameraEvents)
        #expect(editor.draft.sensors.person, "the camera reports people itself")
        #expect(!editor.draft.sensors.package, "packages came from the webhook only")
        await editor.applyPendingEdits()
        #expect(engine.configuration?.sensors.package == false && engine.configuration?.motionSource == .cameraEvents)
    }

    @Test func editsApplyAfterTheQuietPeriod() async {
        let engine = FakeCameraEngine(Self.sample)
        let editor = engine.editor(quietPeriod: .milliseconds(20))
        editor.draft.motionSensitivity = 0.8
        #expect(editor.hasUnsavedEdits && engine.updates.isEmpty)
        await eventually { !engine.updates.isEmpty && !editor.hasUnsavedEdits }
        #expect(engine.updates.count == 1 && engine.updates[0].configuration.motionSensitivity == 0.8)
        #expect(editor.base.motionSensitivity == 0.8 && !editor.hasUnsavedEdits)
    }

    /// Typing continues while the first update is in flight; its echo must not revert the newer characters.
    @Test func theEchoOfAnEarlierUpdateKeepsNewerEdits() async {
        let engine = FakeCameraEngine(Self.sample)
        let editor = engine.editor()
        let hold = Gate()
        engine.hold = hold
        editor.draft.name = "Drive"
        let first = Task { await editor.applyPendingEdits() }
        await settle(until: { engine.updates.count == 1 })
        editor.draft.name = "Driveway North"
        hold.open()
        await first.value
        #expect(engine.configuration?.name == "Drive")
        editor.engineDidPublish(engine.configuration ?? Self.sample)   // the view's onChange
        #expect(editor.draft.name == "Driveway North" && editor.base.name == "Drive" && editor.hasUnsavedEdits)
        engine.hold = nil
        await editor.applyPendingEdits()
        #expect(engine.configuration?.name == "Driveway North" && !editor.hasUnsavedEdits)
    }

    /// An unrelated engine change is taken in without dropping a toggle flipped moments ago.
    @Test func engineChangesMergeFieldByField() {
        let engine = FakeCameraEngine(Self.sample)
        let editor = engine.editor()
        editor.draft.sensors.person = true
        editor.draft.audioEnabled = false
        var published = Self.sample
        published.firmware = "V5.8.0"
        published.sensors.vehicle = true
        published.motionHoldSeconds = 30
        editor.engineDidPublish(published)
        #expect(editor.draft.sensors.person && editor.draft.sensors.vehicle && !editor.draft.audioEnabled)
        #expect(editor.draft.firmware == "V5.8.0" && editor.draft.motionHoldSeconds == 30)
        #expect(editor.base == published && editor.hasUnsavedEdits)

        let merged = CameraEditor.merge(base: Self.sample, edited: editor.draft, latest: Self.sample)
        #expect(merged.sensors.person && !merged.audioEnabled && merged.firmware == Self.sample.firmware)
    }

    /// docs/CONTRACT_CHANGES.md 2026-10-01: the Streams section's picker edits must survive an unrelated engine
    /// publish during the quiet period, exactly like the other editable fields.
    @Test func streamAndQualityEditsSurviveAnUnrelatedEnginePublish() {
        let engine = FakeCameraEngine(Self.sample)
        let editor = engine.editor()
        editor.draft.liveStreamMode = .alwaysSub
        editor.draft.liveQualityMode = .originalQuality
        editor.draft.recordingStreamMode = .sub
        var published = Self.sample
        published.firmware = "V5.9.0"
        editor.engineDidPublish(published)
        #expect(editor.draft.liveStreamMode == .alwaysSub && editor.draft.liveQualityMode == .originalQuality)
        #expect(editor.draft.recordingStreamMode == .sub && editor.draft.firmware == "V5.9.0")
    }

    @Test func withoutEditsTheDraftFollowsTheEngine() {
        let engine = FakeCameraEngine(Self.sample)
        let editor = engine.editor()
        var published = Self.sample
        published.name = "Renamed Elsewhere"
        published.isEnabled = false
        editor.engineDidPublish(published)
        #expect(editor.draft == published && !editor.hasUnsavedEdits)
    }

    @Test func aFailedUpdateRevertsToTheEngineValues() async {
        let engine = FakeCameraEngine(Self.sample)
        engine.failUpdates = true
        let editor = engine.editor()
        editor.draft.twoWayAudio = true
        editor.draft.motionHoldSeconds = 60
        await editor.applyPendingEdits()
        #expect(engine.updates.count == 1)
        #expect(editor.draft == Self.sample && !editor.hasUnsavedEdits)
    }

    /// Edits made while a failing update was in flight get their own attempt instead of being reverted.
    @Test func editsMadeDuringAFailedUpdateAreKept() async {
        let engine = FakeCameraEngine(Self.sample)
        engine.failUpdates = true
        let hold = Gate()
        engine.hold = hold
        let editor = engine.editor()
        editor.draft.name = "Drive"
        let first = Task { await editor.applyPendingEdits() }
        await settle(until: { engine.updates.count == 1 })
        editor.draft.name = "Driveway North"
        hold.open()
        await first.value
        #expect(editor.draft.name == "Driveway North" && editor.hasUnsavedEdits)
    }

    /// Updates reach the engine one at a time, in order: a slow first update can't land after the newer one.
    @Test func updatesAreSerialized() async {
        let engine = FakeCameraEngine(Self.sample)
        let hold = Gate()
        engine.hold = hold
        let editor = engine.editor()
        editor.draft.motionSensitivity = 0.2
        let first = Task { await editor.applyPendingEdits() }
        await settle(until: { engine.updates.count == 1 })
        editor.draft.motionSensitivity = 0.9
        let second = Task { await editor.applyPendingEdits() }
        await settle(limit: 50)
        #expect(engine.updates.count == 1)          // waits for the first
        hold.open()
        await first.value
        await second.value
        #expect(engine.updates.map(\.configuration.motionSensitivity) == [0.2, 0.9])
        #expect(engine.configuration?.motionSensitivity == 0.9 && !editor.hasUnsavedEdits)
    }

    /// The password sheet saves the draft (with its pending edits), not the engine's older copy.
    @Test func changingTheSignInKeepsPendingEdits() async {
        let engine = FakeCameraEngine(Self.sample)
        let editor = engine.editor()
        editor.draft.sensors.person = true
        await editor.changeSignIn(username: "viewer", password: "n3w")
        #expect(engine.updates.count == 1)
        let update = engine.updates[0]
        #expect(update.password == "n3w" && update.configuration.username == "viewer" && update.configuration.sensors.person)
        #expect(!editor.hasUnsavedEdits && editor.draft.username == "viewer")
    }

    @Test func engineNormalisationIsAdopted() async {
        let engine = FakeCameraEngine(Self.sample)
        engine.normalize = { $0.name = $0.name.trimmingCharacters(in: .whitespaces) }
        let editor = engine.editor()
        editor.draft.name = "Porch  "
        await editor.applyPendingEdits()
        #expect(editor.draft.name == "Porch" && !editor.hasUnsavedEdits)
    }

    @Test func anEmptyNameIsNeverSent() async {
        let engine = FakeCameraEngine(Self.sample)
        let editor = engine.editor()
        editor.draft.name = "  "
        await editor.applyPendingEdits()
        #expect(engine.updates.isEmpty)
        editor.draft.audioEnabled = false
        await editor.applyPendingEdits()
        #expect(engine.updates.last?.configuration.name == "Driveway" && engine.updates.last?.configuration.audioEnabled == false)
        #expect(editor.draft.name == "  ")        // still being typed
    }

    @Test func aRemovedCameraIsNotUpdated() async {
        let engine = FakeCameraEngine(Self.sample)
        let editor = engine.editor()
        editor.draft.audioEnabled = false
        engine.configuration = nil
        await editor.applyPendingEdits()
        #expect(engine.updates.isEmpty)
    }
}
