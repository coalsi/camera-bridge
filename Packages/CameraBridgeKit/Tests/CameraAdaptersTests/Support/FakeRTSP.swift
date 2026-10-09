import BridgeSupport
import Foundation
import MediaCore
import RTSP
import TestSupport
@testable import CameraAdapters

/// An `RTSPSessionClient` double: never touches the network.
final class FakeRTSPSession: RTSPSessionClient, Sendable {
    let info: RTSPSessionInfo?
    let error: (any Error)?
    /// `sendBackchannel` blocks until `close()` (a camera that stopped reading), ignoring cancellation like a real socket.
    let stallSends: Bool
    let sent = Box<[Data]>([])
    let calls = Box<[String]>([])
    let closed = Box(false)
    /// `close()` returns this long after a stalled send has already failed with `.closed` (a socket can report the
    /// two in either order).
    let closeDelay: Duration

    init(info: RTSPSessionInfo?, error: (any Error)? = nil, stallSends: Bool = false, closeDelay: Duration = .zero) {
        self.info = info
        self.error = error
        self.stallSends = stallSends
        self.closeDelay = closeDelay
    }

    func connect() async throws -> RTSPSessionInfo {
        calls.update { $0.append("connect") }
        if let error { throw error }
        guard let info else { throw CameraAdapterError.invalidResponse("no info") }
        return info
    }

    func play() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        calls.update { $0.append("play") }
        return AsyncThrowingStream { _ in }
    }

    func sendBackchannel(_ frame: EncodedAudioFrame) async throws {
        if closed.value { throw TransportError.closed }
        if stallSends {
            while !closed.value { try? await Task.sleep(for: .milliseconds(5)) }
            throw TransportError.closed
        }
        sent.update { $0.append(frame.data) }
    }

    func close() async {
        calls.update { $0.append("close") }
        closed.set(true)
        if closeDelay > .zero { try? await Task.sleep(for: closeDelay) }
    }
}

/// Records the configurations requested from the factory; hands out `session`, or a new session per call from `make`.
final class FakeRTSPFactory: Sendable {
    let configurations = Box<[RTSPConfiguration]>([])
    let sessions = Box<[FakeRTSPSession]>([])
    private let make: @Sendable (RTSPConfiguration) -> FakeRTSPSession

    init(_ session: FakeRTSPSession) { make = { _ in session } }

    init(make: @escaping @Sendable () -> FakeRTSPSession) { self.make = { _ in make() } }

    /// A session per configuration (e.g. a camera that answers talkback-only sessions differently).
    init(makeFor: @escaping @Sendable (RTSPConfiguration) -> FakeRTSPSession) { self.make = makeFor }

    var session: FakeRTSPSession { sessions.value.last ?? make(RTSPConfiguration(url: URL(string: "rtsp://192.0.2.1/")!, credentials: nil)) }

    var factory: RTSPSessionFactory {
        { [configurations, sessions, make] configuration in
            configurations.update { $0.append(configuration) }
            let session = make(configuration)
            sessions.update { $0.append(session) }
            return session
        }
    }
}
