import BridgeEngine
import CameraAdapters
import Foundation
import Observation

/// The camera detail form's edits: a draft over the engine's configuration, applied once edits pause for
/// `quietPeriod`, one update at a time and in order.
///
/// Engine configurations (including the echo of an update from here) are merged field by field: a field the person
/// hasn't changed follows the engine; a field with an unsaved edit keeps it. A failed update puts the engine's values
/// back, unless the person has edited again since (those edits get their own attempt). Sign-in and connection changes
/// (Change Password…, Change Address…) go through the same queue with the draft, so they never overwrite pending edits
/// with an older copy, nor are overwritten by one. A failed update is shown as the window's alert, except a connection
/// change, whose sheet shows it (`changeConnection` throws it).
@MainActor @Observable
final class CameraEditor {
    /// Sends a configuration (and a new password, or nil for unchanged) to the engine; throws why it wasn't applied.
    /// `showsFailure`: the failure is also shown as the window's alert (false: the caller shows it itself).
    typealias Apply = @MainActor (_ configuration: CameraConfiguration, _ password: String?, _ showsFailure: Bool) async throws -> Void
    /// The engine's current configuration for this camera, or nil once it has been removed.
    typealias Current = @MainActor () -> CameraConfiguration?

    static let defaultQuietPeriod: Duration = .milliseconds(600)

    /// The engine configuration the draft is based on.
    private(set) var base: CameraConfiguration
    /// What the form shows and edits.
    var draft: CameraConfiguration {
        didSet { if draft != oldValue { scheduleUpdate() } }
    }

    var hasUnsavedEdits: Bool { draft != base }

    @ObservationIgnored private let apply: Apply
    @ObservationIgnored private let current: Current
    @ObservationIgnored private let quietPeriod: Duration
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// The most recently queued update; each update waits for the one before it.
    @ObservationIgnored private var lastUpdate: Task<Void, any Error>?

    init(configuration: CameraConfiguration, quietPeriod: Duration = CameraEditor.defaultQuietPeriod,
         apply: @escaping Apply, current: @escaping Current) {
        base = configuration
        draft = configuration
        self.quietPeriod = quietPeriod
        self.apply = apply
        self.current = current
    }

    /// The engine published `latest` for this camera.
    func engineDidPublish(_ latest: CameraConfiguration) {
        guard latest != base else { return }
        let merged = Self.merge(base: base, edited: draft, latest: latest)
        base = latest
        if merged != draft { draft = merged }
    }

    /// The Motion Source picker: a sensor the old source offered and the new one doesn't (the webhook's detections, when
    /// the camera doesn't report them itself) is turned off with it, so no sensor stays on without its toggle — saved,
    /// unpublished, and back without asking when the source changes again.
    func chooseMotionSource(_ source: MotionSource) {
        guard source != draft.motionSource else { return }
        var updated = draft
        updated.sensors = SensorKind.adjusted(draft.sensors, capabilities: draft.capabilities, from: draft.motionSource, to: source)
        updated.motionSource = source
        draft = updated
    }

    /// Applies unsaved edits now, after any update already under way (the view calls this when it goes away).
    func applyPendingEdits() async {
        cancelDebounce()
        try? await enqueueUpdate(password: nil, showsFailure: true)
    }

    /// Changes the camera's sign-in together with any unsaved edits.
    func changeSignIn(username: String, password: String) async {
        draft.username = username
        cancelDebounce()
        try? await enqueueUpdate(password: password, showsFailure: true)
    }

    /// Changes where the camera is reached (the Connection sheet, after its check) together with any unsaved edits:
    /// the same camera, so its Home accessory, pairing and history stay. Throws why the engine didn't apply it (the
    /// sheet shows it; no alert waits behind the sheet), `EngineError.unknownCamera` when the camera was removed.
    func changeConnection(endpoint: CameraEndpoint, mainStreamURL: URL?, subStreamURL: URL?) async throws {
        draft.endpoint = endpoint
        draft.mainStreamURL = mainStreamURL
        draft.subStreamURL = subStreamURL
        cancelDebounce()
        try await enqueueUpdate(password: nil, showsFailure: false)
    }

    /// Three-way merge: each field the person can edit keeps its edit when it differs from `base`; everything else
    /// comes from `latest`.
    static func merge(base: CameraConfiguration, edited: CameraConfiguration, latest: CameraConfiguration) -> CameraConfiguration {
        var merged = latest
        func keepEdit<Value: Equatable>(_ field: WritableKeyPath<CameraConfiguration, Value>) {
            if edited[keyPath: field] != base[keyPath: field] { merged[keyPath: field] = edited[keyPath: field] }
        }
        keepEdit(\.name)
        keepEdit(\.isEnabled)
        keepEdit(\.username)
        keepEdit(\.endpoint)
        keepEdit(\.mainStreamURL)
        keepEdit(\.subStreamURL)
        keepEdit(\.motionSource)
        keepEdit(\.motionSensitivity)
        keepEdit(\.motionHoldSeconds)
        keepEdit(\.audioEnabled)
        keepEdit(\.twoWayAudio)
        keepEdit(\.liveStreamMode)
        keepEdit(\.liveQualityMode)
        keepEdit(\.liveMaxBitrateOverride)
        keepEdit(\.recordingStreamMode)
        keepEdit(\.recordingQualityMode)
        keepEdit(\.timestampOverlay)
        let sensors: WritableKeyPath<CameraConfiguration, SensorOptions> = \.sensors
        for kind in SensorKind.allCases {
            keepEdit(sensors.appending(path: kind.keyPath))
        }
        return merged
    }

    // MARK: Updates

    private func scheduleUpdate() {
        cancelDebounce()
        guard hasUnsavedEdits else { return }
        debounce = Task { [weak self, quietPeriod] in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled, let self else { return }
            debounce = nil
            try? await enqueueUpdate(password: nil, showsFailure: true)
        }
    }

    private func cancelDebounce() {
        debounce?.cancel()
        debounce = nil
    }

    /// Returns when the update was applied (also when there was nothing to apply); throws why not.
    private func enqueueUpdate(password: String?, showsFailure: Bool) async throws {
        let previous = lastUpdate
        let update = Task { [self] in
            _ = await previous?.result
            try await performUpdate(password: password, showsFailure: showsFailure)
        }
        lastUpdate = update
        try await update.value
    }

    /// Sends the draft as it is when this update's turn comes. Returns once the engine holds it; throws why not.
    private func performUpdate(password: String?, showsFailure: Bool) async throws {
        guard let latest = current() else { throw EngineError.unknownCamera }   // removed
        engineDidPublish(latest)
        let edited = draft
        var submitted = edited
        if submitted.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submitted.name = base.name   // a name is required; the field is still being edited
        }
        guard submitted != base || password != nil else { return }
        do {
            try await apply(submitted, password, showsFailure)
        } catch {
            if draft == edited { draft = base }   // not applied: show what the engine has
            throw error
        }
        // The engine now holds `submitted`: merge its current values over it (normalisation, concurrent changes).
        base = submitted
        if let latest = current() { engineDidPublish(latest) }
    }
}
