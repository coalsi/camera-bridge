#if os(Linux)
import BridgeSupport
import Dispatch
import Foundation
import Glibc
import Synchronization

/// `NetworkTransport` over POSIX sockets: non-blocking descriptors, readiness through Dispatch sources, TCP with `TCP_NODELAY`.
///
/// - `listen(port:loopbackOnly:)` binds 127.0.0.1 when `loopbackOnly`, else every interface (one dual-stack IPv6 socket, or
///   IPv4 only where the machine has no IPv6), with address reuse (a fixed HAP port can be rebound right after a restart). A
///   port that another listening socket holds is refused with `.addressInUse` (the kernel's bind check).
/// - `connect` tries every address the host resolves to, in turn, within `timeout`; refusal fails fast.
/// - Connections report bare IP literals (no port, no IPv6 zone; IPv4-mapped IPv6 as IPv4).
/// - Cancelling a task blocked in `receive` or `connect` closes the connection and throws `CancellationError`.
public final class LinuxNetworkTransport: NetworkTransport {
    public init() {}

    public func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        try LinuxTCPListener.start(port: port, loopbackOnly: loopbackOnly)
    }

    public func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        try await LinuxTCPConnection.connect(host: host, port: port, timeout: timeout)
    }

    static func transportError(errno code: Int32) -> TransportError {
        switch code {
        case ECONNREFUSED: .connectionRefused
        case ETIMEDOUT: .timedOut
        case EADDRINUSE: .addressInUse
        case ECANCELED, ECONNRESET, ECONNABORTED, ENOTCONN, EPIPE, ESHUTDOWN, EBADF: .closed
        default: .failed("\(String(cString: strerror(code))) (\(code))")
        }
    }

    /// Dead-peer detection of the connections a listener accepts (HAP and HDS): a controller that vanished without a FIN
    /// or RST (Wi-Fi dropped, the hub was unplugged) is noticed after `keepaliveIdle` + `keepaliveCount` x
    /// `keepaliveInterval` = 60 s of silence, or after 20 s of unacknowledged retransmissions (`TCP_USER_TIMEOUT`), and its
    /// connection fails, which frees the stream session, HDS connection and recording slot it held.
    static let keepaliveIdle: Int32 = 30
    static let keepaliveInterval: Int32 = 10
    static let keepaliveCount: Int32 = 3
    static let userTimeoutMilliseconds: Int32 = 20_000

    static func setOption(_ descriptor: Int32, level: Int32, name: Int32, value: Int32) {
        var value = value
        _ = setsockopt(descriptor, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `TCP_NODELAY` and, for accepted connections, dead-peer detection.
    static func configureTCP(_ descriptor: Int32, keepalive: Bool) {
        setOption(descriptor, level: Int32(IPPROTO_TCP), name: TCP_NODELAY, value: 1)
        guard keepalive else { return }
        setOption(descriptor, level: SOL_SOCKET, name: SO_KEEPALIVE, value: 1)
        setOption(descriptor, level: Int32(IPPROTO_TCP), name: TCP_KEEPIDLE, value: keepaliveIdle)
        setOption(descriptor, level: Int32(IPPROTO_TCP), name: TCP_KEEPINTVL, value: keepaliveInterval)
        setOption(descriptor, level: Int32(IPPROTO_TCP), name: TCP_KEEPCNT, value: keepaliveCount)
        setOption(descriptor, level: Int32(IPPROTO_TCP), name: TCP_USER_TIMEOUT, value: userTimeoutMilliseconds)
    }

    /// `O_NONBLOCK` and `FD_CLOEXEC` on an accepted descriptor.
    static func makeNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    static let streamType = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_NONBLOCK.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
}

// MARK: - Listener

final class LinuxTCPListener: TCPListener {
    let port: UInt16
    let connections: AsyncStream<any TCPConnection>
    private let continuation: AsyncStream<any TCPConnection>.Continuation
    private let accepting: SourceBox

    private init(port: UInt16, connections: AsyncStream<any TCPConnection>, continuation: AsyncStream<any TCPConnection>.Continuation,
                 accepting: SourceBox) {
        self.port = port
        self.connections = connections
        self.continuation = continuation
        self.accepting = accepting
    }

    deinit {
        close()
    }

    func close() {
        accepting.cancel()
        continuation.finish()
    }

    /// The most connections one readiness event accepts (the source is level triggered: it fires again while more wait).
    private static let acceptBatchLimit = 32

    static func start(port: UInt16, loopbackOnly: Bool) throws -> LinuxTCPListener {
        let (descriptor, boundPort) = try bindListener(port: port, loopbackOnly: loopbackOnly)
        let (connections, continuation) = AsyncStream.makeStream(of: (any TCPConnection).self, bufferingPolicy: .bufferingOldest(64))
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: SocketDescriptor.queue)
        let box = SourceBox(source)
        source.setEventHandler {
            for _ in 0..<acceptBatchLimit {
                let accepted = accept(descriptor, nil, nil)
                if accepted >= 0 { LinuxNetworkTransport.makeNonBlocking(accepted) }
                if accepted < 0 {
                    if errno == EINTR { continue }
                    if errno == ECONNABORTED { continue }
                    if errno == EMFILE || errno == ENFILE { Log(category: "transport").warning("Out of file descriptors accepting a connection") }
                    return
                }
                LinuxNetworkTransport.configureTCP(accepted, keepalive: true)
                if case .dropped = continuation.yield(LinuxTCPConnection(socket: SocketDescriptor(accepted))) {
                    // Nobody is taking connections (64 waiting): the new one is closed by its deinit.
                }
            }
        }
        source.setCancelHandler {
            _ = Glibc.close(descriptor)
            continuation.finish()
        }
        source.resume()
        return LinuxTCPListener(port: boundPort, connections: connections, continuation: continuation, accepting: box)
    }

    /// A listening non-blocking socket: 127.0.0.1 when `loopbackOnly`, else dual stack on `::` (IPv4 `0.0.0.0` where there is
    /// no IPv6). Returns its descriptor and bound port.
    private static func bindListener(port: UInt16, loopbackOnly: Bool) throws -> (Int32, UInt16) {
        var families = loopbackOnly ? [AF_INET] : [AF_INET6, AF_INET]
        var failure: TransportError = .failed("no usable address family")
        while let family = families.first {
            families.removeFirst()
            let descriptor = Glibc.socket(family, LinuxNetworkTransport.streamType, 0)
            guard descriptor >= 0 else {
                failure = LinuxNetworkTransport.transportError(errno: errno)
                if errno == EAFNOSUPPORT, !families.isEmpty { continue }
                throw failure
            }
            LinuxNetworkTransport.setOption(descriptor, level: SOL_SOCKET, name: SO_REUSEADDR, value: 1)
            if family == AF_INET6 { LinuxNetworkTransport.setOption(descriptor, level: Int32(IPPROTO_IPV6), name: IPV6_V6ONLY, value: 0) }
            var address = SocketAddresses.local(port: port, family: family, loopback: loopbackOnly)
            let bound = withUnsafePointer(to: &address.storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.bind(descriptor, $0, address.length) }
            }
            guard bound == 0 else {
                let code = errno
                _ = Glibc.close(descriptor)
                failure = LinuxNetworkTransport.transportError(errno: code)
                if (code == EADDRNOTAVAIL || code == EAFNOSUPPORT), !families.isEmpty { continue }   // IPv6 off: try IPv4
                throw failure
            }
            guard listen(descriptor, 128) == 0 else {
                let code = errno
                _ = Glibc.close(descriptor)
                throw LinuxNetworkTransport.transportError(errno: code)
            }
            guard let name = SocketAddresses.name(of: descriptor, peer: false) else {
                _ = Glibc.close(descriptor)
                throw TransportError.failed("getsockname failed")
            }
            return (descriptor, SocketAddresses.port(of: name))
        }
        throw failure
    }
}

// MARK: - Connection

final class LinuxTCPConnection: TCPConnection {
    let id = UUID()
    let localAddress: String
    let remoteAddress: String
    let isIPv6: Bool
    /// The interface of a link-local connection (`TCPConnection.zone`): the peer's zone, else ours.
    let zone: String?
    private let socket: SocketDescriptor
    private let flags = Mutex(Flags())

    private struct Flags {
        var closed = false
        var receivedEOF = false
    }

    /// `socket` must be connected.
    init(socket: SocketDescriptor) {
        self.socket = socket
        let local = socket.withDescriptor { SocketAddresses.name(of: $0, peer: false) }.flatMap { $0 }.flatMap(SocketAddresses.address(of:))
        let remote = socket.withDescriptor { SocketAddresses.name(of: $0, peer: true) }.flatMap { $0 }.flatMap(SocketAddresses.address(of:))
        localAddress = local?.host ?? ""
        remoteAddress = remote?.host ?? ""
        isIPv6 = remote?.isIPv6 ?? false
        zone = remote?.zone ?? local?.zone
    }

    deinit {
        socket.close()
    }

    /// The local TCP port (internal, for tests; `localAddress` carries no port).
    var localPort: UInt16? {
        socket.withDescriptor { SocketAddresses.name(of: $0, peer: false) }.flatMap { $0 }.map(SocketAddresses.port(of:))
    }

    /// An integer socket option (internal, for tests).
    func socketOption(level: Int32, name: Int32) -> Int32? {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = socket.withDescriptor { getsockopt($0, level, name, &value, &length) }
        return result == 0 ? value : nil
    }

    // MARK: Connecting

    static func connect(host: String, port: UInt16, timeout: Duration) async throws -> LinuxTCPConnection {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, port != 0 else { throw TransportError.failed("invalid address \(host):\(port)") }
        let deadline = ContinuousClock.now + timeout
        let addresses = try await resolve(trimmed, port: port, timeout: timeout)
        guard !addresses.isEmpty else { throw TransportError.failed("\(trimmed) could not be resolved") }
        var failure: TransportError = .timedOut
        for address in addresses {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw TransportError.timedOut }
            do {
                return try await attempt(address, timeout: remaining)
            } catch let error as TransportError {
                failure = error
                if error == .timedOut { throw error }   // the whole time was used
            }
        }
        throw failure
    }

    private typealias ResolvedAddress = (storage: sockaddr_storage, length: socklen_t, family: Int32)

    /// Numeric addresses are used as they are; a name is looked up off the cooperative pool, within `timeout`.
    private static func resolve(_ host: String, port: UInt16, timeout: Duration) async throws -> [ResolvedAddress] {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if let numeric = SocketAddresses.numeric(host: bare, port: port) { return [numeric] }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ResolvedAddress], any Error>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(with: .success(SocketAddresses.resolve(host: bare, port: port)))
            }
            SocketDescriptor.queue.asyncAfter(deadline: .now() + SocketDescriptor.dispatchInterval(timeout)) {
                once.resume(with: .failure(TransportError.timedOut))
            }
        }
    }

    private static func attempt(_ address: ResolvedAddress, timeout: Duration) async throws -> LinuxTCPConnection {
        let descriptor = Glibc.socket(address.family, LinuxNetworkTransport.streamType, 0)
        guard descriptor >= 0 else { throw LinuxNetworkTransport.transportError(errno: errno) }
        LinuxNetworkTransport.configureTCP(descriptor, keepalive: false)
        let handle = SocketDescriptor(descriptor)
        var storage = address.storage
        let started = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(descriptor, $0, address.length) }
        }
        let code = errno
        do {
            if started != 0 {
                guard code == EINPROGRESS else { throw LinuxNetworkTransport.transportError(errno: code) }
                try await withTaskCancellationHandler {
                    try await handle.wait(.writable, timeout: timeout)
                } onCancel: {
                    handle.close()
                }
                var pending: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard handle.withDescriptor({ getsockopt($0, SOL_SOCKET, SO_ERROR, &pending, &length) }) == 0 else { throw TransportError.closed }
                guard pending == 0 else { throw LinuxNetworkTransport.transportError(errno: pending) }
            }
        } catch {
            handle.close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        return LinuxTCPConnection(socket: handle)
    }

    // MARK: Receiving and sending

    private enum ReceiveOutcome {
        case data(Data), endOfFile, wouldBlock, failed(Int32)
    }

    /// The most one `receive` takes from the socket at once.
    private static let receiveLimit = 64 * 1024

    func receive(maximumLength: Int) async throws -> Data? {
        guard maximumLength > 0 else { throw TransportError.failed("maximumLength must be positive") }
        let size = min(maximumLength, Self.receiveLimit)
        do {
            while true {
                if flags.withLock({ $0.closed }) { throw TransportError.closed }
                if flags.withLock({ $0.receivedEOF }) { return nil }
                let outcome = socket.withDescriptor { descriptor -> ReceiveOutcome in
                    withUnsafeTemporaryAllocation(byteCount: size, alignment: 1) { buffer in
                        while true {
                            let count = recv(descriptor, buffer.baseAddress, size, 0)
                            if count > 0 { return .data(Data(bytes: buffer.baseAddress!, count: count)) }
                            if count == 0 { return .endOfFile }
                            if errno == EINTR { continue }
                            if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
                            return .failed(errno)
                        }
                    }
                } ?? .failed(EBADF)
                switch outcome {
                case .data(let data):
                    return data
                case .endOfFile:
                    flags.withLock { $0.receivedEOF = true }
                    return nil
                case .wouldBlock:
                    try await waitUntil(.readable)
                case .failed(let code):
                    throw flags.withLock({ $0.closed }) ? TransportError.closed : LinuxNetworkTransport.transportError(errno: code)
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func send(_ data: Data) async throws {
        var offset = 0
        let total = data.count
        do {
            while offset < total {
                if flags.withLock({ $0.closed }) { throw TransportError.closed }
                let result: Int = socket.withDescriptor { descriptor in
                    data.withUnsafeBytes { bytes in
                        while true {
                            let sent = Glibc.send(descriptor, bytes.baseAddress! + offset, total - offset, Int32(MSG_NOSIGNAL))
                            if sent >= 0 { return sent }
                            if errno == EINTR { continue }
                            if errno == EAGAIN || errno == EWOULDBLOCK { return -Int(EAGAIN) }
                            return -Int(errno)
                        }
                    }
                } ?? -Int(EBADF)
                if result >= 0 {
                    offset += result
                } else if result == -Int(EAGAIN) {
                    try await waitUntil(.writable)
                } else {
                    throw flags.withLock({ $0.closed }) ? TransportError.closed : LinuxNetworkTransport.transportError(errno: Int32(-result))
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Waits for readiness; cancelling the task closes the connection (as the macOS transport does).
    private func waitUntil(_ interest: SocketDescriptor.Interest) async throws {
        try await withTaskCancellationHandler {
            do {
                // Bounded, so a readiness event that went missing delays the next system call by 250 ms instead of forever.
                try await socket.wait(interest, timeout: .milliseconds(250))
            } catch TransportError.timedOut {
                return   // (the callers retry their system call)
            }
        } onCancel: {
            close()
        }
    }

    func close() {
        flags.withLock { $0.closed = true }
        socket.close()
    }
}
#endif
