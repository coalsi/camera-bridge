// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// The stream follows HAP-NodeJS lib/camera/RecordingManagement.ts `CameraRecordingStream` (_startStreaming,
// handleDataSendAck, handleDataSendClose, close, kickOffCloseTimeout); research brief §3.8 "Recording flow".

import BridgeSupport
import Foundation
import HDS

/// One accepted HKSV `dataSend` stream on an HDS connection.
///
/// Sends the open response, asks the delegate for its packets and forwards them as `dataSend/data` events: the first
/// packet is `mediaInitialization` (sequence 1), later ones `mediaFragment` (2, 3, …); each packet goes out in chunks of
/// at most 0x40000 bytes numbered from 1, with `dataTotalSize` on chunk 1, `isLastDataChunk` on the last chunk and
/// `endOfStream` (the packet's `isLast`) on the last chunk of every packet (HAP-NodeJS).
///
/// It ends exactly once: the hub's `ack` (→ `acknowledgeStream`) or `close` (→ `closeRecordingStream(reason)`), the HDS
/// connection closing (→ `closeRecordingStream(nil)`, reported by the controller's one handler per connection), or a
/// close from our side, which queues `dataSend/close` with the reason (no acknowledgement within the timeout after the
/// last packet → `.cancelled`; delegate failure → its `HDSProtocolReason` or `.unexpectedFailure`; camera or recording
/// turned off → `.notAllowed`). Ending never waits for the connection: the slot is freed, the delegate told and the
/// stop watchdog started at once, even while a data event (or the close event) is stuck behind a hub that stopped
/// reading; a close event still unsent after the stop timeout closes the HDS connection. The delegate hears about the
/// end only if `recordingStream(streamID:)` was called (possibly while that call is still running). Ending stops
/// reading the delegate's stream (its `onTermination` fires); a sender still busy after the stop timeout gets its HDS
/// connection closed. The delegate owns the recording cap (`maximumRecordingDuration`): it marks its last packet, which
/// after the cap can be the second of two that one keyframe closes, and every packet goes out as it marks it. Only a
/// delegate that has not ended its stream by the cap plus one fragment (`fragmentLength`, the selected configuration's)
/// plus `recordingCapGrace` has its next packet sent as the last one (a backstop; a second cap racing the delegate's
/// would mark the first of those two packets last and drop the second). A stream closed by us before `start` (the
/// camera turned off while the open was in flight) answers the open with that reason instead of accepting it, and sends
/// no close event.
///
/// A stream that replaces another one (`predecessor`: the one the controller's slot held last) asks the delegate for its
/// packets only once the predecessor's delegate notification (`acknowledgeStream` / `closeRecordingStream`, which run in
/// their own tasks after the slot was freed) is done, so a hub that reuses a stream ID never has its new producer
/// cancelled by the late end of the old one (`waitUntilSettled`).
actor RecordingStream {
    enum Ending: Sendable {
        case acknowledged
        case closed(HDSProtocolReason?)
    }

    static let protocolName = "dataSend"
    static let maximumChunkSize = 0x40000

    nonisolated let streamID: Int
    nonisolated let connection: DataStreamConnection
    private let delegate: any CameraRecordingDelegate
    private let timings: CameraControllerTimings
    /// The selected configuration's fragment length: how much later than the cap the delegate's last packet may come.
    private let fragmentLength: Duration
    private let onFinished: @Sendable (RecordingStream) -> Void
    private let log: Log

    private var started = false
    private var closed = false
    private var delegateAsked = false
    private var consumer: Task<Void, Never>?
    private var consumerFinished = false
    private var acknowledgeTimer: Task<Void, Never>?
    private var backstopTimer: Task<Void, Never>?
    private var backstopReached = false
    /// Why the stream was closed before `start` (its open is refused with it).
    private var refusal: HDSProtocolReason?
    /// The stream this one replaced, whose end the delegate hears before this stream's `recordingStream(streamID:)`.
    private var predecessor: RecordingStream?
    /// The delegate has been told this stream ended (or had nothing to be told).
    private var settled = false
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    /// `log`: the controller's (tagged with its camera).
    init(streamID: Int, connection: DataStreamConnection, delegate: any CameraRecordingDelegate, timings: CameraControllerTimings,
         fragmentLength: Duration = .zero, predecessor: RecordingStream? = nil, log: Log = Log(category: "camera"),
         onFinished: @escaping @Sendable (RecordingStream) -> Void) {
        self.streamID = streamID
        self.predecessor = predecessor
        self.log = log
        self.connection = connection
        self.delegate = delegate
        self.timings = timings
        self.fragmentLength = fragmentLength
        self.onFinished = onFinished
    }

    /// Accepts the `open` request and starts streaming in the background; refuses it if the stream was already closed.
    func start(open request: HDSMessage) async {
        guard !started else { return }
        if closed {
            let reason = refusal ?? .notAllowed
            log.info("Recording stream \(streamID) was closed before it was accepted; refusing it with reason \(reason.rawValue)")
            do {
                try await connection.sendResponse(to: request, status: .protocolSpecificError, body: HDSDictionary([("status", .int(reason.rawValue))]))
            } catch {
                log.debug("Recording stream \(streamID): the refusal was not sent (\(error))")
            }
            return
        }
        started = true
        log.info("Recording stream \(streamID) opened")
        let backstop = timings.recordingBackstop(fragmentLength: fragmentLength)
        backstopTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: backstop)
            } catch {
                return
            }
            await self?.reachBackstop(after: backstop)
        }
        consumer = Task {
            await self.run(open: request)
            self.consumerDidFinish()
        }
    }

    // MARK: - Hub messages

    func acknowledge() async {
        await end(.acknowledged, because: "the hub acknowledged it")
    }

    func hubClosed(reason: HDSProtocolReason?) async {
        await end(.closed(reason), because: "the hub closed it (reason \(reason.map { String($0.rawValue) } ?? "none"))")
    }

    /// The HDS connection closed (the controller watches each connection once).
    func connectionClosed() async {
        await end(.closed(nil), because: "its HDS connection closed")
    }

    /// Closes from our side: queues `dataSend/close` for the hub and tells the delegate `closeRecordingStream(reason)`
    /// without waiting for the event to go out. Before `start`, `start` refuses the open with `reason` instead.
    func close(reason: HDSProtocolReason, because explanation: String) async {
        guard !closed else { return }
        closed = true
        stopTimers()
        guard started else {
            refusal = reason
            log.info("Recording stream \(streamID) closed before it was accepted (reason \(reason.rawValue)): \(explanation)")
            await finish(.closed(reason))
            return
        }
        log.info("Recording stream \(streamID) closed with reason \(reason.rawValue): \(explanation)")
        sendCloseEvent(reason)
        await finish(.closed(reason))
    }

    /// Sends `dataSend/close` in its own task: it queues behind any data event still in flight, and a hub that stopped
    /// reading must not hold up the end of the stream. Not sent within the stop timeout → the HDS connection is closed.
    private func sendCloseEvent(_ reason: HDSProtocolReason) {
        guard !connection.isClosed else { return }
        let connection = self.connection
        let streamID = self.streamID
        let timeout = timings.recordingStopTimeout
        let log = self.log
        let body = HDSDictionary([("streamId", .int(Int64(streamID))), ("reason", .int(reason.rawValue))])
        Task {
            let watchdog = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                log.error("Recording stream \(streamID): the close event was still unsent \(timeout) later; closing its HDS connection")
                await connection.close()
            }
            do {
                try await connection.sendEvent(protocol: Self.protocolName, topic: "close", body: body)
            } catch {
                log.debug("Recording stream \(streamID): the close event was not sent (\(error))")
            }
            watchdog.cancel()
        }
    }

    // MARK: - Streaming

    private func run(open request: HDSMessage) async {
        do {
            try await connection.sendResponse(to: request, status: .success, body: HDSDictionary([("status", .int(0))]))
        } catch {
            await end(.closed(nil), because: "the open response could not be sent")
            return
        }
        guard !closed else { return }
        if let predecessor {
            // Bounded: a delegate that never answers its notification must not keep the new recording from starting.
            await predecessor.waitUntilSettled(limit: timings.recordingStopTimeout)
            self.predecessor = nil   // no chain of every stream before it
            guard !closed else { return }
        }
        delegateAsked = true
        let packets: AsyncThrowingStream<RecordingPacket, any Error>
        do {
            packets = try await delegate.recordingStream(streamID: streamID)
        } catch {
            await close(reason: Self.reason(for: error), because: "the recording delegate failed: \(error)")
            return
        }
        var iterator = packets.makeAsyncIterator()
        var sequence: Int64 = 1
        var sentLast = false
        while !closed {
            let packet: RecordingPacket?
            do {
                packet = try await iterator.next()
            } catch {
                guard !closed else { return }
                await close(reason: Self.reason(for: error), because: "the recording delegate failed: \(error)")
                return
            }
            guard let packet, !closed else { break }
            let isLast = packet.isLast || backstopReached
            do {
                try await send(packet.data, sequence: sequence, isLast: isLast)
            } catch {
                guard !closed else { return }
                if connection.isClosed {
                    await end(.closed(nil), because: "its HDS connection closed")
                } else {
                    await close(reason: .unexpectedFailure, because: "sending failed: \(error)")
                }
                return
            }
            if isLast {
                sentLast = true
                break
            }
            sequence += 1
        }
        guard !closed else { return }
        if !sentLast {
            log.warning("Recording stream \(streamID): the recording delegate ended the stream without a last packet")
        }
        backstopTimer?.cancel()
        startAcknowledgeTimer()
    }

    private func send(_ data: Data, sequence: Int64, isLast: Bool) async throws {
        let total = Int64(data.count)
        var offset = data.startIndex
        var chunk: Int64 = 1
        repeat {
            guard !closed else { return }
            let end = data.index(offset, offsetBy: min(Self.maximumChunkSize, data.endIndex - offset))
            let isLastChunk = end == data.endIndex
            var metadata = HDSDictionary([
                ("dataType", .string(sequence == 1 ? "mediaInitialization" : "mediaFragment")),
                ("dataSequenceNumber", .int(sequence)),
                ("dataChunkSequenceNumber", .int(chunk)),
                ("isLastDataChunk", .bool(isLastChunk)),
            ])
            if chunk == 1 { metadata["dataTotalSize"] = .int(total) }
            let packet = HDSDictionary([("data", .data(Data(data[offset..<end]))), ("metadata", .dictionary(metadata))])
            var body = HDSDictionary([("streamId", .int(Int64(streamID))), ("packets", .array([.dictionary(packet)]))])
            if isLastChunk { body["endOfStream"] = .bool(isLast) }
            try await connection.sendEvent(protocol: Self.protocolName, topic: "data", body: body)
            offset = end
            chunk += 1
        } while offset < data.endIndex
    }

    // MARK: - Ending

    private func end(_ ending: Ending, because explanation: String) async {
        guard !closed else { return }
        closed = true
        stopTimers()
        log.info("Recording stream \(streamID) ended: \(explanation)")
        await finish(ending)
    }

    private func finish(_ ending: Ending) async {
        consumer?.cancel()
        onFinished(self)
        startStopWatchdog()
        predecessor = nil
        defer { markSettled() }
        guard delegateAsked else { return }
        switch ending {
        case .acknowledged:
            await delegate.acknowledgeStream(streamID: streamID)
        case .closed(let reason):
            await delegate.closeRecordingStream(streamID: streamID, reason: reason)
        }
    }

    /// Returns once the delegate has been told this stream ended, or after `limit`.
    func waitUntilSettled(limit: Duration) async {
        guard !settled else { return }
        let stream = self
        _ = try? await withDeadline(limit, followsCancellation: true, {
            await stream.settlement()
        })
    }

    private func settlement() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if settled {
                continuation.resume()
            } else {
                settleWaiters.append(continuation)
            }
        }
    }

    private func markSettled() {
        settled = true
        let waiters = settleWaiters
        settleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func reachBackstop(after backstop: Duration) {
        guard !closed, !backstopReached else { return }
        backstopReached = true
        log.notice("Recording stream \(streamID) ran \(backstop) without the recording delegate ending it at the "
                   + "\(timings.maximumRecordingDuration) limit; its next packet is the last")
        startAcknowledgeTimer()
    }

    private func startAcknowledgeTimer() {
        acknowledgeTimer?.cancel()
        let timeout = timings.recordingAcknowledgeTimeout
        acknowledgeTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.close(reason: .cancelled, because: "the stream was not acknowledged within \(timeout)")
        }
    }

    private func stopTimers() {
        acknowledgeTimer?.cancel()
        acknowledgeTimer = nil
        backstopTimer?.cancel()
        backstopTimer = nil
    }

    private func consumerDidFinish() {
        consumerFinished = true
    }

    private func startStopWatchdog() {
        guard started, !consumerFinished else { return }
        let timeout = timings.recordingStopTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.checkStopped(after: timeout)
        }
    }

    private func checkStopped(after timeout: Duration) async {
        guard !consumerFinished else { return }
        log.error("Recording stream \(streamID) was still sending \(timeout) after it closed; closing its HDS connection")
        await connection.close()
    }

    static func reason(for error: any Error) -> HDSProtocolReason {
        (error as? HDSProtocolReason) ?? .unexpectedFailure
    }
}
