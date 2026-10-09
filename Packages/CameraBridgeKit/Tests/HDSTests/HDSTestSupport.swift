import BridgeSupport
import Foundation
import HAP
import Synchronization
@testable import HDS

/// In-test `HAPSessionHandle`: a fixed shared secret and a manual `close()`.
final class FakeHAPSession: HAPSessionHandle {
    let id = UUID()
    let controllerID = UUID().uuidString
    let isAdmin = true
    let sharedSecret: Data
    let localAddress = "127.0.0.1"
    let remoteAddress = "127.0.0.1"
    let isIPv6 = false
    private let state = Mutex<(closed: Bool, handlers: [@Sendable () -> Void])>((false, []))

    init(sharedSecret: Data = randomBytes(32)) {
        self.sharedSecret = sharedSecret
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let alreadyClosed = state.withLock { state in
            if !state.closed { state.handlers.append(handler) }
            return state.closed
        }
        if alreadyClosed { handler() }
    }

    /// Simulates the HAP connection closing: runs every registered handler once.
    func close() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.closed else { return [] }
            state.closed = true
            defer { state.handlers = [] }
            return state.handlers
        }
        handlers.forEach { $0() }
    }
}

func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}

/// Thread-safe FIFO a handler appends to and a test polls.
actor Mailbox<Item: Sendable> {
    private var items: [Item] = []

    func append(_ item: Item) {
        items.append(item)
    }

    var count: Int { items.count }
    var all: [Item] { items }

    /// The oldest item, waiting up to `timeout`; nil if none arrives.
    func next(timeout: Duration = .seconds(5)) async -> Item? {
        let deadline = ContinuousClock.now + timeout
        while items.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return items.isEmpty ? nil : items.removeFirst()
    }
}

struct TestTimeout: Error {}

/// A one-way latch: `wait()` suspends until `open()`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Observes whether an object has been deallocated.
final class WeakReference<Object: AnyObject & Sendable>: Sendable {
    weak let object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

/// Bounds a test client's `receive`. Deliberately a task group, not BridgeSupport's `withDeadline`: the group waits for
/// the cancelled receive to end, so an abandoned receive can never consume a later frame from the client's buffer
/// (`AppleTCPConnection.receive` honours cancellation, so the bound holds).
func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TestTimeout()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TestTimeout() }
        return result
    }
}

/// Transport wrapper that counts `listen` calls (lazy binding), records the loopback flag and tracks each listener's
/// `close()`.
final class CountingTransport: NetworkTransport {
    private let base: any NetworkTransport
    private let state = Mutex<(loopbackOnly: [Bool], listeners: [TrackedListener])>(([], []))

    init(_ base: any NetworkTransport) {
        self.base = base
    }

    var listenCount: Int { state.withLock { $0.loopbackOnly.count } }
    var loopbackFlags: [Bool] { state.withLock { $0.loopbackOnly } }
    var listeners: [TrackedListener] { state.withLock { $0.listeners } }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        state.withLock { $0.loopbackOnly.append(loopbackOnly) }
        let listener = TrackedListener(try await base.listen(port: port, loopbackOnly: loopbackOnly))
        state.withLock { $0.listeners.append(listener) }
        return listener
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        try await base.connect(host: host, port: port, timeout: timeout)
    }
}

/// Forwards to a real listener and records whether its owner closed it.
final class TrackedListener: TCPListener {
    private let base: any TCPListener
    private let closed = Mutex(false)

    init(_ base: any TCPListener) {
        self.base = base
    }

    var port: UInt16 { base.port }
    var connections: AsyncStream<any TCPConnection> { base.connections }
    var isClosed: Bool { closed.withLock { $0 } }

    func close() {
        closed.withLock { $0 = true }
        base.close()
    }
}

/// Minimal HDS controller built only from the public `HDSFrameCodec` API; it parses frame headers itself.
actor HDSLoopbackClient {
    let connection: any TCPConnection
    let accessoryToController: Data
    let controllerToAccessory: Data
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var buffer: [UInt8] = []

    init(connection: any TCPConnection, sharedSecret: Data, controllerKeySalt: Data, accessoryKeySalt: Data) {
        self.connection = connection
        let keys = HDSFrameCodec.deriveKeys(sharedSecret: sharedSecret, controllerKeySalt: controllerKeySalt, accessoryKeySalt: accessoryKeySalt)
        accessoryToController = keys.accessoryToController
        controllerToAccessory = keys.controllerToAccessory
    }

    static func connect(transport: any NetworkTransport, port: UInt16, sharedSecret: Data, controllerKeySalt: Data,
                        accessoryKeySalt: Data) async throws -> HDSLoopbackClient {
        let connection = try await transport.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        return HDSLoopbackClient(connection: connection, sharedSecret: sharedSecret, controllerKeySalt: controllerKeySalt,
                                 accessoryKeySalt: accessoryKeySalt)
    }

    /// Seals `message` with the next controller→accessory counter without sending it.
    func seal(_ message: HDSMessage) throws -> Data {
        let frame = try HDSFrameCodec.sealFrame(try HDSFrameCodec.encodePayload(message), key: controllerToAccessory, counter: sendCounter)
        sendCounter += 1
        return frame
    }

    /// Seals with an explicit counter (replay/tamper tests); does not advance the counter.
    func seal(_ message: HDSMessage, counter: UInt64) throws -> Data {
        try HDSFrameCodec.sealFrame(try HDSFrameCodec.encodePayload(message), key: controllerToAccessory, counter: counter)
    }

    func send(_ message: HDSMessage) async throws {
        try await connection.send(try seal(message))
    }

    /// Seals an arbitrary (possibly malformed) payload with the next counter and sends it.
    func sendPayload(_ payload: Data) async throws {
        let frame = try HDSFrameCodec.sealFrame(payload, key: controllerToAccessory, counter: sendCounter)
        sendCounter += 1
        try await connection.send(frame)
    }

    func sendRaw(_ bytes: Data) async throws {
        try await connection.send(bytes)
    }

    /// Next message from the accessory; nil at EOF.
    func receive() async throws -> HDSMessage? {
        guard try await fill(4) else { return nil }
        let length = Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
        guard try await fill(4 + length + 16) else { return nil }
        let header = Data(buffer[0..<4])
        let body = Data(buffer[4..<(4 + length + 16)])
        buffer.removeFirst(4 + length + 16)
        let payload = try HDSFrameCodec.openFrame(header: header, body: body, key: accessoryToController, counter: receiveCounter)
        receiveCounter += 1
        return try HDSFrameCodec.decodePayload(payload)
    }

    struct UnexpectedEOF: Error {}

    func receiveMessage(timeout: Duration = .seconds(5)) async throws -> HDSMessage {
        let message = try await withTimeout(timeout) { try await self.receive() }
        guard let message else { throw UnexpectedEOF() }
        return message
    }

    /// Sends `control/hello` and returns the accessory's response.
    func hello(id: Int64 = 1) async throws -> HDSMessage {
        try await send(HDSMessage(kind: .request(id: id), protocolName: "control", topic: "hello"))
        return try await receiveMessage()
    }

    /// True if the accessory closes the connection (EOF or reset) within `timeout`, without sending anything.
    func isDropped(within timeout: Duration = .seconds(5)) async -> Bool {
        do {
            return try await withTimeout(timeout) { try await self.receive() } == nil
        } catch is TransportError {
            return true
        } catch {
            return false
        }
    }

    func close() {
        connection.close()
    }

    private func fill(_ count: Int) async throws -> Bool {
        while buffer.count < count {
            guard let chunk = try await connection.receive(maximumLength: 65536) else { return false }
            buffer.append(contentsOf: chunk)
        }
        return true
    }
}
