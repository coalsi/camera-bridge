import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// A camera's RTSP stream as a `MediaSource`. Each `samples()` call opens a fresh `RTSPClient` session (closing the
/// previous one): the returned stream throws on disconnect, stall (`RTSPError.timeout`) or protocol failure, and
/// finishes normally after `stop()`. Reconnection policy (backoff) belongs to the caller. The sessions share one
/// `BasicDowngradeGuard`: once the camera asked for Digest, a reconnect never answers a Basic challenge.
public final class RTSPMediaSource: MediaSource {
    public let displayName: String
    private let configuration: RTSPConfiguration
    private let transport: any NetworkTransport
    private let current = Mutex<RTSPClient?>(nil)
    private let lastInfo = Mutex<RTSPSessionInfo?>(nil)
    /// Shared by every session: once the camera asked for Digest, no reconnect answers Basic.
    private let downgradeGuard = BasicDowngradeGuard()

    public init(configuration: RTSPConfiguration, displayName: String, transport: any NetworkTransport) {
        self.configuration = configuration
        self.displayName = displayName
        self.transport = transport
    }

    /// Tracks and formats of the most recent successful connection.
    public var sessionInfo: RTSPSessionInfo? { lastInfo.withLock { $0 } }

    public func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> {
        let client = RTSPClient(configuration: configuration, transport: transport, videoFrameTimeout: nil, downgradeGuard: downgradeGuard)
        let previous = current.withLock { slot in
            defer { slot = client }
            return slot
        }
        await previous?.close()
        do {
            let info = try await client.connect()
            lastInfo.withLock { $0 = info }
            return try await client.play()
        } catch {
            await client.close()
            current.withLock { slot in
                if slot === client { slot = nil }
            }
            throw error
        }
    }

    public func stop() async {
        let client = current.withLock { slot in
            defer { slot = nil }
            return slot
        }
        await client?.close()
    }
}
