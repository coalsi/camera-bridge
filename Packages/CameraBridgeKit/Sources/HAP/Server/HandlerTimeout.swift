import BridgeSupport
import Foundation

/// Runs a characteristic or resource handler with HAP-NodeJS's timeout policy: a warning after `warning`, and
/// `HAPStatus.operationTimedOut` after `timeout` in total. Built on BridgeSupport's `withDeadline` (the package's one
/// deadline race), so the request is answered on time even when the handler ignores cancellation: the handler is then
/// cancelled and left to finish on its own.
///
/// Follows the caller's cancellation (`withDeadline`'s default): a cancelled request stops waiting at once, its handler
/// is cancelled, and the result is `.operationTimedOut` too — nobody is left to read the answer, and the handler's late
/// result is dropped as for a timeout.
enum HandlerTimeout {
    static let log = Log(category: "hap")

    /// `log`: the server's (tagged with its camera).
    static func run<T: Sendable>(warning: Duration, timeout: Duration, log: Log = HandlerTimeout.log, description: String,
                                 _ body: @escaping @Sendable () async throws(HAPStatus) -> T) async throws(HAPStatus) -> T {
        let slow = Task {
            try? await Task.sleep(for: warning)
            guard !Task.isCancelled else { return }
            log.warning("\(description) handler is slow to respond")
        }
        defer { slow.cancel() }
        do {
            return try await withDeadline(timeout) { () async throws -> T in try await body() }
        } catch let status as HAPStatus {
            throw status
        } catch is DeadlineExceeded {
            log.error("\(description) handler did not respond within \(timeout)")
            throw .operationTimedOut
        } catch {
            throw .operationTimedOut   // CancellationError: the request itself was cancelled
        }
    }
}
