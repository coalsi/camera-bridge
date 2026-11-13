#if os(Linux)
import BridgeSupport
import BridgeWeb
import Dispatch
import Foundation
import PlatformLinux

/// `AwayNetwork` over netlink and `/proc` on Camera Bridge OS.
struct LinuxAwayNetwork: AwayNetwork {
    private let monitor: any NetworkChangeMonitoring

    init(monitor: any NetworkChangeMonitoring) {
        self.monitor = monitor
    }

    func globalIPv6() async -> [AwayAddress] {
        await offThePool {
            InterfaceAddresses.globalIPv6().map {
                AwayAddress(address: $0.address, prefixLength: $0.prefixLength, preferredLifetime: $0.preferredLifetime,
                            isTemporary: $0.isTemporary, isDeprecated: $0.isDeprecated)
            }
        }
    }

    func ownPrefixes() async -> [String] {
        await offThePool { InterfaceAddresses.stable().map { "\($0.address)/\($0.prefixLength)" } }
    }

    /// The platform's monitor is multi-subscriber and fires when a LAN address comes or goes (a new prefix too), so the stream stays free of
    /// addresses and the service reads them itself after each element.
    var changes: AsyncStream<Void> { monitor.changes }

    /// A netlink dump can wait two seconds, which must not hold one of Swift's few cooperative threads.
    private func offThePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}
#endif
