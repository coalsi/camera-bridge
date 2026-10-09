#if os(macOS)
import BridgeSupport

/// The macOS platform services, wired together for `BridgeEnvironment.live()`.
public enum ApplePlatform {
    /// Network.framework transport, dns_sd advertiser (all interfaces), login-keychain secrets
    /// (`com.coreysilvia.CameraBridge`), NWPath change monitor, ProcessInfo/IOPM power manager, NWBrowser Bonjour check and a
    /// `flock` single-instance lock.
    public static func services() -> PlatformServices {
        PlatformServices(transport: AppleNetworkTransport(), advertiser: DNSSDServiceAdvertiser(), secrets: KeychainSecretStore(),
                         networkChanges: NWPathNetworkChangeMonitor(), power: ApplePowerManager(), browser: AppleServiceBrowser(),
                         instanceLock: AppleInstanceLock(), helpers: ProcessHelperLauncher())
    }
}
#endif
