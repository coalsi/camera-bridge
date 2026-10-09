import BridgeSupport
import Foundation
import HDS

struct TestTimeout: Error {}

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

/// Minimal HDS controller built only from the public `HDSFrameCodec` API, for the handler-level recording tests: it runs
/// over any `TCPConnection` (also an in-memory `FakeTCPConnection` whose sends can stall), reads frames strictly in
/// order and can put several frames in one TCP write (`sendTogether`). End-to-end tests use TestSupport's
/// `HDSTestClient` instead.
actor HDSLoopbackClient {
    let connection: any TCPConnection
    let accessoryToController: Data
    let controllerToAccessory: Data
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var buffer: [UInt8] = []
    private var nextRequestID: Int64 = 1

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

    func send(_ message: HDSMessage) async throws {
        let frame = try HDSFrameCodec.sealFrame(try HDSFrameCodec.encodePayload(message), key: controllerToAccessory, counter: sendCounter)
        sendCounter += 1
        try await connection.send(frame)
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
    func hello() async throws -> HDSMessage {
        try await request(protocol: "control", topic: "hello", body: HDSDictionary())
    }

    /// Sends a request and returns the next message (the response, when nothing else is in flight).
    func request(protocol protocolName: String, topic: String, body: HDSDictionary) async throws -> HDSMessage {
        let id = nextRequestID
        nextRequestID += 1
        try await send(HDSMessage(kind: .request(id: id), protocolName: protocolName, topic: topic, body: body))
        return try await receiveMessage()
    }

    func event(protocol protocolName: String, topic: String, body: HDSDictionary) async throws {
        try await send(HDSMessage(kind: .event, protocolName: protocolName, topic: topic, body: body))
    }

    /// A request with the next request id, to send with `sendTogether`.
    func nextRequest(protocol protocolName: String, topic: String, body: HDSDictionary) -> HDSMessage {
        defer { nextRequestID += 1 }
        return HDSMessage(kind: .request(id: nextRequestID), protocolName: protocolName, topic: topic, body: body)
    }

    /// Seals `messages` (consecutive counters) and sends them in a single TCP write, so the accessory reads them back
    /// to back.
    func sendTogether(_ messages: [HDSMessage]) async throws {
        var frames = Data()
        for message in messages {
            frames += try HDSFrameCodec.sealFrame(try HDSFrameCodec.encodePayload(message), key: controllerToAccessory, counter: sendCounter)
            sendCounter += 1
        }
        try await connection.send(frames)
    }

    /// True if the accessory closes the connection (EOF or reset) within `timeout`.
    func isDropped(within timeout: Duration = .seconds(5)) async -> Bool {
        do {
            while true {
                guard try await withTimeout(timeout, { try await self.receive() }) != nil else { return true }
            }
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

/// A received `dataSend/data` event, flattened.
struct DataSendChunk: Equatable {
    var streamID: Int64
    var data: Data
    var dataType: String
    var sequence: Int64
    var chunk: Int64
    var isLastChunk: Bool
    var totalSize: Int64?
    var endOfStream: Bool?

    init?(_ message: HDSMessage) {
        guard message.kind == .event, message.protocolName == "dataSend", message.topic == "data",
              case .int(let streamID)? = message.body["streamId"],
              case .array(let packets)? = message.body["packets"], packets.count == 1,
              case .dictionary(let packet) = packets[0],
              case .data(let data)? = packet["data"],
              case .dictionary(let metadata)? = packet["metadata"],
              case .string(let dataType)? = metadata["dataType"],
              case .int(let sequence)? = metadata["dataSequenceNumber"],
              case .int(let chunk)? = metadata["dataChunkSequenceNumber"],
              case .bool(let isLastChunk)? = metadata["isLastDataChunk"] else { return nil }
        self.streamID = streamID
        self.data = data
        self.dataType = dataType
        self.sequence = sequence
        self.chunk = chunk
        self.isLastChunk = isLastChunk
        if case .int(let total)? = metadata["dataTotalSize"] { totalSize = total }
        if case .bool(let end)? = message.body["endOfStream"] { endOfStream = end }
    }
}
