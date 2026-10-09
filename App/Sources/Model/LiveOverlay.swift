import BridgeEngine
import Foundation

/// What a live or snapshot picture says about its camera when it is not simply showing video.
enum LiveOverlay: Equatable {
    case none
    /// The camera is offline (or its stream is unavailable): the last snapshot stays, dimmed.
    case offline
    case connecting
    /// A live picture stopped arriving (the camera is reconnecting).
    case reconnecting
    /// The camera is turned off.
    case disabled

    /// The overlay for a camera with `connection` whose live feed (when it runs: `isWanted`) is in `phase`.
    static func current(connection: ConnectionState, phase: LiveFeed.Phase, isWanted: Bool) -> LiveOverlay {
        switch connection {
        case .offline: return .offline
        case .disabled: return .disabled
        case .connecting: return .connecting
        case .idle, .online: break
        }
        guard isWanted else { return .none }
        switch phase {
        case .stopped, .live: return .none
        case .connecting: return .connecting
        case .stalled: return .reconnecting
        case .unavailable: return .offline
        }
    }

    var title: String? {
        switch self {
        case .none: nil
        case .offline: String(localized: "Offline")
        case .connecting: String(localized: "Connecting…")
        case .reconnecting: String(localized: "Reconnecting…")
        case .disabled: String(localized: "Turned Off")
        }
    }

    var symbol: String {
        switch self {
        case .none: ""
        case .offline: "wifi.slash"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .disabled: "pause.circle"
        }
    }
}
