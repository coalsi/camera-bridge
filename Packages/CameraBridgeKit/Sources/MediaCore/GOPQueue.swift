import Foundation
import Synchronization

/// A bounded queue between a producer and one consumer of a keyframe-structured stream (video access units, or a
/// `MediaSample` mix of video and audio). A plain drop-oldest buffer breaks such a stream: the oldest element is
/// usually the keyframe the elements behind it depend on, so a consumer that fell behind decodes grey/green smear until
/// the camera's next keyframe, which a long GOP puts seconds away. This queue drops whole GOPs instead:
///
/// - When a push finds the queue full it discards everything queued up to the next keyframe that is already queued (the
///   oldest GOP) and queues the new element after it, so the queue still starts on a keyframe and the consumer sees a
///   keyframe right after the gap.
/// - A queue holding a single GOP (no later keyframe) is emptied; a new keyframe is queued then, any other element is
///   refused and `Push.awaitingKeyframe` tells the producer to skip deltas until the next keyframe (the elements queued
///   before the overflow stay contiguous: the consumer drains them and then meets a keyframe).
///
/// Whatever the consumer reads after a gap is therefore a keyframe. `stream` is the consumer's `AsyncStream`: ending the
/// consumer's task, dropping the stream or `terminate()` runs `onTerminate` once and frees the queue; `finish()` ends the
/// stream after what is queued (a cancelled `MediaSubscription` still delivers its backlog).
public final class GOPQueue<Element: Sendable>: Sendable {
    /// What a `push` did.
    public struct Push: Sendable, Equatable {
        /// The element is in the queue.
        public var queued: Bool
        /// Queued elements discarded to make room.
        public var dropped = 0
        /// The queue was emptied and the element, a delta, was refused: the producer skips deltas until a keyframe.
        public var awaitingKeyframe = false
        /// The queue ended (finished or terminated): nothing was queued.
        public var closed = false

        public var overflowed: Bool { dropped > 0 || awaitingKeyframe }
    }

    private struct State {
        var items: [Element] = []
        var head = 0
        var waiter: CheckedContinuation<Element?, Never>?
        var finished = false
        var terminated = false
        var count: Int { items.count - head }

        /// Releases the read prefix once it is large.
        mutating func compact() {
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 256, head * 2 >= items.count {
                items.removeFirst(head)
                head = 0
            }
        }
    }

    private let capacity: Int
    private let isKeyframe: @Sendable (Element) -> Bool
    private let onTerminate: @Sendable () -> Void
    private let state = Mutex(State())

    /// `capacity` elements at most (at least 1). `onTerminate` runs once when the consumer went away.
    public init(capacity: Int, isKeyframe: @escaping @Sendable (Element) -> Bool, onTerminate: @escaping @Sendable () -> Void = {}) {
        self.capacity = max(1, capacity)
        self.isKeyframe = isKeyframe
        self.onTerminate = onTerminate
    }

    /// Queued elements not yet read.
    public var count: Int { state.withLock { $0.count } }

    @discardableResult
    public func push(_ element: Element) -> Push {
        var result = Push(queued: true)
        let resume = state.withLock { state -> (CheckedContinuation<Element?, Never>, Element)? in
            guard !state.finished else {
                result = Push(queued: false, closed: true)
                return nil
            }
            if let waiter = state.waiter {   // empty queue, consumer waiting
                state.waiter = nil
                return (waiter, element)
            }
            if state.count >= capacity {
                // The oldest GOP goes: everything before the first keyframe after the head.
                let next = ((state.head + 1)..<max(state.head + 1, state.items.count)).first { isKeyframe(state.items[$0]) }
                let dropEnd = next ?? state.items.count
                result.dropped = dropEnd - state.head
                state.head = dropEnd
                if next == nil, !isKeyframe(element) {
                    state.compact()
                    result.queued = false
                    result.awaitingKeyframe = true
                    return nil
                }
            }
            state.items.append(element)
            state.compact()
            return nil
        }
        if let (waiter, element) = resume { waiter.resume(returning: element) }
        return result
    }

    /// Ends the stream after the queued elements.
    public func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Element?, Never>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// The consumer went away: ends the stream at once, discards what is queued and runs `onTerminate` (once).
    public func terminate() {
        let (waiter, first) = state.withLock { state -> (CheckedContinuation<Element?, Never>?, Bool) in
            let first = !state.terminated
            state.terminated = true
            state.finished = true
            state.items.removeAll()
            state.head = 0
            defer { state.waiter = nil }
            return (state.waiter, first)
        }
        waiter?.resume(returning: nil)
        if first { onTerminate() }
    }

    /// The consumer's stream. Make it once.
    public func makeStream() -> AsyncStream<Element> {
        let release = Release { [self] in terminate() }
        return AsyncStream(unfolding: { [self] in
            withExtendedLifetime(release) {}
            return await next()
        })
    }

    private func next() async -> Element? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                let taken = state.withLock { state -> (Element?, Bool) in
                    if state.head < state.items.count {
                        let element = state.items[state.head]
                        state.head += 1
                        state.compact()
                        return (element, true)
                    }
                    if state.finished { return (nil, true) }
                    state.waiter = continuation
                    return (nil, false)
                }
                if taken.1 { continuation.resume(returning: taken.0) }
            }
        } onCancel: {
            terminate()
        }
    }

    /// Terminates the queue when the consumer's stream is released.
    private final class Release: Sendable {
        private let action: @Sendable () -> Void
        init(_ action: @escaping @Sendable () -> Void) { self.action = action }
        deinit { action() }
    }
}
