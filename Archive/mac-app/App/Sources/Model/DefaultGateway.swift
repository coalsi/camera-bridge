import Foundation
import Network
import Synchronization

/// The current network's IPv4 router (`NWPath.gateways`): what the Local Network check connects to before any camera
/// is configured. Connecting to a LAN host shows the system's Local Network prompt and reveals a denial (TN3179);
/// reading the path itself sends nothing.
nonisolated enum DefaultGateway {
    /// The first IPv4 gateway of the current path, or nil (no network, IPv6 only, or no answer within `timeout`).
    static func ipv4Address(timeout: Duration = .seconds(2)) async -> String? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.gateway")
        let address = await withCheckedContinuation { continuation in
            let answer = OneShot(continuation)
            monitor.pathUpdateHandler = { path in
                answer.resume(ipv4Address(in: path.gateways))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout / .milliseconds(1)))) {
                answer.resume(nil)
            }
        }
        monitor.cancel()
        return address
    }

    /// Dotted-quad form of the first IPv4 host among `gateways`.
    static func ipv4Address(in gateways: [NWEndpoint]) -> String? {
        for gateway in gateways {
            if case .hostPort(host: .ipv4(let address), port: _) = gateway {
                return address.rawValue.map(String.init).joined(separator: ".")
            }
        }
        return nil
    }
}

/// Resumes a continuation once, from whichever callback comes first.
private nonisolated final class OneShot: Sendable {
    private let continuation: Mutex<CheckedContinuation<String?, Never>?>

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: String?) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }
}
