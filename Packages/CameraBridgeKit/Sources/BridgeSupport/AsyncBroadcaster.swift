import Foundation
import Synchronization

/// Fan-out of a stream of values to any number of `AsyncStream` subscribers.
/// Each subscriber receives every element yielded after it subscribed (bounded by `bufferingNewest`).
public final class AsyncBroadcaster<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())
    private let bufferingNewest: Int

    public init(bufferingNewest: Int = 64) {
        self.bufferingNewest = max(1, bufferingNewest)
    }

    public func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(bufferingNewest))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        let alreadyFinished = state.withLock { state -> Bool in
            if state.isFinished { return true }
            state.continuations[id] = continuation
            return false
        }
        if alreadyFinished { continuation.finish() }
        return stream
    }

    public func yield(_ element: Element) {
        let targets = state.withLock { Array($0.continuations.values) }
        for continuation in targets { continuation.yield(element) }
    }

    /// Finishes every current subscriber; later subscribers receive an already-finished stream.
    public func finish() {
        let targets = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            state.isFinished = true
            let all = Array(state.continuations.values)
            state.continuations.removeAll()
            return all
        }
        for continuation in targets { continuation.finish() }
    }

    public var subscriberCount: Int {
        state.withLock { $0.continuations.count }
    }
}
