#if os(Linux)
import BridgeSupport
import Foundation

/// The Linux platform services, wired together for `BridgeEnvironment.linux(dataDirectory:)`.
public enum LinuxPlatform {
    /// POSIX-socket transport, dns_sd advertiser and browser (all interfaces, through avahi-daemon), encrypted-file secrets in
    /// `dataDirectory`, netlink change monitor, no-op power manager, a `flock` single-instance lock and `Process`-based helpers.
    public static func services(dataDirectory: URL) -> PlatformServices {
        PlatformServices(transport: LinuxNetworkTransport(), advertiser: DNSSDServiceAdvertiser(), secrets: FileSecretStore(directory: dataDirectory),
                         networkChanges: NetlinkNetworkChangeMonitor(), power: LinuxPowerManager(), browser: DNSSDServiceBrowser(),
                         instanceLock: LinuxInstanceLock(), helpers: ProcessHelperLauncher())
    }
}
#endif
