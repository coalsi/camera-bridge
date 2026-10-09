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

    /// The issue the engine reports now, most important first.
    static func current(state: EngineState, localNetworkAccess: LocalNetworkAccess, configurationBackup: URL? = nil,
                        webhookProblem: String? = nil) -> BridgeIssue? {
        if case .failed(let reason) = state { return .startFailed(Redact.string(reason)) }
        if let configurationBackup { return .configurationRecovered(configurationBackup) }
        if localNetworkAccess == .denied { return .localNetworkDenied }
        if let webhookProblem { return .webhookNotListening(Redact.string(webhookProblem)) }
        return nil
    }

    var title: String {
        switch self {
        case .startFailed: String(localized: "The Bridge Couldn’t Start")
        case .localNetworkDenied: String(localized: "Local Network Access Denied")
        case .configurationRecovered: String(localized: "Your Cameras Couldn’t Be Loaded")
        case .webhookNotListening: String(localized: "The Webhook Isn’t Listening")
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
        }
    }

    var actionTitle: String {
        switch self {
        case .startFailed: String(localized: "Try Again")
        case .localNetworkDenied: String(localized: "Fix…")
        case .configurationRecovered: String(localized: "Show in Finder")
        case .webhookNotListening: String(localized: "Try Again")
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
        }
    }
}
