import BridgeEngine
import BridgeSupport
import Foundation

/// A problem with the whole bridge, shown as a banner at the top of the manager window and in the menu bar: the status
/// item's warning symbol (VoiceOver names the issue) and, under the menu's header, an item that opens its fix
/// (`menuItemTitle`; a failed start is the header itself, "CameraBridge — Error — …", with Start Bridge). Camera
/// problems stay with the camera; failed actions are alerts.
enum BridgeIssue: Equatable {
    /// The engine couldn't start (`EngineState.failed`); the reason is redacted for the screen.
    case startFailed(String)
    /// macOS denied Local Network access: no camera can be reached and nothing appears in the Home app.
    case localNetworkDenied
    /// The configuration file was damaged and set aside as this file (`BridgeEngine.configurationRecoveredFrom`): the
    /// bridge started without the cameras. Shown until dismissed (Show in Finder), also after a relaunch.
    case configurationRecovered(URL)
    /// The enabled webhook isn't listening (`BridgeEngine.webhookProblem`, e.g. another app took its port at login):
    /// rings of doorbells that report no button of their own, and motion and detections reported to it, are lost.
    case webhookNotListening(String)
    /// Recording cannot continue although a camera has Record on: no folder chosen, the drive is gone or full, or a write failed. Waiting for a
    /// camera is not an issue. The last in line: it needs a person, but nothing else is wrong with the bridge.
    case nvrStorage(ArchivePause)

    /// The issue the engine reports now, most important first.
    static func current(state: EngineState, localNetworkAccess: LocalNetworkAccess, configurationBackup: URL? = nil,
                        webhookProblem: String? = nil, nvrPause: ArchivePause? = nil) -> BridgeIssue? {
        if case .failed(let reason) = state { return .startFailed(Redact.string(reason)) }
        if let configurationBackup { return .configurationRecovered(configurationBackup) }
        if localNetworkAccess == .denied { return .localNetworkDenied }
        if let webhookProblem { return .webhookNotListening(Redact.string(webhookProblem)) }
        if let nvrPause { return .nvrStorage(nvrPause) }
        return nil
    }

    /// Why recording cannot continue, when some camera has Record on: the drive's pause (`ArchiveStorageStatus.pause`: no folder, folder missing,
    /// disk full) first, else the first recording camera's own (a write that stalled).
    static func nvrPause(storage: ArchiveStorageStatus?, cameras: [CameraStatus]) -> ArchivePause? {
        let recording = cameras.filter { $0.nvr.state != .off }
        guard !recording.isEmpty else { return nil }
        if let pause = storage?.pause { return pause }
        for camera in recording {
            if case .paused(let pause) = camera.nvr.state { return pause }
        }
        return nil
    }

    var title: String {
        switch self {
        case .startFailed: String(localized: "The Bridge Couldn’t Start")
        case .localNetworkDenied: String(localized: "Local Network Access Denied")
        case .configurationRecovered: String(localized: "Your Cameras Couldn’t Be Loaded")
        case .webhookNotListening: String(localized: "The Webhook Isn’t Listening")
        case .nvrStorage: String(localized: "Recording Can’t Continue")
        }
    }

    var detail: String {
        switch self {
        case .startFailed(let reason): reason
        case .localNetworkDenied: String(localized: "Camera Bridge can’t reach your cameras or appear in the Home app until you allow it.")
        case .configurationRecovered(let backup):
            String(localized: "The configuration file was damaged, so Camera Bridge started without your cameras. The damaged file was kept as “\(backup.lastPathComponent)”.")
        case .webhookNotListening(let problem):
            String(localized: "\(problem) Doorbell rings, motion and detections sent to it are lost until it listens.")
        case .nvrStorage(let pause): pause.readable
        }
    }

    var actionTitle: String {
        switch self {
        case .startFailed: String(localized: "Try Again")
        case .localNetworkDenied: String(localized: "Fix…")
        case .configurationRecovered: String(localized: "Show in Finder")
        case .webhookNotListening: String(localized: "Try Again")
        case .nvrStorage(let pause): if case .noFolder = pause { String(localized: "Choose Folder…") } else { String(localized: "Open Recording Settings") }
        }
    }

    /// The menu bar menu's item under its header, which opens the manager at the issue (`AppModel.show(_:)`); nil for a
    /// failed start, which the header names ("CameraBridge — Error — …") next to Start Bridge.
    var menuItemTitle: String? {
        switch self {
        case .startFailed: nil
        case .localNetworkDenied: String(localized: "Local Network Access Denied — Fix…")
        case .configurationRecovered: String(localized: "Your Cameras Couldn’t Be Loaded — Show…")
        case .webhookNotListening: String(localized: "The Webhook Isn’t Listening — Show…")
        case .nvrStorage: String(localized: "Recording Can’t Continue — Show…")
        }
    }
}
