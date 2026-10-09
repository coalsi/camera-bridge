import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Which of a camera's streams an in-app viewer wants (`BridgeEngine.liveVideo`).
public enum LiveVideoStream: String, Sendable, Equatable, CaseIterable {
    /// The camera's main stream (always connected).
    case main
    /// The sub stream: lower resolution, connected on demand and disconnected shortly after the last user (a HomeKit
    /// viewer or an app viewer) leaves. A camera without a usable sub stream serves the main stream instead.
    case sub
    /// The engine chooses: the sub stream when the main stream is taller than 1440 px and the viewer shows it small
    /// (`displayWidth` at most 1280 px, or not given), else the main stream.
    case automatic
}

/// An app viewer's subscription to a camera's live encoded video (and optionally audio), delivered as the camera's own
/// access units: no transcoding. Every subscription holds a lease on the stream it reads, exactly as a HomeKit viewer
/// does: the sub stream starts on demand and is released when the subscription ends, whichever way it ends — `cancel()`,
/// the consumer's task finishing, or dropping `samples`.
///
/// Delivery starts at the newest keyframe the hub holds (the replay of the newest GOP, so the first picture appears at
/// once), then continues live. After the camera's ingest reconnects, the first video sample is again a keyframe (the hub
/// makes every subscriber wait for one): a consumer follows format changes by the keyframe's `format`.
public struct LiveVideoSubscription: Sendable {
    /// Video and (when requested) audio access units. The first video sample is a keyframe. Audio from the replay is not
    /// delivered (it would play seconds late).
    public let samples: AsyncStream<MediaSample>
    /// The stream actually read: `.main` or `.sub`, never `.automatic`.
    public let stream: LiveVideoStream
    /// Ends the subscription and releases its lease (idempotent).
    public let cancel: @Sendable () -> Void

    public init(samples: AsyncStream<MediaSample>, stream: LiveVideoStream, cancel: @escaping @Sendable () -> Void) {
        self.samples = samples
        self.stream = stream
        self.cancel = cancel
    }
}

/// Subscribes to a hub for an app viewer (the engine's `liveVideo`).
enum LiveVideoPump {
    /// Samples a slow consumer may fall behind by before its oldest GOP is dropped (`GOPQueue`): what it reads after such a
    /// gap is a keyframe, so a viewer never decodes deltas whose keyframe it lost.
    static let bufferLimit = 600
    private static let log = Log(category: "LiveVideo")

    /// Subscribes to `lease.hub` at its newest keyframe. `onEnd` runs once the subscription ended and the lease was
    /// released. `audio` false drops audio samples; the replayed ones are always dropped.
    static func start(lease: HubLease, audio: Bool, onEnd: @escaping @Sendable () async -> Void) async -> LiveVideoSubscription {
        let source = await lease.hub.subscribe(from: .prebuffer(.zero), bufferLimit: bufferLimit)
        let replayCount = source.replayCount
        let overflows = OverflowLog()
        // The consumer leaving (cancel, a finished task, a dropped stream) ends the hub subscription, which ends the pump.
        let queue = GOPQueue<MediaSample>(capacity: bufferLimit, isKeyframe: { $0.isKeyframeSample }, onTerminate: { source.cancel() })
        let samples = queue.makeStream()
        let pump = Task {
            var index = 0
            var skippingToKeyframe = false
            for await sample in source.samples {
                defer { index += 1 }
                if case .audio = sample, !audio || index < replayCount { continue }
                if skippingToKeyframe {
                    guard sample.isKeyframeSample else { continue }
                    skippingToKeyframe = false
                }
                let push = queue.push(sample)
                if push.awaitingKeyframe { skippingToKeyframe = true }
                if push.overflowed { overflows.record(dropped: push.dropped, log: log) }
            }
            queue.finish()
        }
        // Releases the lease once the pump ended: the subscription is cancelled, the consumer dropped the stream, or the
        // hub's samples finished.
        Task {
            await pump.value
            await lease.release()
            await onEnd()
        }
        return LiveVideoSubscription(samples: samples, stream: lease.isSubStream ? .sub : .main, cancel: { queue.terminate() })
    }

    /// One warning per overflow incident, at most one per 10 s.
    private final class OverflowLog: Sendable {
        private let state = Mutex<(last: ContinuousClock.Instant?, suppressed: Int)>((nil, 0))

        func record(dropped: Int, log: Log) {
            let now = ContinuousClock.now
            let suppressed = state.withLock { state -> Int? in
                if let last = state.last, now - last < .seconds(10) {
                    state.suppressed += 1
                    return nil
                }
                defer {
                    state.last = now
                    state.suppressed = 0
                }
                return state.suppressed
            }
            guard let suppressed else { return }
            log.warning("an in-app viewer is not keeping up: dropped \(dropped) queued samples (its oldest GOP); it resumes at a keyframe"
                        + (suppressed > 0 ? " (\(suppressed) more overflows since the last warning)" : ""))
        }
    }
}
