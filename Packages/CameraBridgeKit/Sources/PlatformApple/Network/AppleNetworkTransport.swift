#if os(macOS)
import BridgeSupport
import Foundation
import Network
import Synchronization

/// `NetworkTransport` over Network.framework (`NWListener` / `NWConnection`, TCP with `TCP_NODELAY`).
///
/// - `listen(port:loopbackOnly:)` binds 127.0.0.1 when `loopbackOnly`, else every interface (dual stack), with
///   address reuse (a fixed HAP port can be rebound right after a restart). A fixed port that another socket holds at
///   any address the listener would serve — the same address, a wildcard, or (for every interface) one specific
///   local address such as 127.0.0.1 — is refused with `.addressInUse` (`ListenerPortProbe`).
/// - `connect` fails fast on `.connectionRefused` and on Local Network denial (`.waiting` with
///   `unsatisfiedReason == .localNetworkDenied`, or DNS-SD -65570) and otherwise waits for the path up to `timeout`.
///   A connection left waiting with `EADDRINUSE` (its local port completes an existing 4-tuple) is replaced by one
///   bound to a kernel-chosen local port, within the same `timeout`.
/// - Connections report bare IP literals (no port, no IPv6 zone; IPv4-mapped IPv6 as IPv4).
/// - Cancelling a task blocked in `receive` or `connect` cancels the connection and throws `CancellationError`.
public final class AppleNetworkTransport: NetworkTransport {
    public init() {}

    public func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        let probing = port == 0 ? [] : ListenerPortProbe.addresses(loopbackOnly: loopbackOnly)
        return try await AppleTCPListener.start(port: port, loopbackOnly: loopbackOnly, probing: probing)
    }

    public func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        try await AppleTCPConnection.connect(host: host, port: port, timeout: timeout)
    }

    /// kDNSServiceErr_PolicyDenied: Local Network privacy refused a Bonjour/DNS operation.
    static let dnsPolicyDenied: Int32 = -65570

    static func transportError(_ error: NWError) -> TransportError {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .ETIMEDOUT: return .timedOut
            case .EADDRINUSE: return .addressInUse
            case .ECANCELED, .ECONNRESET, .ECONNABORTED, .ENOTCONN, .EPIPE, .ESHUTDOWN: return .closed
            default: return .failed(String(describing: error))
            }
        case .dns(let code) where code == dnsPolicyDenied:
            return .localNetworkDenied
        default:
            return .failed(String(describing: error))
        }
    }

    static func transportError(_ error: any Error) -> TransportError {
        if let error = error as? TransportError { return error }
        if let error = error as? NWError { return transportError(error) }
        return .failed(String(describing: error))
    }

    /// Bare IP literal for a host plus whether it is IPv6. IPv4-mapped IPv6 addresses are reported as IPv4.
    static func ipLiteral(_ host: NWEndpoint.Host) -> (String, Bool) {
        switch host {
        case .ipv4(let address):
            return (withoutZone("\(address)"), false)
        case .ipv6(let address):
            if address.isIPv4Mapped, let v4 = address.asIPv4 { return (withoutZone("\(v4)"), false) }
            return (withoutZone("\(address)"), true)
        case .name(let name, _):
            return (name, name.contains(":"))
        @unknown default:
            return ("\(host)", false)
        }
    }

    static func ipLiteral(_ endpoint: NWEndpoint?) -> (String, Bool) {
        guard case .hostPort(let host, _)? = endpoint else { return ("", false) }
        return ipLiteral(host)
    }

    /// The zone of an IPv6 host (`fe80::1%en0` → `en0`): its interface's name; nil for IPv4 (mapped included) and
    /// addresses without one.
    static func zone(_ host: NWEndpoint.Host) -> String? {
        guard case .ipv6(let address) = host, !address.isIPv4Mapped else { return nil }
        if let name = address.interface?.name, !name.isEmpty { return name }
        let text = "\(address)"
        guard let percent = text.firstIndex(of: "%") else { return nil }
        let zone = text[text.index(after: percent)...]
        return zone.isEmpty ? nil : String(zone)
    }

    static func zone(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        return zone(host)
    }

    private static func withoutZone(_ text: String) -> String {
        text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    }

    /// Dead-peer detection of the connections a listener accepts (HAP and HDS): a controller that vanished without a FIN
    /// or RST (Wi-Fi dropped, the Mac or the hub slept) is noticed after `keepaliveIdle` + `keepaliveCount` x
    /// `keepaliveInterval` = 60 s of silence, or after 20 s of unacknowledged retransmissions (`connectionDropTime`), and
    /// its connection fails, which frees the stream session, HDS connection and recording slot it held.
    static let keepaliveIdle = 30
    static let keepaliveInterval = 10
    static let keepaliveCount = 3
    static let connectionDropTime = 20

    /// `keepalive`: for accepted connections only; outbound ones (cameras, tests) keep the system defaults.
    static func parameters(keepalive: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if keepalive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = keepaliveIdle
            tcp.keepaliveInterval = keepaliveInterval
            tcp.keepaliveCount = keepaliveCount
            tcp.connectionDropTime = connectionDropTime
        }
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return .nanoseconds(0) }
        guard seconds < Int64(Int32.max) else { return .never }
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}

/// Resumes a continuation at most once (Network.framework may report several states).
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    /// True if this call resumed the continuation.
    @discardableResult
    func resume(with result: Result<Value, any Error>) -> Bool {
        let taken = continuation.withLock { state in
            defer { state = nil }
            return state
        }
        taken?.resume(with: result)
        return taken != nil
    }
}

// MARK: - Listener

final class AppleTCPListener: TCPListener {
    let port: UInt16
    let connections: AsyncStream<any TCPConnection>
    private let listener: NWListener
    private let continuation: AsyncStream<any TCPConnection>.Continuation

    private init(port: UInt16, listener: NWListener, connections: AsyncStream<any TCPConnection>,
                 continuation: AsyncStream<any TCPConnection>.Continuation) {
        self.port = port
        self.listener = listener
        self.connections = connections
        self.continuation = continuation
    }

    deinit {
        listener.cancel()
        continuation.finish()
    }

    func close() {
        listener.cancel()
        continuation.finish()
    }

    /// The listener for `port` (0 = any), not started (nothing is bound yet; internal for tests): 127.0.0.1 only when
    /// `loopbackOnly`, else every interface and both IP versions; with address reuse.
    /// `keepalive`: dead-peer detection on the accepted connections (`AppleNetworkTransport.parameters`); only a test of
    /// connection teardown behaviour turns it off.
    static func makeListener(port: UInt16, loopbackOnly: Bool, keepalive: Bool = true) throws -> NWListener {
        let parameters = AppleNetworkTransport.parameters(keepalive: keepalive)
        parameters.allowLocalEndpointReuse = true
        let requestedPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        do {
            if loopbackOnly {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requestedPort)
                return try NWListener(using: parameters)
            }
            return try NWListener(using: parameters, on: requestedPort)
        } catch {
            throw AppleNetworkTransport.transportError(error)
        }
    }

    /// `probing`: addresses checked with `ListenerPortProbe` before a fixed `port` is bound (ignored for port 0).
    static func start(port: UInt16, loopbackOnly: Bool, probing: [ListenerPortProbe.Address], keepalive: Bool = true) async throws -> AppleTCPListener {
        if port != 0, let holder = ListenerPortProbe.firstConflict(port: port, among: probing) {
            Log(category: "transport").debug("Port \(port) is already held at \(holder)")
            throw TransportError.addressInUse
        }
        let listener = try makeListener(port: port, loopbackOnly: loopbackOnly, keepalive: keepalive)

        let (connections, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self, bufferingPolicy: .bufferingOldest(64))
        listener.newConnectionHandler = { connection in
            AppleTCPConnection.accept(connection) { accepted in
                if case .dropped = continuation.yield(accepted) { accepted.close() }
            }
        }
        let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.listener")
        do {
            let boundPort: UInt16 = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (checked: CheckedContinuation<UInt16, any Error>) in
                    let once = ResumeOnce(checked)
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            once.resume(with: .success(listener.port?.rawValue ?? 0))
                        case .waiting(let error), .failed(let error):
                            if !once.resume(with: .failure(AppleNetworkTransport.transportError(error))) {
                                Log(category: "transport").warning("Listener stopped: \(error)")
                            }
                            listener.cancel()
                            continuation.finish()
                        case .cancelled:
                            once.resume(with: .failure(TransportError.closed))
                            continuation.finish()
                        default:
                            break
                        }
                    }
                    listener.start(queue: queue)
                }
            } onCancel: {
                listener.cancel()
            }
            return AppleTCPListener(port: boundPort, listener: listener, connections: connections, continuation: continuation)
        } catch {
            listener.cancel()
            continuation.finish()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

// MARK: - Connection

final class AppleTCPConnection: TCPConnection {
    let id = UUID()
    let localAddress: String
    let remoteAddress: String
    let isIPv6: Bool
    /// Connections `connect` started for this one (internal, for tests): 1 unless a local port was in use (0: accepted).
    let connectAttempts: Int
    /// The interface of a link-local connection (`TCPConnection.zone`): the peer's zone, else ours.
    let zone: String?
    private let connection: NWConnection
    private let state = ConnectionState()

    /// `connection` must be `.ready`.
    private init(connection: NWConnection, connectAttempts: Int = 0) {
        self.connection = connection
        self.connectAttempts = connectAttempts
        let path = connection.currentPath
        let remote = AppleNetworkTransport.ipLiteral(path?.remoteEndpoint ?? connection.endpoint)
        remoteAddress = remote.0
        isIPv6 = remote.1
        localAddress = AppleNetworkTransport.ipLiteral(path?.localEndpoint).0
        zone = AppleNetworkTransport.zone(path?.remoteEndpoint ?? connection.endpoint) ?? AppleNetworkTransport.zone(path?.localEndpoint)
    }

    deinit {
        connection.cancel()
    }

    /// The local TCP port (internal, for tests; `localAddress` carries no port).
    var localPort: UInt16? {
        guard case .hostPort(_, let port)? = connection.currentPath?.localEndpoint else { return nil }
        return port.rawValue
    }

    /// Starts an inbound connection and hands it to `deliver` once it is ready (dropped if it fails first).
    static func accept(_ connection: NWConnection, deliver: @escaping @Sendable (AppleTCPConnection) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                deliver(AppleTCPConnection(connection: connection))
            case .waiting, .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.coreysilvia.CameraBridge.connection"))
    }

    /// How one `NWConnection` of `connect` ended without an error.
    private enum Attempt: Sendable {
        case ready
        /// `.waiting(EADDRINUSE)`: the local port Network.framework chose completes a 4-tuple that already exists.
        /// `local` is the attempt's local endpoint, if known.
        case localPortInUse(local: NWEndpoint?)
    }

    /// Network.framework can give a new connection a local port whose 4-tuple is already taken — on loopback, the
    /// TIME_WAIT left behind by a server that closed first, once a new listener got the old client's port — and the
    /// connection then waits with `EADDRINUSE` for good; a new `NWConnection` is given the same port again. Such an
    /// attempt is replaced by one that binds the same local address with a port the kernel picks (which skips ports
    /// any socket uses), until `timeout`.
    static func connect(host: String, port: UInt16, timeout: Duration) async throws -> AppleTCPConnection {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.failed("invalid address \(host):\(port)")
        }
        let deadline = ContinuousClock.now + timeout
        var requiredLocalEndpoint: NWEndpoint?
        var attempts = 0
        while true {
            attempts += 1
            let parameters = AppleNetworkTransport.parameters()
            if let requiredLocalEndpoint { parameters.requiredLocalEndpoint = requiredLocalEndpoint }
            let connection = NWConnection(host: NWEndpoint.Host(trimmed), port: nwPort, using: parameters)
            switch try await attempt(connection, timeout: deadline - ContinuousClock.now) {
            case .ready:
                return AppleTCPConnection(connection: connection, connectAttempts: attempts)
            case .localPortInUse(let local):
                Log(category: "transport").debug("Connection to \(trimmed):\(port) from \(local.map { "\($0)" } ?? "?") waits with "
                                                 + "EADDRINUSE (attempt \(attempts)); retrying from another local port")
                if case .hostPort(let address, _)? = local { requiredLocalEndpoint = .hostPort(host: address, port: .any) }
                // The first retry goes at once; later ones back off (20 ms, doubling, at most 500 ms).
                if attempts > 1 {
                    let backoff = min(Duration.milliseconds(20 << min(attempts - 2, 5)), .milliseconds(500))
                    try await Task.sleep(for: min(backoff, max(deadline - ContinuousClock.now, .zero)))
                }
                guard ContinuousClock.now < deadline else { throw TransportError.timedOut }
            }
        }
    }

    /// Starts `connection` and waits until it is ready, a definitive failure, the local port is in use, or `timeout`.
    private static func attempt(_ connection: NWConnection, timeout: Duration) async throws -> Attempt {
        let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.connection")
        let outcome: Attempt
        do {
            outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (checked: CheckedContinuation<Attempt, any Error>) in
                    let once = ResumeOnce(checked)
                    let fail: @Sendable (TransportError) -> Void = { error in
                        if once.resume(with: .failure(error)) { connection.cancel() }
                    }
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            once.resume(with: .success(.ready))
                        case .waiting(let error):
                            // Network.framework keeps retrying while waiting; give up only on definitive answers.
                            if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                                fail(.localNetworkDenied)
                            } else if case .posix(.EADDRINUSE) = error {
                                // Retrying keeps the same local port: never resolves on its own.
                                let local = connection.currentPath?.localEndpoint
                                if once.resume(with: .success(.localPortInUse(local: local))) { connection.cancel() }
                            } else {
                                let mapped = AppleNetworkTransport.transportError(error)
                                if mapped == .connectionRefused || mapped == .localNetworkDenied { fail(mapped) }
                            }
                        case .failed(let error):
                            fail(AppleNetworkTransport.transportError(error))
                        case .cancelled:
                            once.resume(with: .failure(TransportError.closed))
                        default:
                            break
                        }
                    }
                    queue.asyncAfter(deadline: .now() + AppleNetworkTransport.dispatchInterval(timeout)) { fail(.timedOut) }
                    connection.start(queue: queue)
                }
            } onCancel: {
                connection.cancel()
            }
        } catch {
            connection.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        connection.stateUpdateHandler = nil
        return outcome
    }

    func receive(maximumLength: Int) async throws -> Data? {
        guard maximumLength > 0 else { throw TransportError.failed("maximumLength must be positive") }
        if state.isClosed { throw TransportError.closed }
        if state.receivedEOF { return nil }
        let connection = self.connection
        let state = self.state
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (checked: CheckedContinuation<Data?, any Error>) in
                    Self.receive(on: connection, maximumLength: maximumLength, state: state, continuation: checked)
                }
            } onCancel: {
                state.markClosed()
                connection.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func receive(on connection: NWConnection, maximumLength: Int, state: ConnectionState,
                                continuation: CheckedContinuation<Data?, any Error>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            if state.isClosed {
                // Closed locally (close() or task cancellation): Network.framework may still report EOF or data.
                continuation.resume(throwing: TransportError.closed)
            } else if let data, !data.isEmpty {
                if isComplete { state.markEOF() }
                continuation.resume(returning: data)
            } else if let error {
                continuation.resume(throwing: AppleNetworkTransport.transportError(error))
            } else if isComplete {
                state.markEOF()
                continuation.resume(returning: nil)
            } else {
                receive(on: connection, maximumLength: maximumLength, state: state, continuation: continuation)
            }
        }
    }

    func send(_ data: Data) async throws {
        if state.isClosed { throw TransportError.closed }
        let state = self.state
        try await withCheckedThrowingContinuation { (checked: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    checked.resume(throwing: state.isClosed ? TransportError.closed : AppleNetworkTransport.transportError(error))
                } else {
                    checked.resume()
                }
            })
        }
    }

    func close() {
        state.markClosed()
        connection.cancel()
    }
}

/// Close/EOF flags shared between a connection and its in-flight Network.framework callbacks.
private final class ConnectionState: Sendable {
    private let flags = Mutex((closed: false, receivedEOF: false))

    var isClosed: Bool { flags.withLock { $0.closed } }
    var receivedEOF: Bool { flags.withLock { $0.receivedEOF } }
    func markClosed() { flags.withLock { $0.closed = true } }
    func markEOF() { flags.withLock { $0.receivedEOF = true } }
}
#endif
