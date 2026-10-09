import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Go2RTCManager {
    /// A manager for the real helper: ports found through `transport` (a listener on port 0 of 127.0.0.1, closed again), the health
    /// check an HTTP request to the helper's API, and the helper's private files in `directory` (`<data>/go2rtc`).
    public static func standard(launcher: any HelperLaunching, transport: any NetworkTransport, dataDirectory: URL,
                                timing: Timing = Timing()) -> Go2RTCManager {
        Go2RTCManager(launcher: launcher, directory: dataDirectory.appending(path: "go2rtc", directoryHint: .isDirectory),
                      pickPort: portPicker(transport: transport), healthCheck: httpHealthCheck, timing: timing)
    }

    /// Asks the system for a free port on 127.0.0.1 by listening on port 0, and gives the port back at once. Ports are never
    /// handed out twice in a row.
    public static func portPicker(transport: any NetworkTransport) -> PortPicker {
        let recent = RecentPorts()
        return {
            for _ in 0..<8 {
                guard let listener = try? await transport.listen(port: 0, loopbackOnly: true) else { return nil }
                let port = listener.port
                listener.close()
                if port > 1024, recent.insert(port) { return port }
            }
            return nil
        }
    }

    /// `GET /api` with the run's password: the helper answers `{"version": …}` once it is up.
    public static let httpHealthCheck: HealthCheck = { port, password in
        guard let url = URL(string: "http://127.0.0.1:\(port)/api") else { return false }
        let credentials = password.map { HTTPCredentials(username: Go2RTCConfig.apiUsername, password: $0) }
        let client = AuthenticatingHTTPClient(credentials: credentials, timeout: .seconds(2))
        defer { client.invalidate() }
        guard let (data, response) = try? await client.data(for: URLRequest(url: url)), response.statusCode == 200 else { return false }
        return (try? JSONValue.parse(data))?["version"]?.string != nil
    }
}

private final class RecentPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [UInt16] = []

    /// True when `port` was not handed out lately.
    func insert(_ port: UInt16) -> Bool {
        lock.withLock {
            guard !ports.contains(port) else { return false }
            ports.append(port)
            if ports.count > 16 { ports.removeFirst() }
            return true
        }
    }
}
