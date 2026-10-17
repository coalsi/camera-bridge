// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Fields follow HAP-NodeJS lib/camera/RecordingManagement.ts `RecordingManagementState` and RTPStreamManagement's state.

import Foundation

/// What `CameraController` keeps in `HAPPersistentState.extras[CameraController.persistenceKey]` (JSON), like
/// HAP-NodeJS's `RecordingManagementState` + `RTPStreamManagementState`.
///
/// Decoding is lenient: a missing field (state written by another version) takes its default, so adding a field never
/// makes older state unreadable (which would reset the hub's selection and every flag).
struct PersistedCameraState: Codable, Equatable, Sendable {
    var version = 1
    /// SHA-256 (hex) of the three Supported*RecordingConfiguration values the selection was made against.
    var configurationHash: String?
    /// The hub's SelectedCameraRecordingConfiguration TLV, dropped when `configurationHash` no longer matches.
    var selectedConfiguration: Data?
    var recordingActive = false
    var recordingAudioActive = false
    var homeKitCameraActive = true
    var eventSnapshotsActive = true
    var periodicSnapshotsActive = true
    var nightVision: Bool?
    var indicatorEnabled: Bool?
    /// RTP stream management `Active`, by stream index.
    var streamActive: [Bool] = []
    /// The camera's last battery reading, nil while it has reported none: a camera that has a battery publishes its Battery
    /// service from the start (before the first new reading), so the accessory's structure, and `c#`, stay the same.
    var battery: CameraBattery?

    enum CodingKeys: String, CodingKey {
        case version, configurationHash, selectedConfiguration, recordingActive, recordingAudioActive, homeKitCameraActive
        case eventSnapshotsActive, periodicSnapshotsActive, nightVision, indicatorEnabled, streamActive, battery
    }
}

extension PersistedCameraState {
    /// What HAP-NodeJS `handleFactoryReset` leaves (the accessory lost its last pairing): night vision and the indicator
    /// (camera settings) stay, and so does the battery reading (a fact about the camera); the hub's selection, recording, the
    /// operating-mode flags and every stream `Active` go back to their defaults.
    func afterFactoryReset() -> PersistedCameraState {
        PersistedCameraState(configurationHash: configurationHash, nightVision: nightVision, indicatorEnabled: indicatorEnabled,
                             streamActive: streamActive.map { _ in true }, battery: battery)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PersistedCameraState()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        configurationHash = try container.decodeIfPresent(String.self, forKey: .configurationHash)
        selectedConfiguration = try container.decodeIfPresent(Data.self, forKey: .selectedConfiguration)
        recordingActive = try container.decodeIfPresent(Bool.self, forKey: .recordingActive) ?? defaults.recordingActive
        recordingAudioActive = try container.decodeIfPresent(Bool.self, forKey: .recordingAudioActive) ?? defaults.recordingAudioActive
        homeKitCameraActive = try container.decodeIfPresent(Bool.self, forKey: .homeKitCameraActive) ?? defaults.homeKitCameraActive
        eventSnapshotsActive = try container.decodeIfPresent(Bool.self, forKey: .eventSnapshotsActive) ?? defaults.eventSnapshotsActive
        periodicSnapshotsActive = try container.decodeIfPresent(Bool.self, forKey: .periodicSnapshotsActive) ?? defaults.periodicSnapshotsActive
        nightVision = try container.decodeIfPresent(Bool.self, forKey: .nightVision)
        indicatorEnabled = try container.decodeIfPresent(Bool.self, forKey: .indicatorEnabled)
        streamActive = try container.decodeIfPresent([Bool].self, forKey: .streamActive) ?? defaults.streamActive
        battery = (try? container.decodeIfPresent(CameraBattery.self, forKey: .battery)) ?? nil
    }
}
