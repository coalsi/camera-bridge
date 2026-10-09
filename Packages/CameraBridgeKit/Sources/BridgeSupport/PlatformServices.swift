import Foundation
import Synchronization

// Platform service protocols. Portable modules reach the OS only through these (contracts: portability rule);
// PlatformApple implements them on macOS, a future Linux edition with SwiftNIO/Avahi/etc.

/// One TCP connection (accepted by a `TCPListener` or opened by `NetworkTransport.connect`).
public protocol TCPConnection: AnyObject, Sendable {
    var id: UUID { get }
    /// IP literal of our side of the connection (no port, no IPv6 zone).
    var localAddress: String { get }
    /// IP literal of the peer (no port, no IPv6 zone).
    var remoteAddress: String { get }
    var isIPv6: Bool { get }
    /// The IPv6 zone of the connection's addresses (the interface name, e.g. `en0`) when they carry one — link-local
    /// (fe80::/10) addresses, which are reachable only through it; nil otherwise. Default: nil.
    var zone: String? { get }
    /// Up to `maximumLength` bytes as soon as any arrive; nil = orderly EOF. Throws `TransportError` on failure.
    func receive(maximumLength: Int) async throws -> Data?
    /// Returns once the stack has accepted the bytes. Throws `TransportError` on failure.
    func send(_ data: Data) async throws
    /// Idempotent. Pending and later `receive`/`send` calls throw `TransportError.closed`.
    func close()
}

extension TCPConnection {
    public var zone: String? { nil }
}

public protocol TCPListener: AnyObject, Sendable {
    /// The bound port (the ephemeral port when listening on 0).
    var port: UInt16 { get }
    /// Accepted connections, ready to use. Single consumer; finishes when the listener closes or fails.
    var connections: AsyncStream<any TCPConnection> { get }
    /// Stops accepting. Connections already delivered stay open (their owner closes them).
    func close()
}

public protocol NetworkTransport: Sendable {
    /// `loopbackOnly` binds 127.0.0.1 only (tests); otherwise all interfaces. Port 0 = ephemeral.
    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection
}

public enum TransportError: Error, Equatable, Sendable {
    /// macOS Local Network privacy denied the operation (NWPath `.localNetworkDenied`, DNS-SD -65570).
    case localNetworkDenied
    case connectionRefused
    case timedOut
    /// The connection or listener was closed (locally or by the peer resetting it).
    case closed
    case addressInUse
    case failed(String)
}

// MARK: - Service advertising (Bonjour)

public struct ServiceAdvertisement: Sendable, Equatable {
    public var name: String
    /// e.g. "_hap._tcp"
    public var type: String
    public var port: UInt16
    public var txt: [String: String]

    public init(name: String, type: String, port: UInt16, txt: [String: String]) {
        self.name = name
        self.type = type
        self.port = port
        self.txt = txt
    }
}

public protocol AdvertisedService: AnyObject, Sendable {
    func updateTXT(_ txt: [String: String]) async throws
    /// Errors after registration, e.g. `.localNetworkDenied` (DNS-SD -65570). Finishes on `cancel()`.
    var failures: AsyncStream<TransportError> { get }
    /// Idempotent: withdraws the advertisement.
    func cancel()
}

public protocol ServiceAdvertiser: Sendable {
    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService
}

/// What looking for a service on the network found (`ServiceBrowsing.lookup`).
public enum ServiceLookup: Sendable, Equatable {
    /// The service is on the network, with this TXT record.
    case found([String: String])
    /// Nothing by that name answered within the limit.
    case notFound
    /// Browsing itself could not run (Local Network access denied, the daemon is not reachable): says nothing about the service.
    case unavailable(String)
}

/// Looks for a service the way a controller does, to check what this machine advertises is what the network sees.
public protocol ServiceBrowsing: Sendable {
    /// The service `name` of `type` (e.g. "_hap._tcp"), waiting at most `timeout` for it to show up.
    func lookup(type: String, name: String, timeout: Duration) async -> ServiceLookup
}

/// Finds nothing is wrong and nothing is there: browsing is `.unavailable` (tests, `advertise = false`).
public final class NullServiceBrowser: ServiceBrowsing {
    public init() {}

    public func lookup(type: String, name: String, timeout: Duration) async -> ServiceLookup {
        .unavailable("browsing is not available")
    }
}

/// Advertises nothing (tests, `advertise = false`). The returned service accepts TXT updates and never fails.
public final class NullServiceAdvertiser: ServiceAdvertiser {
    public init() {}

    public func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService {
        NullAdvertisedService()
    }
}

private final class NullAdvertisedService: AdvertisedService {
    private let failureStream = AsyncStream<TransportError>.makeStream()

    var failures: AsyncStream<TransportError> { failureStream.stream }

    func updateTXT(_ txt: [String: String]) async throws {}

    func cancel() {
        failureStream.continuation.finish()
    }

    deinit {
        failureStream.continuation.finish()
    }
}

// MARK: - Secrets

public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    /// nil deletes (deleting a missing item is not an error).
    func write(_ data: Data?, account: String) throws
}

/// Process-local secret store (tests, previews).
public final class InMemorySecretStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    public init() {}

    public func read(account: String) throws -> Data? {
        items.withLock { $0[account] }
    }

    public func write(_ data: Data?, account: String) throws {
        items.withLock { $0[account] = data }
    }
}

// MARK: - Network changes

public protocol NetworkChangeMonitoring: Sendable {
    /// One element per path/interface change (not for the initial path). Each access is a new subscription.
    var changes: AsyncStream<Void> { get }
}

/// Never reports a change: `changes` finishes immediately.
public final class NullNetworkChangeMonitor: NetworkChangeMonitoring {
    public init() {}

    public var changes: AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Power

public protocol PowerManaging: Sendable {
    /// Prevents App Nap / automatic termination (idle system sleep still allowed). Idempotent.
    func beginBackgroundActivity(reason: String)
    /// Ends the activity `beginBackgroundActivity` began (the bridge paused or stopped). Idempotent.
    func endBackgroundActivity()
    /// Holds or releases an assertion preventing idle system sleep. Idempotent.
    func setKeepSystemAwake(_ awake: Bool, reason: String)
    /// Whether this machine runs on a battery (a laptop) and so sleeps when its lid closes or the battery runs low; false
    /// for a desktop that stays on mains power.
    var hasBattery: Bool { get }
}

extension PowerManaging {
    /// Default: does nothing, the behaviour before this requirement existed (W4 review). An addition to a contract
    /// protocol, so a conformer written to the contract (`beginBackgroundActivity` + `setKeepSystemAwake`) still
    /// compiles; a conformer whose `beginBackgroundActivity` holds something implements it.
    public func endBackgroundActivity() {}

    /// Default: unknown counts as a laptop, so nothing about a machine of unknown kind is decided as for a desktop.
    public var hasBattery: Bool { true }
}

public final class NullPowerManager: PowerManaging {
    public init() {}
    public func beginBackgroundActivity(reason: String) {}
    public func endBackgroundActivity() {}
    public func setKeepSystemAwake(_ awake: Bool, reason: String) {}
}

// MARK: - Single instance

/// Keeps a second copy of the app that runs on the same configuration from starting its bridge: two copies would both
/// advertise the same cameras (same identities) and fight over their ports.
public protocol InstanceLocking: Sendable {
    /// Takes the lock named by `directory` (the configuration's data directory) for this process. nil = taken (or this
    /// platform has no lock); otherwise a sentence for the person saying another copy runs. Idempotent for the holder.
    func acquire(directory: URL) -> String?
    /// Releases what `acquire` took. Idempotent.
    func release()
}

/// Never refuses (tests, previews, platforms without a lock).
public final class NullInstanceLock: InstanceLocking {
    public init() {}
    public func acquire(directory: URL) -> String? { nil }
    public func release() {}
}

// MARK: - Bundle

/// Everything platform-specific a portable module may need, injected by the caller
/// (`ApplePlatform.services()` on macOS).
public struct PlatformServices: Sendable {
    public var transport: any NetworkTransport
    public var advertiser: any ServiceAdvertiser
    public var secrets: any SecretStore
    public var networkChanges: any NetworkChangeMonitoring
    public var power: any PowerManaging
    /// Checks what the network sees of this machine's advertisements (`HAPHealthMonitor`); `NullServiceBrowser` checks nothing.
    public var browser: any ServiceBrowsing
    /// Refuses a second copy on the same configuration; `NullInstanceLock` never does.
    public var instanceLock: any InstanceLocking
    /// Starts bundled helper programs (go2rtc); `NullHelperLauncher` runs none.
    public var helpers: any HelperLaunching

    public init(transport: any NetworkTransport, advertiser: any ServiceAdvertiser, secrets: any SecretStore,
                networkChanges: any NetworkChangeMonitoring, power: any PowerManaging, browser: any ServiceBrowsing = NullServiceBrowser(),
                instanceLock: any InstanceLocking = NullInstanceLock(), helpers: any HelperLaunching = NullHelperLauncher()) {
        self.transport = transport
        self.advertiser = advertiser
        self.secrets = secrets
        self.networkChanges = networkChanges
        self.power = power
        self.browser = browser
        self.instanceLock = instanceLock
        self.helpers = helpers
    }
}
