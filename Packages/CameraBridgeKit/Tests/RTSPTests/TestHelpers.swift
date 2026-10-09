import Foundation
import MediaCore
import Synchronization
import Testing

/// Collected output of a sample stream.
struct Collected: Sendable {
    var samples: [MediaSample]
    var error: (any Error)?
    /// The stream ended (normally or by throwing) before the collection stopped.
    var ended: Bool

    var video: [EncodedVideoFrame] {
        samples.compactMap { if case .video(let frame) = $0 { frame } else { nil } }
    }

    var audio: [EncodedAudioFrame] {
        samples.compactMap { if case .audio(let frame) = $0 { frame } else { nil } }
    }
}

private final class CollectorBox: Sendable {
    private let state = Mutex(Collected(samples: [], error: nil, ended: false))
    private let stopRequested = Mutex(false)

    func append(_ sample: MediaSample, stop: @Sendable ([MediaSample]) -> Bool) -> Bool {
        state.withLock { s in
            s.samples.append(sample)
            let done = stop(s.samples)
            if done { stopRequested.withLock { $0 = true } }
            return done
        }
    }

    func end(_ error: (any Error)?) {
        state.withLock {
            $0.error = error
            $0.ended = true
        }
    }

    var isDone: Bool { state.withLock { $0.ended } || stopRequested.withLock { $0 } }
    var snapshot: Collected { state.withLock { $0 } }
}

/// Reads `stream` until `stop` returns true, the stream ends, or `timeout` passes (then the reading task is
/// cancelled, which terminates the stream).
func collect(_ stream: AsyncThrowingStream<MediaSample, any Error>, timeout: Duration,
             until stop: @escaping @Sendable ([MediaSample]) -> Bool = { _ in false }) async -> Collected {
    let box = CollectorBox()
    let task = Task {
        do {
            for try await sample in stream {
                if box.append(sample, stop: stop) { return }
            }
            box.end(nil)
        } catch {
            box.end(error)
        }
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !box.isDone, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    await task.value
    return box.snapshot
}

func videoFrameCount(_ samples: [MediaSample]) -> Int {
    samples.reduce(0) { count, sample in if case .video = sample { count + 1 } else { count } }
}
