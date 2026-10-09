import BridgeSupport
import Foundation
import Synchronization

/// The TCP connection of one RTSP session: one reader task (responses, server requests, interleaved packets) and one
/// writer task that sends queued messages in order, so requests and interleaved backchannel packets never interleave
/// mid-message. Interleaved data is dropped rather than queued once `maxQueuedBytes` wait for a peer that stopped
/// reading (requests and replies are small and always queued).
final class RTSPControlConnection: Sendable {
    static let maxQueuedBytes = 1024 * 1024

    typealias InterleavedHandler = @Sendable (_ channel: UInt8, _ payload: Data, _ arrival: Date) -> Void
    typealias CloseHandler = @Sendable (_ error: any Error) -> Void

    private struct Pending {
        var continuation: CheckedContinuation<RTSPResponse, any Error>
        var timeout: Task<Void, Never>
    }

    private struct State {
        var pending: [Int: Pending] = [:]
        var closedError: (any Error)?
        var interleavedHandler: InterleavedHandler?
        var closeHandler: CloseHandler?
        var tasks: [Task<Void, Never>] = []
        var queuedBytes = 0
    }

    private let connection: any TCPConnection
    private let outgoing: AsyncStream<Data>.Continuation
    private let state = Mutex(State())
    private let log: Log

    init(connection: any TCPConnection, log: Log) {
        self.connection = connection
        self.log = log
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        outgoing = continuation
        let reader = Task { [weak self, connection] in
            var parser = RTSPMessageParser()
            do {
                while true {
                    guard let data = try await connection.receive(maximumLength: 256 * 1024) else {
                        throw TransportError.closed   // orderly EOF from the camera
                    }
                    let arrival = Date()
                    parser.append(data)
                    while let message = try parser.next() {
                        guard let self else { return }
                        self.dispatch(message, arrival: arrival)
                    }
                }
            } catch {
                self?.shutdown(error)
            }
        }
        let writer = Task { [weak self, connection] in
            for await data in stream {
                do {
                    try await connection.send(data)
                    self?.state.withLock { $0.queuedBytes -= data.count }
                } catch {
                    self?.shutdown(error)
                    return
                }
            }
        }
        state.withLock { $0.tasks = [reader, writer] }
    }

    deinit {
        close()
    }

    var isClosed: Bool { state.withLock { $0.closedError != nil } }

    func setInterleavedHandler(_ handler: InterleavedHandler?) {
        state.withLock { $0.interleavedHandler = handler }
    }

    /// Called once if the connection ends for any reason other than `close()`.
    func setCloseHandler(_ handler: CloseHandler?) {
        state.withLock { $0.closeHandler = handler }
    }

    /// Sends a serialized request and waits for the response with the same CSeq.
    func request(_ data: Data, cseq: Int, timeout: Duration) async throws -> RTSPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTSPResponse, any Error>) in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.fail(cseq: cseq, with: RTSPError.timeout)
                }
                let closedError = state.withLock { s -> (any Error)? in
                    if let error = s.closedError { return error }
                    s.pending[cseq] = Pending(continuation: continuation, timeout: timeoutTask)
                    return nil
                }
                if let closedError {
                    timeoutTask.cancel()
                    continuation.resume(throwing: closedError)
                    return
                }
                enqueue(data)
            }
        } onCancel: {
            fail(cseq: cseq, with: CancellationError())
        }
    }

    /// Queues bytes for sending (interleaved packets). False when they were dropped because `maxQueuedBytes` are
    /// already waiting for the peer. Throws if the connection is closed.
    @discardableResult
    func send(_ data: Data) throws -> Bool {
        let accepted = try state.withLock { s throws -> Bool in
            if let error = s.closedError { throw error }
            guard s.queuedBytes + data.count <= Self.maxQueuedBytes else { return false }
            s.queuedBytes += data.count
            return true
        }
        if accepted { outgoing.yield(data) }
        return accepted
    }

    /// Closes without calling the close handler; pending requests fail with `TransportError.closed`.
    func close() {
        state.withLock { $0.closeHandler = nil }
        shutdown(TransportError.closed)
    }

    // MARK: Private

    /// Queues a request or reply regardless of `maxQueuedBytes`.
    private func enqueue(_ data: Data) {
        state.withLock { $0.queuedBytes += data.count }
        outgoing.yield(data)
    }

    private func fail(cseq: Int, with error: any Error) {
        let pending = state.withLock { $0.pending.removeValue(forKey: cseq) }
        pending?.timeout.cancel()
        pending?.continuation.resume(throwing: error)
    }

    private func dispatch(_ message: RTSPIncomingMessage, arrival: Date) {
        switch message {
        case .interleaved(let channel, let payload):
            let handler = state.withLock { $0.interleavedHandler }
            handler?(channel, payload, arrival)
        case .response(let response):
            let pending = state.withLock { s -> Pending? in
                if let cseq = response.cseq { return s.pending.removeValue(forKey: cseq) }
                // No CSeq: answer the oldest outstanding request.
                guard let oldest = s.pending.keys.min() else { return nil }
                return s.pending.removeValue(forKey: oldest)
            }
            guard let pending else {
                log.debug("Ignoring RTSP response without a matching request (CSeq \(response.cseq.map(String.init) ?? "none"))")
                return
            }
            pending.timeout.cancel()
            pending.continuation.resume(returning: response)
        case .request(let request):
            // Servers may probe the client (e.g. GET_PARAMETER / OPTIONS as keepalive).
            let supported = ["OPTIONS", "GET_PARAMETER", "SET_PARAMETER"].contains(request.method.uppercased())
            let reply = supported
                ? RTSPRequestSerializer.response(status: 200, reason: "OK", cseq: request.headers["CSeq"])
                : RTSPRequestSerializer.response(status: 501, reason: "Not Implemented", cseq: request.headers["CSeq"])
            enqueue(reply)
        }
    }

    private func shutdown(_ error: any Error) {
        let taken = state.withLock { s -> (pending: [Pending], handler: CloseHandler?, tasks: [Task<Void, Never>])? in
            guard s.closedError == nil else { return nil }
            s.closedError = error
            defer {
                s.pending = [:]
                s.closeHandler = nil
                s.interleavedHandler = nil
                s.tasks = []
            }
            return (Array(s.pending.values), s.closeHandler, s.tasks)
        }
        guard let taken else { return }
        outgoing.finish()
        connection.close()
        taken.tasks.forEach { $0.cancel() }
        for pending in taken.pending {
            pending.timeout.cancel()
            pending.continuation.resume(throwing: error)
        }
        taken.handler?(error)
    }
}
