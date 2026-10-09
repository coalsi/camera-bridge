#if os(macOS)
import BridgeSupport
import Foundation
import Network
import Synchronization

/// `NetworkChangeMonitoring` over `NWPathMonitor` (cellular and loopback excluded). Emits once per change of path
/// status, of the interfaces and gateways that matter (Wi-Fi/Ethernet switches, new DHCP networks) or of the addresses the
/// Ethernet and Wi-Fi interfaces hold (a renewed lease, a new IPv6 prefix); VPN tunnels, AirDrop and other system
/// interfaces coming and going are not changes (`NetworkPathSignature`). The initial path is not a change. `changes` is
/// multi-subscriber. `cancel()` (or deinit) stops monitoring and finishes every subscription.
public final class NWPathNetworkChangeMonitor: NetworkChangeMonitoring {
    private let monitor: NWPathMonitor
    private let reporter = PathChangeReporter()

    public init() {
        monitor = NWPathMonitor(prohibitedInterfaceTypes: [.cellular, .loopback])
        let reporter = self.reporter
        monitor.pathUpdateHandler = { path in reporter.report(NetworkPathSignature(path)) }
        monitor.start(queue: DispatchQueue(label: "com.coreysilvia.CameraBridge.path"))
    }

    deinit {
        monitor.cancel()
        reporter.finish()
    }

    public var changes: AsyncStream<Void> {
        reporter.subscribe()
    }

    /// Stops monitoring; current and later subscriptions finish.
    public func cancel() {
        monitor.cancel()
        reporter.finish()
    }
}

/// The parts of an `NWPath` whose change should restart camera ingest and re-advertise: its status, the interfaces and
/// gateways that carry the LAN, and the addresses of the Ethernet and Wi-Fi (`en*`) interfaces.
///
/// A Mac with a VPN client or AirDrop sees interfaces (`utun*`, `awdl*`, `llw*`, `anpi*`, `bridge*`) come and go all day;
/// each one used to restart every camera's stream (several logins to a camera that locks its account after a few). They
/// are left out, and so are gateways that are not on a network one of the `en*` interfaces is on. What stays is what can
/// break a camera or a controller connection: another network, another address, a lost interface.
struct NetworkPathSignature: Equatable, Sendable {
    /// Interfaces that say nothing about the LAN: tunnels, AirDrop/Wi-Fi Direct, Low Latency WLAN, the Apple NPU
    /// interface, bridges (Thunderbolt, virtual machines), loopback.
    static let ignoredInterfacePrefixes = ["utun", "awdl", "llw", "anpi", "bridge", "lo"]

    var status: String
    var interfaces: [String]
    var gateways: [String]
    /// The stable addresses of the `en*` interfaces (`InterfaceAddresses.stable()`), as text, sorted.
    var addresses: [String]

    static func isIgnored(interface name: String) -> Bool {
        ignoredInterfacePrefixes.contains { name.hasPrefix($0) }
    }

    /// `interfaces` are `name:type`; the ignored ones are dropped here, so every way of building a signature agrees.
    init(status: String, interfaces: [String], gateways: [String], addresses: [String] = []) {
        self.status = status
        self.interfaces = interfaces.filter { entry in !Self.isIgnored(interface: String(entry.split(separator: ":", maxSplits: 1).first ?? "")) }
        self.gateways = gateways
        self.addresses = addresses.sorted()
    }

    init(_ path: NWPath, addresses: [InterfaceAddress] = InterfaceAddresses.stable()) {
        let gateways = path.gateways.compactMap { endpoint -> String? in
            // Only gateways on a network an en* interface is on: a VPN's gateway comes and goes with its tunnel.
            let (host, _) = AppleNetworkTransport.ipLiteral(endpoint)
            guard !host.isEmpty, InterfaceAddresses.isOnLink(host, among: addresses) else { return nil }
            return "\(endpoint)"
        }
        self.init(status: "\(path.status)", interfaces: path.availableInterfaces.map { "\($0.name):\($0.type)" }, gateways: gateways,
                  addresses: addresses.map(\.description))
    }
}

/// Suppresses the initial path and repeats of the previous one.
struct NetworkChangeFilter: Sendable {
    private var last: NetworkPathSignature?

    init() {}

    mutating func isChange(_ signature: NetworkPathSignature) -> Bool {
        defer { last = signature }
        guard let last else { return false }
        return last != signature
    }
}

private final class PathChangeReporter: Sendable {
    private let filter = Mutex(NetworkChangeFilter())
    /// A burst of path updates coalesces into one pending element per subscriber.
    private let broadcaster = AsyncBroadcaster<Void>(bufferingNewest: 1)

    func report(_ signature: NetworkPathSignature) {
        if filter.withLock({ $0.isChange(signature) }) { broadcaster.yield(()) }
    }

    /// Already finished after `finish()`.
    func subscribe() -> AsyncStream<Void> {
        broadcaster.subscribe()
    }

    func finish() {
        broadcaster.finish()
    }
}
#endif
