// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// (Controller side of lib/datastream/DataStreamServer.ts framing and the HKSV dataSend flow of
// lib/camera/RecordingManagement.ts; research brief §3.8.)

import BridgeSupport
import Foundation
import HDS

/// Controller side of a HomeKit Data Stream connection, built only from `HDSFrameCodec`: frame crypto with its own
/// counters, `control/hello`, requests with id matching, an event queue, and the HKSV `dataSend` flow
/// (`open` → `data` events reassembled into init + fragments → `ack` / `close`).
///
/// Safe for concurrent callers: every frame is sealed with the next nonce counter and queued in the same actor turn,
/// and one writer sends the queue in order (the accessory drops the connection at the first frame that does not
/// decrypt with the counter it expects). Waits end with `CancellationError` when the caller is cancelled.
/// Requests from the accessory are queued (`nextIncomingRequest`) and never answered automatically.
public actor HDSTestClient {
    /// Default `eventBufferLimit`: events kept for `nextEvent` that nobody has taken yet.
    public static let defaultEventBufferLimit = 512

    public nonisolated let host: String
    public nonisolated let port: UInt16
    public private(set) var isClosed = false
    /// Why the connection ended (nil while open or after `close()`).
    public private(set) var closeError: (any Error)?
    /// Unclaimed events kept at most (the oldest are dropped beyond it; e.g. data events still arriving after
    /// `receiveRecording` stopped at `maximumFragments`). Change it with `setEventBufferLimit`.
    public private(set) var eventBufferLimit = HDSTestClient.defaultEventBufferLimit
    /// Unclaimed events dropped because the buffer was full.
    public private(set) var droppedEventCount = 0

    private typealias ResponseWaiter = CheckedContinuation<HDSMessage, any Error>
    private typealias EventWaiter = (id: UUID, filter: @Sendable (HDSMessage) -> Bool, continuation: CheckedContinuation<HDSMessage, any Error>)

    /// Who hears about a queued frame's write: a caller waiting for it, or the request it carries.
    private enum SendCompletion {
        case caller(CheckedContinuation<Void, any Error>)
        case request(Int64)
    }

    private let connection: any TCPConnection
    private let accessoryToController: Data
    private let controllerToAccessory: Data
    private let log = Log(category: "HDSTestClient")
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var buffer = Data()
    private var nextRequestID: Int64 = 1
    private var pendingResponses: [Int64: ResponseWaiter] = [:]
    private var events: [HDSMessage] = []
    private var eventWaiters: [EventWaiter] = []
    private var incomingRequests: [HDSMessage] = []
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var requestTimers: [Int64: Task<Void, Never>] = [:]
    private var readTask: Task<Void, Never>?
    /// Sealed frames in counter order, written by one writer at a time (`isWriting`).
    private var sendQueue: [(frame: Data, completion: SendCompletion)] = []
    private var isWriting = false

    private init(host: String, port: UInt16, connection: any TCPConnection, keys: (accessoryToController: Data, controllerToAccessory: Data)) {
        self.host = host
        self.port = port
        self.connection = connection
        accessoryToController = keys.accessoryToController
        controllerToAccessory = keys.controllerToAccessory
    }

    /// Connects to the accessory's HDS port with keys derived from the HAP session's shared secret and both salts.
    /// Call `hello()` next (the accessory drops connections whose first message is anything else).
    public static func connect(host: String, port: UInt16, transport: any NetworkTransport, sharedSecret: Data, controllerKeySalt: Data,
                               accessoryKeySalt: Data, timeout: Duration = .seconds(10)) async throws -> HDSTestClient {
        let connection = try await transport.connect(host: host, port: port, timeout: timeout)
        let keys = HDSFrameCodec.deriveKeys(sharedSecret: sharedSecret, controllerKeySalt: controllerKeySalt, accessoryKeySalt: accessoryKeySalt)
        let client = HDSTestClient(host: host, port: port, connection: connection, keys: keys)
        await client.startReading()
        return client
    }

    public func close() {
        connection.close()
        finish(with: nil)
    }

    deinit {
        readTask?.cancel()
        connection.close()
    }

    // MARK: - Messages

    /// `control/hello`; throws unless the accessory answers with status success.
    public func hello(timeout: Duration = .seconds(10)) async throws {
        let response = try await sendRequest(protocol: "control", topic: "hello", body: HDSDictionary(), timeout: timeout)
        guard case .response(_, .success) = response.kind else { throw HDSTestClientError.unexpectedStatus(response) }
    }

    /// Sends a request and waits for its response (matched by id). A cancelled caller gets `CancellationError` at once
    /// (a late response is dropped by id).
    public func sendRequest(protocol protocolName: String, topic: String, body: HDSDictionary,
                            timeout: Duration = .seconds(10)) async throws -> HDSMessage {
        try Task.checkCancellation()
        if isClosed { throw HDSTestClientError.closed }
        let id = nextRequestID
        nextRequestID += 1
        let payload = try HDSFrameCodec.encodePayload(HDSMessage(kind: .request(id: id), protocolName: protocolName, topic: topic, body: body))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: ResponseWaiter) in
                if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
                if isClosed { return continuation.resume(throwing: closeError ?? HDSTestClientError.closed) }
                let frame: Data
                do {
                    frame = try sealPayload(payload)
                } catch {
                    return continuation.resume(throwing: error)
                }
                pendingResponses[id] = continuation
                requestTimers[id] = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.expireRequest(id)
                }
                enqueue(frame, .request(id))
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    public func sendEvent(protocol protocolName: String, topic: String, body: HDSDictionary) async throws {
        try await write(try HDSFrameCodec.encodePayload(HDSMessage(kind: .event, protocolName: protocolName, topic: topic, body: body)))
    }

    /// Answers a request the accessory sent.
    public func sendResponse(to request: HDSMessage, status: HDSStatus = .success, body: HDSDictionary = HDSDictionary()) async throws {
        guard case .request(let id) = request.kind else { throw HDSTestClientError.notARequest }
        try await write(try HDSFrameCodec.encodePayload(HDSMessage(kind: .response(id: id, status: status), protocolName: request.protocolName,
                                                                   topic: request.topic, body: body)))
    }

    /// Sends a payload sealed with the next counter, as is (malformed-input tests).
    public func sendRawPayload(_ payload: Data) async throws {
        try await write(payload)
    }

    /// The next event matching `protocol`/`topic` (nil = any); non-matching events stay queued.
    public func nextEvent(protocol protocolName: String? = nil, topic: String? = nil, timeout: Duration = .seconds(10)) async throws -> HDSMessage {
        let filter: @Sendable (HDSMessage) -> Bool = { message in
            (protocolName == nil || message.protocolName == protocolName) && (topic == nil || message.topic == topic)
        }
        return try await nextEvent(where: filter, timeout: timeout)
    }

    /// The next event matching `filter` (a queued one first). A cancelled caller gets `CancellationError` at once.
    public func nextEvent(where filter: @escaping @Sendable (HDSMessage) -> Bool, timeout: Duration = .seconds(10)) async throws -> HDSMessage {
        if let index = events.firstIndex(where: filter) { return events.remove(at: index) }
        if isClosed { throw HDSTestClientError.closed }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
                eventWaiters.append((id, filter, continuation))
                timeouts[id] = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.expireEvent(id)
                }
            }
        } onCancel: {
            Task { await self.cancelEventWait(id) }
        }
    }

    /// Events received but not yet taken (at most `eventBufferLimit`, oldest first).
    public var queuedEvents: [HDSMessage] { events }

    /// Sets `eventBufferLimit` (at least 1) and drops the oldest unclaimed events beyond it.
    public func setEventBufferLimit(_ limit: Int) {
        eventBufferLimit = max(1, limit)
        trimEvents()
    }

    /// The oldest request the accessory sent, if any.
    public func nextIncomingRequest() -> HDSMessage? {
        incomingRequests.isEmpty ? nil : incomingRequests.removeFirst()
    }

    /// Waits until the accessory closes the connection; true if it did within `timeout` (false at once if cancelled).
    public func waitUntilClosed(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isClosed, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                break
            }
        }
        return isClosed
    }

    // MARK: - dataSend (HKSV recording)

    /// `dataSend/open` for a recording stream. Returns the accessory's answer; `isAccepted` when HDS status 0 (the body
    /// then has `status: 0`); a refusal carries HDS status 6 and the protocol reason in `status`.
    public func openRecording(streamID: Int64, reason: String? = "motion", type: String = "ipcamera.recording", target: String = "controller",
                              timeout: Duration = .seconds(10)) async throws -> DataSendOpenResult {
        var body = HDSDictionary([("target", .string(target)), ("type", .string(type)), ("streamId", .int(streamID))])
        if let reason { body["reason"] = .string(reason) }
        let response = try await sendRequest(protocol: "dataSend", topic: "open", body: body, timeout: timeout)
        guard case .response(_, let status) = response.kind else { throw HDSTestClientError.unexpectedStatus(response) }
        var protocolReason: HDSProtocolReason?
        if status == .protocolSpecificError, case .int(let raw)? = response.body["status"] { protocolReason = HDSProtocolReason(rawValue: raw) }
        return DataSendOpenResult(status: status, protocolReason: protocolReason, body: response.body)
    }

    /// Receives `dataSend/data` (and `close`) events for `streamID` until `endOfStream`, a `close` from the accessory,
    /// `maximumFragments` fragments, or `duration` elapses. Violations of the chunking rules throw
    /// `DataSendReassembler.Violation`. `eventTimeout` bounds the wait for each event.
    public func receiveRecording(streamID: Int64, maximumFragments: Int? = nil, duration: Duration? = nil,
                                 eventTimeout: Duration = .seconds(10),
                                 onPacket: (@Sendable (DataSendReassembler.Packet) -> Void)? = nil) async throws -> RecordingCapture {
        var reassembler = DataSendReassembler(streamID: streamID)
        var capture = RecordingCapture(streamID: streamID)
        let deadline = duration.map { ContinuousClock.now + $0 }
        let filter: @Sendable (HDSMessage) -> Bool = { message in
            guard message.protocolName == "dataSend", message.topic == "data" || message.topic == "close" else { return false }
            if case .int(let id)? = message.body["streamId"] { return id == streamID }
            return message.topic == "data"   // a data event without streamId is a violation the reassembler reports
        }
        while true {
            if let maximumFragments, capture.fragments.count >= maximumFragments { break }
            var wait = eventTimeout
            if let deadline {
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero { break }
                if remaining < wait { wait = remaining }
            }
            let event: HDSMessage
            do {
                event = try await nextEvent(where: filter, timeout: wait)
            } catch HDSTestClientError.timedOut where deadline.map({ ContinuousClock.now >= $0 }) ?? false {
                break
            }
            if event.topic == "close" {
                if case .int(let raw)? = event.body["reason"] { capture.closeReason = HDSProtocolReason(rawValue: raw) ?? .unexpectedFailure }
                else { capture.closeReason = .normal }
                break
            }
            for packet in try reassembler.consume(event.body) {
                capture.chunkCounts.append(packet.chunkCount)
                capture.arrivalTimes.append(.now)
                if packet.isInitialization {
                    capture.initialization = packet.data
                } else {
                    capture.fragments.append(packet.data)
                }
                onPacket?(packet)
            }
            if reassembler.endOfStream {
                capture.endOfStream = true
                break
            }
        }
        return capture
    }

    /// `dataSend/ack` (the hub's answer to `endOfStream`).
    public func ackRecording(streamID: Int64, endOfStream: Bool = true) async throws {
        try await sendEvent(protocol: "dataSend", topic: "ack", body: HDSDictionary([("streamId", .int(streamID)), ("endOfStream", .bool(endOfStream))]))
    }

    /// `dataSend/close` from the controller.
    public func closeRecording(streamID: Int64, reason: HDSProtocolReason = .normal) async throws {
        try await sendEvent(protocol: "dataSend", topic: "close", body: HDSDictionary([("streamId", .int(streamID)), ("reason", .int(reason.rawValue))]))
    }

    // MARK: - Framing

    /// Seals `payload` with the next send counter. Callers queue the frame in the same actor turn (`enqueue`), so
    /// frames reach the socket in counter order.
    private func sealPayload(_ payload: Data) throws -> Data {
        let frame = try HDSFrameCodec.sealFrame(payload, key: controllerToAccessory, counter: sendCounter)
        sendCounter += 1
        return frame
    }

    /// Seals and queues `payload`, then waits until it was written.
    private func write(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if isClosed { return continuation.resume(throwing: closeError ?? HDSTestClientError.closed) }
            do {
                enqueue(try sealPayload(payload), .caller(continuation))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func enqueue(_ frame: Data, _ completion: SendCompletion) {
        sendQueue.append((frame, completion))
        guard !isWriting else { return }
        isWriting = true
        Task { await self.drainSendQueue() }
    }

    /// The single writer: sends queued frames one at a time, in order.
    private func drainSendQueue() async {
        while !sendQueue.isEmpty {
            let (frame, completion) = sendQueue.removeFirst()
            do {
                try await connection.send(frame)
                complete(completion, with: nil)
            } catch {
                complete(completion, with: error)
                // Frames after a lost one would not decrypt (their counters are ahead): the stream is unusable.
                fail(error)
            }
        }
        isWriting = false
    }

    private func complete(_ completion: SendCompletion, with error: (any Error)?) {
        switch completion {
        case .caller(let continuation):
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        case .request(let id):
            if let error { failRequest(id, error) }
        }
    }

    private func startReading() {
        let connection = self.connection
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                let data: Data?
                var failure: (any Error)?
                do {
                    data = try await connection.receive(maximumLength: 65_536)
                } catch {
                    data = nil
                    failure = error
                }
                guard let self else { return }
                guard let data else {
                    await self.finish(with: failure ?? HDSTestClientError.closed)
                    return
                }
                await self.didReceive(data)
            }
        }
    }

    private func didReceive(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard length <= HDSFrameCodec.maximumPayloadLength else {
                fail(HDSTestClientError.malformedFrame("payload length \(length)"))
                return
            }
            let total = 4 + length + 16
            guard buffer.count >= total else { return }
            let header = Data(buffer[start..<(start + 4)])
            let body = Data(buffer[(start + 4)..<(start + total)])
            buffer = Data(buffer[(start + total)...])
            let message: HDSMessage
            do {
                let payload = try HDSFrameCodec.openFrame(header: header, body: body, key: accessoryToController, counter: receiveCounter)
                receiveCounter += 1
                message = try HDSFrameCodec.decodePayload(payload)
            } catch {
                fail(error)
                return
            }
            dispatch(message)
        }
    }

    private func dispatch(_ message: HDSMessage) {
        switch message.kind {
        case .response(let id, _):
            if let waiter = pendingResponses.removeValue(forKey: id) {
                requestTimers.removeValue(forKey: id)?.cancel()
                waiter.resume(returning: message)
            } else {
                log.warning("response to unknown request \(id) (\(message.protocolName)/\(message.topic)) ignored")
            }
        case .event:
            if let index = eventWaiters.firstIndex(where: { $0.filter(message) }) {
                let waiter = eventWaiters.remove(at: index)
                timeouts.removeValue(forKey: waiter.id)?.cancel()
                waiter.continuation.resume(returning: message)
            } else {
                events.append(message)
                trimEvents()
            }
        case .request:
            incomingRequests.append(message)
        }
    }

    private func trimEvents() {
        let excess = events.count - eventBufferLimit
        guard excess > 0 else { return }
        events.removeFirst(excess)
        if droppedEventCount == 0 { log.warning("unclaimed HDS events exceed \(eventBufferLimit); dropping the oldest") }
        droppedEventCount += excess
    }

    private func fail(_ error: any Error) {
        connection.close()
        finish(with: error)
    }

    private func finish(with error: (any Error)?) {
        guard !isClosed else { return }
        isClosed = true
        closeError = error
        let failure = error ?? HDSTestClientError.closed
        let responses = pendingResponses
        pendingResponses.removeAll()
        for waiter in responses.values { waiter.resume(throwing: failure) }
        let waiters = eventWaiters
        eventWaiters.removeAll()
        for waiter in waiters {
            timeouts.removeValue(forKey: waiter.id)?.cancel()
            waiter.continuation.resume(throwing: failure)
        }
        for timer in timeouts.values { timer.cancel() }
        timeouts.removeAll()
        for timer in requestTimers.values { timer.cancel() }
        requestTimers.removeAll()
        let unsent = sendQueue
        sendQueue.removeAll()
        for item in unsent { complete(item.completion, with: failure) }
    }

    private func expireRequest(_ id: Int64) {
        requestTimers.removeValue(forKey: id)
        pendingResponses.removeValue(forKey: id)?.resume(throwing: HDSTestClientError.timedOut)
    }

    private func failRequest(_ id: Int64, _ error: any Error) {
        requestTimers.removeValue(forKey: id)?.cancel()
        pendingResponses.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func cancelRequest(_ id: Int64) {
        requestTimers.removeValue(forKey: id)?.cancel()
        pendingResponses.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelEventWait(_ id: UUID) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let index = eventWaiters.firstIndex(where: { $0.id == id }) else { return }
        eventWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func expireEvent(_ id: UUID) {
        timeouts.removeValue(forKey: id)
        guard let index = eventWaiters.firstIndex(where: { $0.id == id }) else { return }
        eventWaiters.remove(at: index).continuation.resume(throwing: HDSTestClientError.timedOut)
    }
}

/// The accessory's answer to `dataSend/open`.
public struct DataSendOpenResult: Sendable {
    public var status: HDSStatus
    /// For HDS status 6 (protocol-specific error): the reason in the body's `status`.
    public var protocolReason: HDSProtocolReason?
    public var body: HDSDictionary

    public var isAccepted: Bool { status == .success }
}

public enum HDSTestClientError: Error, Sendable, CustomStringConvertible {
    case closed
    case timedOut
    case notARequest
    case malformedFrame(String)
    case unexpectedStatus(HDSMessage)

    public var description: String {
        switch self {
        case .closed: "HDS connection closed"
        case .timedOut: "HDS request or event timed out"
        case .notARequest: "not a request"
        case .malformedFrame(let what): "malformed HDS frame: \(what)"
        case .unexpectedStatus(let message): "unexpected HDS answer \(message.kind) to \(message.protocolName)/\(message.topic)"
        }
    }
}
