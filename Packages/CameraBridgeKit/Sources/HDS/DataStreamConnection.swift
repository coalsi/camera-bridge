// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// (Connection behaviour from lib/datastream/DataStreamServer.ts `DataStreamConnection`; research brief §3.8.)

import BridgeSupport
import Foundation
import HAP
import Synchronization

/// One accepted HDS connection, already matched to the HAP session that prepared it.
///
/// - The first message must be the controller's `control/hello` request (the server closes the connection otherwise);
///   it is answered internally with an empty message. Later `control/hello` requests are answered too.
/// - Events and requests are handed to the server's protocol handler one at a time, in arrival order. A handler that
///   does long work (e.g. streaming a recording) must start it in its own task and return, or later messages on this
///   connection wait. A request without a handler for its protocol is answered with `.missingProtocol`; an event
///   without one is dropped. Messages still waiting for the handler when the connection closes are dropped.
/// - At most `maximumQueuedMessages` events/requests wait for (or sit in) the handler; while that many do, the
///   connection stops reading from the transport (TCP backpressure), so hello requests and responses wait too.
/// - Responses resolve `sendRequest` directly (never through a handler), so a handler may await `sendRequest` (as
///   long as the peer does not fill the queue meanwhile; the request's timeout still bounds that wait).
/// - A message that fails to decode after the hello is not handed on: a response still settles its request with the
///   decoding error (e.g. a status outside 0–6), a request whose header is readable is answered with `.payloadError`,
///   anything else is dropped.
/// - Frames leave in nonce order even when sent from many tasks at once. `sendEvent`/`sendResponse` return once the
///   transport accepted the frame. A frame that fails authentication, an oversized frame, the peer closing, a
///   `sendRequest` timeout, the linked HAP session closing, `close()` or `DataStreamServer.stop()` close the connection;
///   then pending and later sends throw `HDSConnectionError.closed`.
public actor DataStreamConnection {
    public nonisolated let id: UUID
    public nonisolated let hapSessionID: UUID

    /// Delivers an event/request to the protocol's handler; false when there is none.
    typealias Dispatch = @Sendable (HDSMessage, DataStreamConnection) async -> Bool

    static let controlProtocol = "control"
    static let helloTopic = "hello"
    static let receiveChunkSize = 65536
    /// Events/requests waiting for or in the protocol handler before the connection stops reading.
    static let maximumQueuedMessages = 32

    private struct OutgoingFrame: Sendable {
        let bytes: Data
        /// Resumed once the transport accepted (or refused) the bytes; nil for fire-and-forget frames.
        let sent: CheckedContinuation<Void, any Error>?
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<HDSMessage, any Error>
        let timeout: Duration
        let timer: Task<Void, Never>
    }

    private struct Lifecycle {
        var closed = false
        var handlers: [@Sendable () -> Void] = []
    }

    private let tcp: any TCPConnection
    private let accessoryToControllerKey: Data
    private let controllerToAccessoryKey: Data
    private let dispatch: Dispatch
    /// The server's.
    nonisolated let log: Log
    /// One send that makes no progress for this long closes the connection (`sendWatchingProgress`).
    private let sendStallTimeout: Duration
    private let lifecycle = Mutex(Lifecycle())
    private let outgoingFrames: AsyncStream<OutgoingFrame>
    private let outgoing: AsyncStream<OutgoingFrame>.Continuation
    private let incomingMessages: AsyncStream<HDSMessage>
    private let incoming: AsyncStream<HDSMessage>.Continuation
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var assembler = HDSFrameAssembler()
    private var receivedHello = false
    private var started = false
    private var pendingRequests: [Int64: PendingRequest] = [:]
    /// Events/requests handed to `incoming` whose dispatch has not finished.
    private var queuedMessages = 0
    /// The reader, paused while `queuedMessages` is at the maximum.
    private var capacityWaiter: CheckedContinuation<Void, Never>?
    private var dispatchFinished = false

    init(id: UUID = UUID(), hapSessionID: UUID, tcp: any TCPConnection, accessoryToControllerKey: Data,
         controllerToAccessoryKey: Data, log: Log = Log(category: "HDS"), sendStallTimeout: Duration = .seconds(15),
         dispatch: @escaping Dispatch) {
        self.id = id
        self.log = log
        self.sendStallTimeout = sendStallTimeout
        self.hapSessionID = hapSessionID
        self.tcp = tcp
        self.accessoryToControllerKey = accessoryToControllerKey
        self.controllerToAccessoryKey = controllerToAccessoryKey
        self.dispatch = dispatch
        (outgoingFrames, outgoing) = AsyncStream.makeStream(of: OutgoingFrame.self)
        (incomingMessages, incoming) = AsyncStream.makeStream(of: HDSMessage.self)
    }

    /// Starts the connection with the identified first frame's plaintext (opened at counter 0) and the bytes that
    /// arrived after it.
    func start(firstPayload: Data, assembler: HDSFrameAssembler) {
        guard !started, !isClosed else { return }
        started = true
        self.assembler = assembler
        receiveCounter = 1
        let tcp = self.tcp
        let frames = outgoingFrames
        let messages = incomingMessages
        let dispatch = self.dispatch
        let stall = sendStallTimeout
        Task { await Self.writeFrames(frames, to: tcp, connection: self, stallTimeout: stall) }
        Task { await Self.dispatchMessages(messages, connection: self, dispatch: dispatch) }
        handlePayload(firstPayload)
        drainFrames()
        guard !isClosed else { return }
        Task { await self.readFrames() }
    }

    // MARK: - Test hooks

    var queuedMessageCount: Int { queuedMessages }
    var isDispatchFinished: Bool { dispatchFinished }
    var pendingRequestTimeouts: [Duration] { pendingRequests.values.map(\.timeout) }

    // MARK: - Sending

    public func sendEvent(protocol protocolName: String, topic: String, body: HDSDictionary) async throws {
        try await transmit(HDSMessage(kind: .event, protocolName: protocolName, topic: topic, body: body))
    }

    public func sendResponse(to request: HDSMessage, status: HDSStatus, body: HDSDictionary) async throws {
        guard case .request(let requestID) = request.kind else { throw HDSConnectionError.notARequest }
        try await transmit(HDSMessage(kind: .response(id: requestID, status: status), protocolName: request.protocolName,
                                      topic: request.topic, body: body))
    }

    /// Sends a request and waits for its response. No response within `timeout` closes the connection (brief §3.8)
    /// and throws `HDSConnectionError.timeout`; cancelling the calling task throws `CancellationError` and keeps the
    /// connection open. A response that cannot be decoded (e.g. `HDSFrameError.invalidStatus` for a status outside
    /// 0–6) throws the decoding error at once and keeps the connection open.
    public func sendRequest(protocol protocolName: String, topic: String, body: HDSDictionary, timeout: Duration = .seconds(10)) async throws -> HDSMessage {
        guard !isClosed else { throw HDSConnectionError.closed }
        let requestID = newRequestID()
        let payload = try HDSFrameCodec.encodePayload(HDSMessage(kind: .request(id: requestID), protocolName: protocolName,
                                                                 topic: topic, body: body))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HDSMessage, any Error>) in
                do {
                    let frame = try seal(payload)
                    let timer = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        await self?.requestTimedOut(requestID)
                    }
                    pendingRequests[requestID] = PendingRequest(continuation: continuation, timeout: timeout, timer: timer)
                    if case .terminated = outgoing.yield(OutgoingFrame(bytes: frame, sent: nil)) {
                        failRequest(requestID, with: HDSConnectionError.closed)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.failRequest(requestID, with: CancellationError()) }
        }
    }

    // MARK: - Closing

    /// Idempotent. Fails pending requests and queued sends with `HDSConnectionError.closed`, closes the TCP
    /// connection and runs the `onClose` handlers once.
    public func close() async {
        closeNow()
    }

    public nonisolated var isClosed: Bool {
        lifecycle.withLock { $0.closed }
    }

    /// `handler` runs once when the connection closes, or at once if it already has.
    public nonisolated func onClose(_ handler: @escaping @Sendable () -> Void) {
        let alreadyClosed = lifecycle.withLock { state in
            if !state.closed { state.handlers.append(handler) }
            return state.closed
        }
        if alreadyClosed { handler() }
    }

    private func closeNow() {
        let handlers = lifecycle.withLock { state -> [@Sendable () -> Void]? in
            guard !state.closed else { return nil }
            state.closed = true
            defer { state.handlers.removeAll() }
            return state.handlers
        }
        guard let handlers else { return }
        log.debug("HDS connection \(id) closed")
        tcp.close()
        outgoing.finish()
        incoming.finish()
        resumeReader()
        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.timer.cancel()
            request.continuation.resume(throwing: HDSConnectionError.closed)
        }
        for handler in handlers { handler() }
    }

    // MARK: - Internals

    private func transmit(_ message: HDSMessage) async throws {
        guard !isClosed else { throw HDSConnectionError.closed }
        let payload = try HDSFrameCodec.encodePayload(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                // Sealing and queueing happen in one synchronous step, so frames leave in counter order.
                let frame = try seal(payload)
                if case .terminated = outgoing.yield(OutgoingFrame(bytes: frame, sent: continuation)) {
                    continuation.resume(throwing: HDSConnectionError.closed)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Queues `message` without waiting for the transport (internal replies).
    private func enqueue(_ message: HDSMessage) {
        do {
            let frame = try seal(try HDSFrameCodec.encodePayload(message))
            outgoing.yield(OutgoingFrame(bytes: frame, sent: nil))
        } catch {
            log.error("HDS connection \(id) could not encode \(message.protocolName)/\(message.topic): \(error)")
        }
    }

    /// Encrypts with the next accessory→controller counter; the counter advances only on success.
    private func seal(_ payload: Data) throws -> Data {
        let frame = try HDSFrameCodec.sealFrame(payload, key: accessoryToControllerKey, counter: sendCounter)
        sendCounter += 1
        return frame
    }

    private func newRequestID() -> Int64 {
        var requestID: Int64
        repeat {
            requestID = Int64.random(in: 1...Int64(UInt32.max))
        } while pendingRequests[requestID] != nil
        return requestID
    }

    private func failRequest(_ requestID: Int64, with error: any Error) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.timer.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func requestTimedOut(_ requestID: Int64) {
        guard pendingRequests[requestID] != nil else { return }
        log.warning("HDS connection \(id): request \(requestID) got no response in time; closing")
        failRequest(requestID, with: HDSConnectionError.timeout)
        closeNow()
    }

    private func readFrames() async {
        while !isClosed {
            drainFrames()
            guard !isClosed else { break }
            if queuedMessages >= Self.maximumQueuedMessages {
                await waitForDispatchCapacity()
                continue
            }
            let chunk: Data?
            do {
                chunk = try await tcp.receive(maximumLength: Self.receiveChunkSize)
            } catch {
                break
            }
            guard let chunk else { break }   // orderly EOF
            assembler.append(chunk)
        }
        closeNow()
    }

    /// Handles buffered frames until none is complete or the handler queue is full.
    private func drainFrames() {
        do {
            while !isClosed, queuedMessages < Self.maximumQueuedMessages, let frame = try assembler.nextFrame() {
                handleFrame(frame)
            }
        } catch {
            log.warning("HDS connection \(id): \(error); closing")
            closeNow()
        }
    }

    private func waitForDispatchCapacity() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isClosed || queuedMessages < Self.maximumQueuedMessages {
                continuation.resume()
            } else {
                capacityWaiter = continuation
            }
        }
    }

    private func resumeReader() {
        guard let waiter = capacityWaiter else { return }
        capacityWaiter = nil
        waiter.resume()
    }

    private func messageDispatched() {
        queuedMessages = max(queuedMessages - 1, 0)
        if queuedMessages < Self.maximumQueuedMessages { resumeReader() }
    }

    private func dispatchEnded() {
        dispatchFinished = true
    }

    private func handleFrame(_ frame: HDSRawFrame) {
        let payload: Data
        do {
            payload = try HDSFrameCodec.openFrame(header: frame.header, body: frame.body, key: controllerToAccessoryKey, counter: receiveCounter)
        } catch {
            log.warning("HDS connection \(id): frame \(receiveCounter) failed authentication; closing")
            closeNow()
            return
        }
        receiveCounter += 1
        handlePayload(payload)
    }

    private func handlePayload(_ payload: Data) {
        let message: HDSMessage
        do {
            message = try HDSFrameCodec.decodePayload(payload)
        } catch {
            handleUndecodable(payload, error: error)
            return
        }
        let isHello = message.protocolName == Self.controlProtocol && message.topic == Self.helloTopic
        switch message.kind {
        case .request(let helloID) where isHello:
            receivedHello = true
            enqueue(HDSMessage(kind: .response(id: helloID, status: .success), protocolName: Self.controlProtocol, topic: Self.helloTopic))
        case _ where !receivedHello:
            log.warning("HDS connection \(id): first message was \(message.protocolName)/\(message.topic), not control/hello; closing")
            closeNow()
        case .response(let requestID, _):
            guard let pending = pendingRequests.removeValue(forKey: requestID) else {
                log.debug("HDS connection \(id): response to unknown request \(requestID)")
                return
            }
            pending.timer.cancel()
            pending.continuation.resume(returning: message)
        case .event, .request:
            queuedMessages += 1
            incoming.yield(message)
        }
    }

    /// HAP-NodeJS hands such messages on as they are; here the peer at least gets an answer instead of a timeout.
    private func handleUndecodable(_ payload: Data, error: any Error) {
        guard receivedHello else {
            log.warning("HDS connection \(id): undecodable first message (\(error)); closing")
            closeNow()
            return
        }
        switch HDSFrameCodec.partialHeader(payload) {
        case .response(let requestID)? where pendingRequests[requestID] != nil:
            log.warning("HDS connection \(id): undecodable response to request \(requestID) (\(error))")
            failRequest(requestID, with: error)
        case .request(let requestID, let protocolName, let topic)?:
            log.warning("HDS connection \(id): undecodable \(protocolName)/\(topic) request (\(error)); answering payloadError")
            enqueue(HDSMessage(kind: .response(id: requestID, status: .payloadError), protocolName: protocolName, topic: topic))
        default:
            log.warning("HDS connection \(id): undecodable message (\(error)); dropped")
        }
    }

    private func closeAfterSendFailure() {
        if !isClosed { log.notice("HDS connection \(id): send failed; closing") }
        closeNow()
    }

    private static func writeFrames(_ frames: AsyncStream<OutgoingFrame>, to tcp: any TCPConnection, connection: DataStreamConnection,
                                    stallTimeout: Duration) async {
        for await frame in frames {
            do {
                let id = connection.id, log = connection.log
                try await sendWatchingProgress(frame.bytes, on: tcp, limit: stallTimeout) {
                    log.warning("HDS connection \(id): the controller accepted no data for \(stallTimeout); closing")
                }
                frame.sent?.resume()
            } catch {
                frame.sent?.resume(throwing: HDSConnectionError.closed)
                await connection.closeAfterSendFailure()
            }
        }
    }

    private static func dispatchMessages(_ messages: AsyncStream<HDSMessage>, connection: DataStreamConnection, dispatch: Dispatch) async {
        for await message in messages {
            // The stream still yields what was queued before it finished; nothing can answer those any more.
            if connection.isClosed { break }
            let handled = await dispatch(message, connection)
            if !handled, case .request = message.kind {
                try? await connection.sendResponse(to: message, status: .missingProtocol, body: HDSDictionary())
            }
            await connection.messageDispatched()
        }
        await connection.dispatchEnded()
    }
}
