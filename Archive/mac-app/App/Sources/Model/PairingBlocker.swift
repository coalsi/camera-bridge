import BridgeEngine
import Foundation

/// Why a camera's QR code and setup code aren't offered: the engine reports a code for every camera (from its stored
/// identity), but the Home app only finds an accessory the bridge publishes. Like the Sensors Bridge page, the camera
/// page and the wizard's last page offer the code only while the accessory is published, and otherwise say why.
enum PairingBlocker: Equatable {
    case cameraDisabled
    case bridgePaused
    case bridgeNotRunning
    case bridgeStarting
    /// The bridge runs but this camera's accessory couldn't start (its status and the log say why).
    case accessoryNotRunning

    /// What fixes it from the same page.
    enum Action: Equatable {
        case resumeBridge, startBridge

        var title: String {
            switch self {
            case .resumeBridge: String(localized: "Resume Bridge")
            case .startBridge: String(localized: "Start Bridge")
            }
        }
    }

    /// nil when the accessory is published: the bridge runs, the camera is on and its accessory listens (`hapPort`).
    static func current(state: EngineState, isEnabled: Bool, hapPort: UInt16?) -> PairingBlocker? {
        guard isEnabled else { return .cameraDisabled }
        switch state {
        case .paused: return .bridgePaused
        case .stopped, .failed: return .bridgeNotRunning
        case .starting: return .bridgeStarting
        case .running: return hapPort == nil ? .accessoryNotRunning : nil
        }
    }

    var message: String {
        switch self {
        case .cameraDisabled:
            String(localized: "This camera is turned off, so the Home app can’t find it. Turn it on to add it.")
        case .bridgePaused:
            String(localized: "The bridge is paused, so the Home app can’t find this accessory. Resume the bridge to add it.")
        case .bridgeNotRunning:
            String(localized: "The bridge isn’t running, so the Home app can’t find this accessory. Start the bridge to add it.")
        case .bridgeStarting:
            String(localized: "The bridge is starting. The code appears once this accessory is published.")
        case .accessoryNotRunning:
            String(localized: "This camera’s accessory isn’t running, so the Home app can’t find it. The camera’s status and log show why.")
        }
    }

    var action: Action? {
        switch self {
        case .bridgePaused: .resumeBridge
        case .bridgeNotRunning: .startBridge
        case .cameraDisabled, .bridgeStarting, .accessoryNotRunning: nil
        }
    }
}
