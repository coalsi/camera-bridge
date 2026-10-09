import BridgeEngine
import Foundation

/// The camera page's "Recent Events" (spec §3.2): the engine's event history for the camera, newest first. Not derived
/// from the log, which a log level of Notice or above empties of events.
enum RecentEvents {
    static let defaultLimit = 5

    static func newestFirst(in status: CameraStatus?, limit: Int = defaultLimit) -> [CameraEventRecord] {
        Array((status?.recentEvents ?? []).reversed().prefix(limit))
    }
}
