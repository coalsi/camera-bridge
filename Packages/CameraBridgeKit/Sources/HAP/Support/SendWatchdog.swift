import BridgeSupport
import Foundation

/// Sends `data` and closes `connection` if the send has not completed within `limit` (a peer that vanished without a
/// FIN or RST: its receive window closed, its Wi-Fi dropped, the Mac slept mid-send). Closing makes the pending `send`
/// throw `TransportError.closed`, so the caller's writer ends and its connection is torn down like any failed one.
/// `onStall` runs once, just before the close (the caller logs the incident there). A peer that is merely slow is not
/// cut off: the limit counts one send, and a send completes as soon as the stack has taken the bytes.
package func sendWatchingProgress(_ data: Data, on connection: any TCPConnection, limit: Duration,
                                  onStall: @escaping @Sendable () -> Void) async throws {
    let watchdog = Task {
        do {
            try await Task.sleep(for: limit)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        onStall()
        connection.close()
    }
    defer { watchdog.cancel() }
    try await connection.send(data)
}
