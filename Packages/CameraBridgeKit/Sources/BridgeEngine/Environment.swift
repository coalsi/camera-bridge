import BridgeSupport
import Foundation
import MediaCore
#if canImport(Darwin)
import PlatformApple
#endif
#if os(Linux)
import PlatformLinux
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
    /// What the NVR needs from the host to find free space and to name folders (statvfs lives in BridgeDaemon only). nil on the Mac app: the
    /// engine then reads Foundation's volume attributes and names camera folders after the camera.
    public var archivePolicy: ArchivePlatformPolicy?
    /// Development only (the daemon's hidden `--demo-keyframe-seconds`, accepted with `--dev` or `--preview`): the demo camera's main stream
    /// keys every this many seconds instead of every 2, so the smart-codec path (the keyframe note above 10 s, the coarse caption above 4 s,
    /// `typicalGOP`) runs through the real engine. nil, or a value outside 1...120, keeps 2 s.
    public var demoKeyframeSeconds: Double?
    /// This machine serves time (NTP) to the local network: Camera Bridge OS's chrony does. "Set up for Camera Bridge" then points cameras'
    /// clocks at the bridge's address; elsewhere (the Mac app) that step is not offered. Off by default.
    public var servesTime: Bool = false
    /// This machine has Camera Bridge OS's internet guard: it answers the DNS of the cameras it watches with "does not exist" and keeps what
    /// they asked for (docs/superpowers/specs/2026-10-17-internet-guard-design.md). The daemon sets it where the guard is installed; elsewhere
    /// (the Mac app) "Watch its internet" is not offered. Off by default.
    public var hasInternetGuard: Bool = false
    /// Replaces the list of cameras the internet guard watches; an empty list turns it off. Throws a sentence the person can read. nil where
    /// there is no guard.
    public var setGuardedCameras: (@Sendable ([GuardedCamera]) async throws -> Void)?
    /// What the internet guard saw (Camera Bridge OS's `status/guard.json`); nil where there is no guard or it has not reported yet.
    public var guardReport: (@Sendable () async -> GuardReport?)?

    public init(dataDirectory: URL, platform: PlatformServices, codecs: any MediaCodecs, loopbackOnly: Bool = false, advertise: Bool = true,
                archivePolicy: ArchivePlatformPolicy? = nil, demoKeyframeSeconds: Double? = nil) {
        self.dataDirectory = dataDirectory
        self.platform = platform
        self.codecs = codecs
        self.loopbackOnly = loopbackOnly
        self.advertise = advertise
        self.archivePolicy = archivePolicy
        self.demoKeyframeSeconds = demoKeyframeSeconds
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

    #if os(Linux)
    /// `LinuxPlatform.services(dataDirectory:)` (POSIX sockets, Avahi, netlink, encrypted-file secrets in `dataDirectory`), the given
    /// codecs (default: ffmpeg child processes, `FFmpegMediaCodecs`), all interfaces, mDNS on. `dataDirectory` is
    /// /var/lib/camera-bridge on the OS image.
    public static func linux(dataDirectory: URL, codecs: any MediaCodecs = FFmpegMediaCodecs(), loopbackOnly: Bool = false,
                             advertise: Bool = true) -> BridgeEnvironment {
        BridgeEnvironment(dataDirectory: dataDirectory, platform: LinuxPlatform.services(dataDirectory: dataDirectory), codecs: codecs,
                          loopbackOnly: loopbackOnly, advertise: advertise)
    }

    /// `directory`, the Linux transport, in-memory secrets, no advertising / power / network-change monitoring, loopback only;
    /// `codecs` as given (tests that need real codecs pass the ffmpeg ones).
    public static func testing(directory: URL, codecs: any MediaCodecs = UnavailableMediaCodecs()) -> BridgeEnvironment {
        BridgeEnvironment(dataDirectory: directory,
                          platform: PlatformServices(transport: LinuxNetworkTransport(), advertiser: NullServiceAdvertiser(),
                                                     secrets: InMemorySecretStore(), networkChanges: NullNetworkChangeMonitor(),
                                                     power: NullPowerManager()),
                          codecs: codecs, loopbackOnly: true, advertise: false)
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

// MARK: - The internet guard

/// How closely Camera Bridge OS's internet guard looks after a camera.
public enum GuardLevel: String, Codable, Sendable, CaseIterable {
    /// The camera asks the box for every internet name, and every answer is "does not exist", so it cannot find its cloud.
    case watch
}

/// A camera the internet guard looks after, by the address it has on the local network.
public struct GuardedCamera: Codable, Sendable, Equatable, Hashable {
    public var address: String
    public var level: GuardLevel

    public init(address: String, level: GuardLevel) {
        self.address = address
        self.level = level
    }
}

/// What the internet guard saw: Camera Bridge OS's `status/guard.json` (linux/os/README.md). The root side writes it, so everything is read
/// leniently: a field that is missing or of the wrong kind gets its default, and a camera without an address is left out.
public struct GuardReport: Codable, Sendable, Equatable {
    /// The system has the guard and reports on it.
    public var available: Bool
    /// The DNS for the watched cameras answers now. nil when the system does not say.
    public var running: Bool?
    public var updatedAt: Date?
    /// The time zone `today` is counted in.
    public var timeZone: String?
    /// Where `today` starts (to the hour).
    public var todayStart: Date?
    public var cameras: [Camera]

    public static let unavailable = GuardReport(available: false)

    public init(available: Bool, running: Bool? = nil, updatedAt: Date? = nil, timeZone: String? = nil, todayStart: Date? = nil, cameras: [Camera] = []) {
        self.available = available
        self.running = running
        self.updatedAt = updatedAt
        self.timeZone = timeZone
        self.todayStart = todayStart
        self.cameras = cameras
    }

    public func camera(at address: String) -> Camera? { cameras.first { $0.address == address } }

    /// One watched camera.
    public struct Camera: Codable, Sendable, Equatable {
        public var address: String
        /// nil: a level this build does not know.
        public var level: GuardLevel?
        /// Since when the box has watched it without a break: the later of when its address was put on the list, when the box's history
        /// started again, and when its DNS last started. nil when the box does not say.
        public var since: Date?
        /// Lookups since `todayStart`, and in the last 24 hours (to the hour).
        public var today: Int
        public var last24h: Int
        /// The names it asked for in the last 7 days, most asked first (at most 50).
        public var names: [Lookup]

        public init(address: String, level: GuardLevel?, since: Date? = nil, today: Int, last24h: Int, names: [Lookup]) {
            self.address = address
            self.level = level
            self.since = since
            self.today = today
            self.last24h = last24h
            self.names = names
        }

        private enum CodingKeys: String, CodingKey { case address, level, since, today, last24h, names }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let address = try? container.decodeIfPresent(String.self, forKey: .address)
            guard let address, !address.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .address, in: container, debugDescription: "a camera without an address")
            }
            self.address = address
            level = (try? container.decodeIfPresent(String.self, forKey: .level)).flatMap(GuardLevel.init(rawValue:))
            since = GuardReport.date(container, .since)
            today = GuardReport.count(container, .today)
            last24h = GuardReport.count(container, .last24h)
            names = GuardReport.elements(container, .names)
        }
    }

    /// A name a camera asked for: how often, first and last.
    public struct Lookup: Codable, Sendable, Equatable {
        public var name: String
        public var count: Int
        public var first: Date?
        public var last: Date?

        public init(name: String, count: Int, first: Date? = nil, last: Date? = nil) {
            self.name = name
            self.count = count
            self.first = first
            self.last = last
        }

        private enum CodingKeys: String, CodingKey { case name, count, first, last }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = try? container.decodeIfPresent(String.self, forKey: .name)
            guard let name, !name.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "a lookup without a name")
            }
            self.name = name
            count = GuardReport.count(container, .count)
            first = GuardReport.date(container, .first)
            last = GuardReport.date(container, .last)
        }
    }

    private enum CodingKeys: String, CodingKey { case available, running, updatedAt, timeZone, todayStart, cameras }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? container.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        running = try? container.decodeIfPresent(Bool.self, forKey: .running)
        updatedAt = Self.date(container, .updatedAt)
        timeZone = try? container.decodeIfPresent(String.self, forKey: .timeZone)
        todayStart = Self.date(container, .todayStart)
        cameras = Self.elements(container, .cameras)
    }

    /// The elements of an array that decode; the others are skipped.
    private static func elements<Key: CodingKey, Element: Decodable>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> [Element] {
        (try? container.decodeIfPresent([Lenient<Element>].self, forKey: key))?.compactMap(\.value) ?? []
    }

    /// A whole number given as a number or as digits; 0 otherwise.
    private static func count<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> Int {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return max(0, value) }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite, value >= 0, value < 1e15 { return Int(value) }
        if let text = try? container.decodeIfPresent(String.self, forKey: key), let value = Int(text) { return max(0, value) }
        return 0
    }

    /// An ISO 8601 time ("2026-10-17T17:46:01Z", with or without fractions of a second); nil otherwise.
    private static func date<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> Date? {
        guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
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
