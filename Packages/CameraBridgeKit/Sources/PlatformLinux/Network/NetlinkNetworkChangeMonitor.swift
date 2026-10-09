#if os(Linux)
import BridgeSupport
import Dispatch
import Foundation
import Glibc
import Synchronization

/// `NetworkChangeMonitoring` over a `NETLINK_ROUTE` socket (`RTMGRP_LINK`, `RTMGRP_IPV4_IFADDR`, `RTMGRP_IPV6_IFADDR`). The
/// kernel's messages only say that something happened; each burst is followed (250 ms later, once it has settled) by a look at
/// what the LAN interfaces hold (`NetworkSignature`), and only a different answer is a change. So the noise that flips
/// constantly is no change: temporary IPv6 addresses, deprecation flips, unique-local prefixes announced for Thread, container
/// and tunnel interfaces coming and going. The initial state is not a change. `changes` is multi-subscriber. `cancel()` (or
/// deinit) stops monitoring and finishes every subscription.
///
/// Where the kernel does not offer a netlink socket (a restrictive sandbox) the same look is taken every 10 seconds instead.
public final class NetlinkNetworkChangeMonitor: NetworkChangeMonitoring {
    /// How long a burst of kernel messages has to be quiet before the interfaces are looked at.
    static let settleDelay: Duration = .milliseconds(250)
    static let pollInterval: Duration = .seconds(10)

    private let reporter = ChangeReporter()
    private let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.netlink")
    private let watcher = Mutex<SourceBox?>(nil)

    /// `snapshot` reads the state to compare (tests replace it).
    public convenience init() {
        self.init(snapshot: { NetworkSignature.current() })
    }

    init(snapshot: @escaping @Sendable () -> NetworkSignature) {
        reporter.report(snapshot())   // the initial state
        let reporter = self.reporter
        let queue = self.queue
        let pending = Mutex(false)
        let evaluate: @Sendable () -> Void = {
            pending.withLock { $0 = false }
            reporter.report(snapshot())
        }
        let schedule: @Sendable () -> Void = {
            guard pending.withLock({ state in defer { state = true }; return !state }) else { return }
            queue.asyncAfter(deadline: .now() + SocketDescriptor.dispatchInterval(Self.settleDelay), execute: evaluate)
        }
        if let descriptor = Netlink.openSocket(groups: Netlink.groupLink | Netlink.groupIPv4Address | Netlink.groupIPv6Address) {
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler {
                _ = Netlink.drain(descriptor)   // (after an overflow the look at the interfaces below covers whatever was lost)
                schedule()
            }
            source.setCancelHandler { _ = Glibc.close(descriptor) }
            source.resume()
            watcher.withLock { $0 = SourceBox(source) }
        } else {
            Log(category: "network").warning("No netlink socket; checking the network every \(Self.pollInterval) instead")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = SocketDescriptor.dispatchInterval(Self.pollInterval)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { reporter.report(snapshot()) }
            timer.resume()
            watcher.withLock { $0 = SourceBox(timer) }
        }
    }

    deinit {
        cancel()
    }

    public var changes: AsyncStream<Void> {
        reporter.subscribe()
    }

    /// Stops monitoring; current and later subscriptions finish.
    public func cancel() {
        watcher.withLock { box in
            box?.cancel()
            box = nil
        }
        reporter.finish()
    }
}

/// The parts of the network state whose change should restart camera ingest and re-advertise: the addresses of the LAN
/// interfaces (`InterfaceAddresses.stable()`) and the IPv4 default gateway.
struct NetworkSignature: Equatable, Sendable {
    /// `InterfaceAddress.description`s, sorted.
    var addresses: [String]
    var gateway: String?

    init(addresses: [String], gateway: String?) {
        self.addresses = addresses.sorted()
        self.gateway = gateway
    }

    static func current() -> NetworkSignature {
        let addresses = InterfaceAddresses.stable()
        let gateway = InterfaceAddresses.defaultGateway()
        // A gateway that is not on a network one of the LAN interfaces is on says nothing about the LAN.
        return NetworkSignature(addresses: addresses.map(\.description),
                                gateway: gateway.flatMap { InterfaceAddresses.isOnLink($0, among: addresses) ? $0 : nil })
    }
}

/// Suppresses the initial state and repeats of the previous one.
struct NetworkChangeFilter: Sendable {
    private var last: NetworkSignature?

    init() {}

    mutating func isChange(_ signature: NetworkSignature) -> Bool {
        defer { last = signature }
        guard let last else { return false }
        return last != signature
    }
}

private final class ChangeReporter: Sendable {
    private let filter = Mutex(NetworkChangeFilter())
    /// A burst of updates coalesces into one pending element per subscriber.
    private let broadcaster = AsyncBroadcaster<Void>(bufferingNewest: 1)

    func report(_ signature: NetworkSignature) {
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
