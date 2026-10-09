import BridgeSupport
import Foundation
import MediaCore
#if canImport(Darwin)
import PlatformApple
#endif

/// Everything the engine gets from outside: storage location, platform services and codecs.
public struct BridgeEnvironment: Sendable {
    /// Application Support/CameraBridge (container when sandboxed).
    public var dataDirectory: URL
    /// Transport, advertiser, secrets, network changes, power.
    public var platform: PlatformServices
    public var codecs: any MediaCodecs
    /// Tests.
    public var loopbackOnly: Bool
    /// Tests may disable Bonjour.
    public var advertise: Bool

    public init(dataDirectory: URL, platform: PlatformServices, codecs: any MediaCodecs, loopbackOnly: Bool = false, advertise: Bool = true) {
        self.dataDirectory = dataDirectory
        self.platform = platform
        self.codecs = codecs
        self.loopbackOnly = loopbackOnly
        self.advertise = advertise
    }

    #if canImport(Darwin)
    /// `ApplePlatform.services()` + `AppleMediaCodecs`, Application Support/CameraBridge, all interfaces, Bonjour on.
    public static func live() -> BridgeEnvironment {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return BridgeEnvironment(dataDirectory: base.appending(path: "CameraBridge", directoryHint: .isDirectory),
                                 platform: ApplePlatform.services(), codecs: AppleMediaCodecs(), loopbackOnly: false, advertise: true)
    }

    /// `directory`, Apple transport and codecs, in-memory secrets, no advertising / power / network-change
    /// monitoring, loopback only.
    public static func testing(directory: URL) -> BridgeEnvironment {
        BridgeEnvironment(dataDirectory: directory,
                          platform: PlatformServices(transport: AppleNetworkTransport(), advertiser: NullServiceAdvertiser(),
                                                     secrets: InMemorySecretStore(), networkChanges: NullNetworkChangeMonitor(),
                                                     power: NullPowerManager()),
                          codecs: AppleMediaCodecs(), loopbackOnly: true, advertise: false)
    }
    #endif

    /// The preview engine's environment: `inert`, except that the Apple codecs are available where they exist, so the preview
    /// engine's synthetic streams (`BridgeEngine.liveVideo`) can be encoded. Nothing in the preview engine reaches a transport.
    static func preview(directory: URL) -> BridgeEnvironment {
        var environment = inert(directory: directory)
        #if canImport(Darwin)
        environment.codecs = AppleMediaCodecs()
        #endif
        return environment
    }

    /// Portable environment that can never touch the network or a codec (every transport/codec call throws):
    /// SwiftUI previews and platforms without a PlatformApple equivalent yet.
    static func inert(directory: URL) -> BridgeEnvironment {
        BridgeEnvironment(dataDirectory: directory,
                          platform: PlatformServices(transport: InertTransport(), advertiser: NullServiceAdvertiser(),
                                                     secrets: InMemorySecretStore(), networkChanges: NullNetworkChangeMonitor(),
                                                     power: NullPowerManager()),
                          codecs: InertCodecs(), loopbackOnly: true, advertise: false)
    }
}

private final class InertTransport: NetworkTransport {
    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        throw TransportError.failed("networking is disabled in this environment")
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        throw TransportError.failed("networking is disabled in this environment")
    }
}

private final class InertCodecs: MediaCodecs {
    private static let unavailable = MediaCodecError.unsupported("codecs are disabled in this environment")

    func makeVideoDecoder(format: VideoFormat) throws -> any VideoDecoding { throw Self.unavailable }
    func makeVideoEncoder(settings: VideoEncoderSettings) throws -> any VideoEncoding { throw Self.unavailable }
    func makeVideoTranscoder(output: VideoEncoderSettings) throws -> any VideoTranscoding { throw Self.unavailable }
    func makeAudioTranscoder(input: AudioFormat, output: AudioEncoderSettings) throws -> any AudioTranscoding { throw Self.unavailable }
    func jpeg(from frame: any DecodedVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double) throws -> Data { throw Self.unavailable }
    func resizeJPEG(_ jpeg: Data, maxWidth: Int?, maxHeight: Int?) throws -> Data { throw Self.unavailable }
    func silentAACFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        throw Self.unavailable
    }
    func makeSyntheticSource(displayName: String, width: Int, height: Int, fps: Int, keyframeInterval: Duration,
                             audio: AudioCodec?, audioSampleRate: Int) -> any MediaSource {
        InertSource(displayName: displayName)
    }

    private final class InertSource: MediaSource {
        let displayName: String
        init(displayName: String) { self.displayName = displayName }
        func samples() async throws -> AsyncThrowingStream<MediaSample, any Error> { throw InertCodecs.unavailable }
        func stop() async {}
    }
}
