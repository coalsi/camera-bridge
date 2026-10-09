import BridgeSupport
import Dispatch
import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SocketAddress: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Whether two host texts name one address (zones ignored, IPv4-mapped IPv6 as IPv4, IPv6 in any spelling).
    public static func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        func bytes(_ host: String) -> [UInt8]? {
            var bare = host
            if bare.hasPrefix("["), bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
            if let percent = bare.firstIndex(of: "%") { bare = String(bare[..<percent]) }
            if bare.contains(":") {
                var raw = in6_addr()
                guard inet_pton(AF_INET6, bare, &raw) == 1 else { return nil }
                let all = withUnsafeBytes(of: raw) { Array($0) }
                if all[0..<10].allSatisfy({ $0 == 0 }), all[10] == 0xFF, all[11] == 0xFF { return Array(all[12..<16]) }
                return all
            }
            var raw = in_addr()
            guard inet_pton(AF_INET, bare, &raw) == 1 else { return nil }
            return withUnsafeBytes(of: raw) { Array($0) }
        }
        if let left = bytes(lhs), let right = bytes(rhs) { return left == right }
        return lhs.lowercased() == rhs.lowercased()
    }

    /// `host:port`, or `[host]:port` for IPv6 literals.
    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum UDPSocketError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The host is not a numeric address of the socket's family.
    case invalidAddress(String)
    /// A system call failed with `errno` = `code`.
    case system(operation: String, code: Int32)
    /// The socket was closed.
    case closed

    public var description: String {
        switch self {
        case .invalidAddress(let host): "invalid address \(host)"
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
        case .closed: "socket closed"
        }
    }
}

/// A UDP endpoint on a BSD socket; incoming datagrams are read by a `DispatchSource` on a private serial queue.
///
/// - `bind(host:port:ipv6:interface:)`: `host` nil binds the wildcard address (IPv6 wildcard sockets are dual-stack);
///   otherwise `host` must be a numeric address of the chosen family. No `SO_REUSEADDR`, so a busy port throws.
///   Send and receive buffers are raised to 1 MiB (best effort). `interface` (and `scope(toInterface:)` later) scopes the
///   socket to one network interface (`IP_BOUND_IF` / `IPV6_BOUND_IF`, `SO_BINDTODEVICE` elsewhere): its packets leave
///   through that interface whatever the routing table prefers, which a source address alone does not guarantee.
/// - `send` never blocks (non-blocking socket); a full buffer throws `.system(code: EAGAIN/ENOBUFS)`.
///   On an IPv6 socket an IPv4 literal is sent to its IPv4-mapped address.
/// - `datagrams` is one stream per socket (iterate it once); it keeps the newest 1024 undelivered datagrams and
///   finishes as soon as the socket is closed (datagrams already buffered are still delivered). Senders on
///   IPv4-mapped addresses are reported as IPv4.
/// - Reading: each readiness event reads at most `readBatchLimit` datagrams and stops early once closing has begun
///   (the source fires again while data remains), so a sender flooding the port cannot hold up closing.
/// - `close()` is idempotent: later sends throw `.closed`, `datagrams` finishes, and it returns once the descriptor is
///   closed (at most one datagram read later; at once on the socket's own queue). Actors and deinit use
///   `closeWithoutWaiting()`, which never blocks, and `waitUntilClosed()` to await the descriptor.
public final class UDPSocket: Sendable {
    public let localPort: UInt16
    public let datagrams: AsyncStream<(data: Data, from: SocketAddress)>
    /// How a live stream's sockets were set up and who hears about transport trouble (`LiveStreamTransport`); unused by
    /// other callers.
    public let transport = LiveStreamTransport()

    /// The most datagrams one readiness event reads.
    static let readBatchLimit = 64

    private let descriptor: Int32
    private let family: Int32
    /// Serial queue of the read source (internal for tests).
    let queue: DispatchQueue
    private let state: Mutex<State>
    private let resolved = Mutex<(address: SocketAddress, storage: sockaddr_storage, length: socklen_t)?>(nil)
    private let continuation: AsyncStream<(data: Data, from: SocketAddress)>.Continuation
    /// Set when closing begins; the read handler checks it before every read.
    private let closing: ClosingFlag
    /// Entered at init, left by the cancel handler once the descriptor is closed.
    private let open = DispatchGroup()

    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    private struct State {
        var closed = false
        var source: (any DispatchSourceRead)?
        /// The interface the socket is scoped to (`scope(toInterface:)`), nil when unscoped.
        var interface: String?
        /// Send attempts so far, for `injectSendFailures`.
        var attempts = 0
    }

    /// Tests: fails a send attempt with the errno this returns for the (1-based) attempt number, nil lets it through.
    private let fault = Mutex<(@Sendable (Int) -> Int32?)?>(nil)

    private init(descriptor: Int32, family: Int32, localPort: UInt16) {
        self.descriptor = descriptor
        self.family = family
        self.localPort = localPort
        let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.UDPSocket.\(localPort)")
        self.queue = queue
        let (stream, continuation) = AsyncStream.makeStream(of: (data: Data, from: SocketAddress).self, bufferingPolicy: .bufferingNewest(1_024))
        datagrams = stream
        self.continuation = continuation
        let closing = ClosingFlag()
        self.closing = closing
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        state = Mutex(State(closed: false, source: source))
        source.setEventHandler { Self.read(descriptor: descriptor, until: closing, into: continuation) }
        let open = self.open
        open.enter()
        source.setCancelHandler {
            closeDescriptor(descriptor)
            continuation.finish()
            open.leave()
        }
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(queue))
        source.activate()
    }

    deinit {
        closeWithoutWaiting()
    }

    public static func bind(host: String? = nil, port: UInt16 = 0, ipv6: Bool = false, interface: String? = nil) throws -> UDPSocket {
        let family = ipv6 ? AF_INET6 : AF_INET
        var address = try host.map { try resolve(host: $0, port: port, family: family, passive: true) } ?? wildcard(port: port, family: family)
        let descriptor = socket(family, datagramSocketType, 0)
        guard descriptor >= 0 else { throw UDPSocketError.system(operation: "socket", code: errno) }
        do {
            try configure(descriptor, family: family, dualStack: host == nil)
            if let interface { try scope(descriptor, family: family, to: interface) }
            let bound = withUnsafePointer(to: &address.storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemBind(descriptor, $0, address.length) }
            }
            guard bound == 0 else { throw UDPSocketError.system(operation: "bind", code: errno) }
            var local = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let named = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            guard named == 0, let localAddress = socketAddress(local) else { throw UDPSocketError.system(operation: "getsockname", code: errno) }
            let created = UDPSocket(descriptor: descriptor, family: family, localPort: localAddress.port)
            created.state.withLock { $0.interface = interface }
            return created
        } catch {
            closeDescriptor(descriptor)
            throw error
        }
    }

    public func send(_ data: Data, to address: SocketAddress) throws {
        var destination = try destination(for: address)
        try state.withLock { state in
            guard !state.closed else { throw UDPSocketError.closed }
            state.attempts += 1
            if let code = fault.withLock({ $0 })?(state.attempts) { throw UDPSocketError.system(operation: "sendto", code: code) }
            let sent = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination.storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, destination.length) }
                }
            }
            guard sent >= 0 else { throw UDPSocketError.system(operation: "sendto", code: errno) }
        }
    }

    /// The interface the socket is scoped to, nil when it is not.
    public var scopedInterface: String? { state.withLock { $0.interface } }

    /// Scopes the socket to the interface `name` ("en0"), or removes the scope when `name` is nil. Packets sent from now on
    /// leave through that interface; the bound address is unchanged. Throws `.system` when there is no such interface.
    public func scope(toInterface name: String?) throws {
        try state.withLock { state in
            guard !state.closed else { throw UDPSocketError.closed }
            try Self.scope(descriptor, family: family, to: name)
            state.interface = name
        }
    }

    /// Test seam: from now on `failure(attempt)` decides whether a send attempt fails with an errno instead of going out.
    func injectSendFailures(_ failure: (@Sendable (Int) -> Int32?)?) {
        fault.withLock { $0 = failure }
    }

    /// Closes the socket; returns once the descriptor is closed. The read handler checks for closing before every read,
    /// so this waits for at most one datagram (never on the socket's own queue). Every caller waits, also a second one.
    public func close() {
        closeWithoutWaiting()
        if DispatchQueue.getSpecific(key: Self.queueKey) != ObjectIdentifier(queue) {
            open.wait()
        }
    }

    /// `close()` without waiting for the descriptor, for actors and deinit: later sends throw `.closed` and `datagrams`
    /// finishes at once; the descriptor is closed on the socket's queue right after (see `waitUntilClosed()`).
    func closeWithoutWaiting() {
        let source = state.withLock { state -> (any DispatchSourceRead)? in
            state.closed = true
            defer { state.source = nil }
            return state.source
        }
        closing.set()
        continuation.finish()
        source?.cancel()
    }

    /// Returns once the descriptor is closed (immediately if it already is). Only closing closes it, so await this
    /// after `close()`/`closeWithoutWaiting()`.
    func waitUntilClosed() async {
        let open = self.open
        await withCheckedContinuation { continuation in open.notify(queue: .global()) { continuation.resume() } }
    }

    // MARK: Receiving

    /// Reads up to `readBatchLimit` datagrams, stopping early at EAGAIN or once `closing` is set. The source is level
    /// triggered: it fires again while datagrams remain, so a bounded batch loses nothing.
    private static func read(descriptor: Int32, until closing: ClosingFlag,
                             into continuation: AsyncStream<(data: Data, from: SocketAddress)>.Continuation) {
        withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 16) { buffer in
            var reads = 0
            while reads < readBatchLimit, !closing.isSet {
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let received = withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, buffer.baseAddress, buffer.count, 0, $0, &length) }
                }
                if received < 0 {
                    if errno == EINTR { continue }
                    return   // EAGAIN: drained; other errors: wait for the next readiness event
                }
                reads += 1
                guard let from = socketAddress(storage), let base = buffer.baseAddress else { continue }
                continuation.yield((Data(bytes: base, count: received), from))
            }
        }
    }

    // MARK: Addresses

    private func destination(for address: SocketAddress) throws -> (storage: sockaddr_storage, length: socklen_t) {
        if let cached = resolved.withLock({ $0 }), cached.address == address { return (cached.storage, cached.length) }
        let result = try Self.resolve(host: address.host, port: address.port, family: family, passive: false)
        resolved.withLock { $0 = (address, result.storage, result.length) }
        return result
    }

    /// The wildcard address of `family` (internal for tests: the app binds it for every live view, loopback tests never do).
    static func wildcard(port: UInt16, family: Int32) -> (storage: sockaddr_storage, length: socklen_t) {
        var storage = sockaddr_storage()
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: &address) { Array($0) }) }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: 0)
        withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: &address) { Array($0) }) }
        return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
    }

    /// Numeric addresses only (no DNS; IPv6 may carry a `%scope`); on IPv6 sockets IPv4 literals map to ::ffff:a.b.c.d.
    /// Internal for tests.
    static func resolve(host: String, port: UInt16, family: Int32, passive: Bool) throws -> (storage: sockaddr_storage, length: socklen_t) {
        if family == AF_INET6, !passive {
            var ipv4 = in_addr()
            if inet_pton(AF_INET, host, &ipv4) == 1 {
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                withUnsafeMutableBytes(of: &address.sin6_addr) { bytes in
                    for index in 0..<10 { bytes[index] = 0 }
                    bytes[10] = 0xFF
                    bytes[11] = 0xFF
                    withUnsafeBytes(of: &ipv4) { for index in 0..<4 { bytes[12 + index] = $0[index] } }
                }
                var storage = sockaddr_storage()
                withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: &address) { Array($0) }) }
                return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = datagramSocketType
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV | (passive ? AI_PASSIVE : 0)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { throw UDPSocketError.invalidAddress(host) }
        defer { freeaddrinfo(list) }
        guard let address = list.pointee.ai_addr, list.pointee.ai_family == family else { throw UDPSocketError.invalidAddress(host) }
        var storage = sockaddr_storage()
        let length = min(Int(list.pointee.ai_addrlen), MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: length)) }
        return (storage, socklen_t(length))
    }

    /// The address in `storage`; IPv4-mapped IPv6 addresses are reported as IPv4. Internal for tests.
    static func socketAddress(_ storage: sockaddr_storage) -> SocketAddress? {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafeBytes(of: &storage) { raw -> SocketAddress? in
                var address = raw.loadUnaligned(as: sockaddr_in.self)
                guard let host = presentation(family: AF_INET, of: &address.sin_addr, capacity: Int(INET_ADDRSTRLEN)) else { return nil }
                return SocketAddress(host: host, port: UInt16(bigEndian: address.sin_port))
            }
        case AF_INET6:
            return withUnsafeBytes(of: &storage) { raw -> SocketAddress? in
                var address = raw.loadUnaligned(as: sockaddr_in6.self)
                let port = UInt16(bigEndian: address.sin6_port)
                let bytes = withUnsafeBytes(of: &address.sin6_addr) { Array($0) }
                if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                    return SocketAddress(host: bytes[12...].map(String.init).joined(separator: "."), port: port)
                }
                guard var host = presentation(family: AF_INET6, of: &address.sin6_addr, capacity: Int(INET6_ADDRSTRLEN)) else { return nil }
                if address.sin6_scope_id != 0 {
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(address.sin6_scope_id, &name) != nil {
                        host += "%" + String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                }
                return SocketAddress(host: host, port: port)
            }
        default:
            return nil
        }
    }

    private static func presentation<T>(family: Int32, of address: inout T, capacity: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: capacity + 1)
        let converted = withUnsafeBytes(of: &address) { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(capacity)) != nil }
        guard converted else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `IP_BOUND_IF` / `IPV6_BOUND_IF` (Darwin) or `SO_BINDTODEVICE` for `name`; nil clears it (index 0). An IPv6 socket is
    /// scoped for both families, since its IPv4-mapped traffic goes through the IPv4 option.
    private static func scope(_ descriptor: Int32, family: Int32, to name: String?) throws {
        var index: UInt32 = 0
        if let name {
            index = if_nametoindex(name)
            guard index != 0 else { throw UDPSocketError.system(operation: "if_nametoindex", code: ENXIO) }
        }
        #if canImport(Darwin)
        var value = Int32(index)
        let size = socklen_t(MemoryLayout<Int32>.size)
        if family == AF_INET6 {
            guard setsockopt(descriptor, Int32(IPPROTO_IPV6), IPV6_BOUND_IF, &value, size) == 0 else {
                throw UDPSocketError.system(operation: "setsockopt(IPV6_BOUND_IF)", code: errno)
            }
            _ = setsockopt(descriptor, Int32(IPPROTO_IP), IP_BOUND_IF, &value, size)   // dual-stack IPv4: best effort
        } else {
            guard setsockopt(descriptor, Int32(IPPROTO_IP), IP_BOUND_IF, &value, size) == 0 else {
                throw UDPSocketError.system(operation: "setsockopt(IP_BOUND_IF)", code: errno)
            }
        }
        #else
        var device = [CChar](name?.utf8CString ?? [0])
        guard setsockopt(descriptor, SOL_SOCKET, SO_BINDTODEVICE, &device, socklen_t(name == nil ? 0 : device.count)) == 0 else {
            throw UDPSocketError.system(operation: "setsockopt(SO_BINDTODEVICE)", code: errno)
        }
        #endif
    }

    /// Non-blocking, close-on-exec, 1 MiB buffers; an IPv6 socket is dual stack (IPV6_V6ONLY = 0) when `dualStack`, else
    /// IPv6 only. Internal for tests (they check it on an unbound descriptor).
    static func configure(_ descriptor: Int32, family: Int32, dualStack: Bool) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw UDPSocketError.system(operation: "fcntl", code: errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var bufferSize: Int32 = 1 << 20
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET6 {
            var v6Only: Int32 = dualStack ? 0 : 1
            _ = setsockopt(descriptor, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
        }
    }
}

/// Written by `closeWithoutWaiting()` on any thread, read by the read handler on the socket's queue.
private final class ClosingFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .acquiring) }
    func set() { value.store(true, ordering: .releasing) }
}

/// `SOCK_DGRAM` as an `Int32` on every platform (internal for tests).
#if canImport(Glibc)
let datagramSocketType = Int32(SOCK_DGRAM.rawValue)
#else
let datagramSocketType = SOCK_DGRAM
#endif

private func systemBind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.bind(descriptor, address, length)
    #else
    Glibc.bind(descriptor, address, length)
    #endif
}

private func closeDescriptor(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #else
    _ = Glibc.close(descriptor)
    #endif
}
