import BridgeSupport
import Foundation

/// Local Network privacy check (plan W3-1 item 7, spec §3.2 onboarding and §7, TN3179): a TCP connection to a camera
/// through `PlatformServices.transport` triggers the system prompt and reveals the answer. Connected or refused (the
/// packets reached the host) → granted; `TransportError.localNetworkDenied` → denied; no answer or another failure →
/// unknown (the host may simply be down).
///
/// The first local network operation shows the system's Local Network alert without waiting for the answer: until the
/// person responds, connections are blocked exactly as if access were denied (TN3179). So a denial is retried every
/// `retryInterval` for up to `answerWait` before it counts; access allowed meanwhile shows on the next attempt.
enum LocalNetworkCheck {
    static func check(host: String, port: UInt16, transport: any NetworkTransport, timeout: Duration = .seconds(3),
                      answerWait: Duration = .zero, retryInterval: Duration = .milliseconds(500)) async -> LocalNetworkAccess {
        let deadline = ContinuousClock.now + answerWait
        while true {
            let access = await attempt(host: host, port: port, transport: transport, timeout: timeout)
            guard access == .denied, ContinuousClock.now + retryInterval <= deadline else { return access }
            do {
                try await Task.sleep(for: retryInterval)
            } catch {
                return access   // cancelled while still blocked
            }
        }
    }

    private static func attempt(host: String, port: UInt16, transport: any NetworkTransport, timeout: Duration) async -> LocalNetworkAccess {
        do {
            let connection = try await transport.connect(host: host, port: port, timeout: timeout)
            connection.close()
            return .granted
        } catch TransportError.localNetworkDenied {
            return .denied
        } catch TransportError.connectionRefused {
            return .granted
        } catch {
            return .unknown
        }
    }
}
