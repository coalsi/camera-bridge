import Foundation

/// Symmetric RTP's decision, once: where the media goes, from the sources of the controller's authenticated packets. The
/// first packet decides (the destination keeps its host when the packet came from it, else moves to the packet's source);
/// after that a different source is followed only when the host the stream is going to has been silent for `relatchAfter`.
/// Without that, a controller whose video and audio (or two of whose interfaces) answer from different addresses would
/// make the stream flap between them with every packet.
struct DestinationLatch {
    enum Decision: Equatable {
        /// The packet came from the destination.
        case unchanged
        /// Another source while the destination is still answering; `first` is true the first time (it is worth one log line).
        case ignored(first: Bool)
        /// Move the stream to the packet's source; `silentFor` is how long the old destination was silent (nil: first packet).
        case moved(silentFor: Duration?)
    }

    private var decided = false
    private var lastHeard: ContinuousClock.Instant?
    private var notedForeign = false

    /// `source` sent an authenticated packet while the media goes to `destination`.
    mutating func observe(source: String, destination: String, now: ContinuousClock.Instant, relatchAfter: Duration) -> Decision {
        if SocketAddress.sameHost(source, destination) {
            decided = true
            lastHeard = now
            return .unchanged
        }
        var silent: Duration?
        if decided {
            guard let heard = lastHeard, now - heard >= relatchAfter else {
                defer { notedForeign = true }
                return .ignored(first: !notedForeign)
            }
            silent = now - heard
        }
        decided = true
        lastHeard = now
        notedForeign = false
        return .moved(silentFor: silent)
    }
}
