import BridgeSupport
import Foundation
import HAP
import HDS
import Synchronization
import TestSupport
@testable import HAPCamera

/// In-test `HAPSessionHandle` with a manual `close()`.
final class FakeHAPSession: HAPSessionHandle {
    let id = UUID()
    let controllerID: String
    let isAdmin: Bool
    let sharedSecret: Data
    let localAddress: String
    let remoteAddress: String
    let isIPv6: Bool
    let zone: String?
    private let state = Mutex<(closed: Bool, handlers: [@Sendable () -> Void])>((false, []))

    init(isAdmin: Bool = true, localAddress: String = "127.0.0.1", remoteAddress: String = "127.0.0.1", isIPv6: Bool = false,
         zone: String? = nil, sharedSecret: Data = Data(repeating: 7, count: 32), controllerID: String = UUID().uuidString) {
        self.controllerID = controllerID
        self.isAdmin = isAdmin
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.isIPv6 = isIPv6
        self.zone = zone
        self.sharedSecret = sharedSecret
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let closed = state.withLock { state in
            if !state.closed { state.handlers.append(handler) }
            return state.closed
        }
        if closed { handler() }
    }

    var closeHandlerCount: Int { state.withLock { $0.handlers.count } }

    func close() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.closed else { return [] }
            state.closed = true
            defer { state.handlers = [] }
            return state.handlers
        }
        handlers.forEach { $0() }
    }

    var context: HAPRequestContext { HAPRequestContext(session: self) }
}

struct FakeDelegateError: Error {}

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

/// Records every streaming delegate call; `prepareStream` echoes the controller's SRTP parameters.
final class FakeStreamingDelegate: CameraStreamingDelegate {
    struct State {
        var prepares: [PrepareStreamRequest] = []
        var requests: [StreamRequest] = []
        var snapshots: [SnapshotRequest] = []
        var prepareError: (any Error)?
        var startError: (any Error)?
        var reconfigureError: (any Error)?
        var snapshotError: (any Error)?
        var snapshotData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        var prepareGate: Gate?
        /// `.start` / `.stop` requests wait for these when set.
        var startGate: Gate?
        var stopGate: Gate?
        /// Runs inside each `.start` call (e.g. to end the session from the delegate's side).
        var onStart: (@Sendable (UUID) -> Void)?
        var accessoryAddressOverride: String?
    }

    let state = Mutex(State())
    static let videoSSRC: UInt32 = 0x1111_2222
    static let audioSSRC: UInt32 = 0x3333_4444

    func snapshot(_ request: SnapshotRequest) async throws -> Data {
        let (error, data) = state.withLock { state in
            state.snapshots.append(request)
            return (state.snapshotError, state.snapshotData)
        }
        if let error { throw error }
        return data
    }

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        let (gate, error, override) = state.withLock { state in
            state.prepares.append(request)
            return (state.prepareGate, state.prepareError, state.accessoryAddressOverride)
        }
        if let gate { await gate.wait() }
        if let error { throw error }
        return PrepareStreamResponse(accessoryAddress: override ?? request.localAddress, videoPort: 50_000, audioPort: 50_002,
                                     videoSSRC: Self.videoSSRC, audioSSRC: Self.audioSSRC, videoSRTP: request.videoSRTP, audioSRTP: request.audioSRTP)
    }

    func handleStreamRequest(_ request: StreamRequest) async throws {
        let (error, gate, onStart) = state.withLock { state -> ((any Error)?, Gate?, (@Sendable (UUID) -> Void)?) in
            state.requests.append(request)
            switch request {
            case .start: return (state.startError, state.startGate, state.onStart)
            case .stop: return (nil, state.stopGate, nil)
            case .reconfigure: return (state.reconfigureError, nil, nil)
            }
        }
        if case .start(let id, _, _) = request { onStart?(id) }
        if let gate { await gate.wait() }
        if let error { throw error }
    }

    var prepares: [PrepareStreamRequest] { state.withLock { $0.prepares } }
    var requests: [StreamRequest] { state.withLock { $0.requests } }
    var snapshots: [SnapshotRequest] { state.withLock { $0.snapshots } }

    var stopIDs: [UUID] {
        requests.compactMap { if case .stop(let id) = $0 { return id } else { return nil } }
    }

    var startIDs: [UUID] {
        requests.compactMap { if case .start(let id, _, _) = $0 { return id } else { return nil } }
    }
}

/// Records every recording delegate call. `recordingStream` hands out a stream whose continuation the test drives
/// (`continuation(for:)`), or replays `script` when set.
final class FakeRecordingDelegate: CameraRecordingDelegate {
    enum Call: Equatable {
        case active(Bool)
        case configuration(CameraRecordingConfiguration?)
        case audioActive(Bool)
        case stream(Int)
        case acknowledge(Int)
        case close(Int, HDSProtocolReason?)
    }

    struct State {
        var calls: [Call] = []
        var continuations: [Int: AsyncThrowingStream<RecordingPacket, any Error>.Continuation] = [:]
        var terminated: Set<Int> = []
        var script: [RecordingPacket]?
        var streamError: (any Error)?
        /// When set, `recordingStream` waits for it before returning.
        var streamGate: Gate?
        /// When set, `acknowledgeStream` / `closeRecordingStream` record their call and then wait for it (a slow delegate).
        var endGate: Gate?
    }

    let state = Mutex(State())

    func updateRecordingActive(_ active: Bool) async { record(.active(active)) }
    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) async { record(.configuration(configuration)) }
    func updateRecordingAudioActive(_ active: Bool) async { record(.audioActive(active)) }

    func recordingStream(streamID: Int) async throws -> AsyncThrowingStream<RecordingPacket, any Error> {
        if let gate = state.withLock({ state -> Gate? in
            guard let gate = state.streamGate else { return nil }
            state.calls.append(.stream(streamID))
            return gate
        }) {
            await gate.wait()
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RecordingPacket.self)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.terminated.insert(streamID) }
        }
        let (script, error) = state.withLock { state in
            if state.streamGate == nil { state.calls.append(.stream(streamID)) }
            state.continuations[streamID] = continuation
            return (state.script, state.streamError)
        }
        if let error { throw error }
        if let script {
            for packet in script { continuation.yield(packet) }
        }
        return stream
    }

    func acknowledgeStream(streamID: Int) async {
        record(.acknowledge(streamID))
        await state.withLock { $0.endGate }?.wait()
    }

    func closeRecordingStream(streamID: Int, reason: HDSProtocolReason?) async {
        record(.close(streamID, reason))
        await state.withLock { $0.endGate }?.wait()
    }

    private func record(_ call: Call) {
        state.withLock { $0.calls.append(call) }
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func continuation(for streamID: Int) -> AsyncThrowingStream<RecordingPacket, any Error>.Continuation? {
        state.withLock { $0.continuations[streamID] }
    }

    func isTerminated(_ streamID: Int) -> Bool { state.withLock { $0.terminated.contains(streamID) } }

    /// Calls that end a stream (acknowledge / close).
    var endings: [Call] {
        calls.filter {
            switch $0 {
            case .acknowledge, .close: true
            default: false
            }
        }
    }
}

/// The value of `task`, or nil if it has none after `timeout` (the task keeps running): a regression that makes a
/// request hang fails the test instead of hanging the run.
func value<T: Sendable>(of task: Task<T, Never>, within timeout: Duration = .seconds(5)) async -> T? {
    let box = Box<T?>(nil)
    Task { box.set(await task.value) }
    _ = await eventually(timeout: timeout) { box.value != nil }
    return box.value
}
