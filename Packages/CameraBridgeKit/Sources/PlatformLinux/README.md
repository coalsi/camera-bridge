# PlatformLinux

Linux implementations of the platform protocols in `BridgeSupport/PlatformServices.swift` (the counterpart of `PlatformApple`).
Every file is wrapped in `#if os(Linux)`, so the module builds empty on macOS. `BridgeEnvironment.linux(dataDirectory:codecs:)`
(BridgeEngine/Environment.swift) wires it together through `LinuxPlatform.services(dataDirectory:)`.

| Protocol | Type | Notes |
|---|---|---|
| `NetworkTransport` | `LinuxNetworkTransport` | Non-blocking POSIX sockets, readiness from Dispatch sources (`SocketDescriptor`). Dual-stack listener (IPv4 only where there is no IPv6), `TCP_NODELAY`, keepalive and `TCP_USER_TIMEOUT` on accepted connections, name lookups off the cooperative pool, every resolved address tried in turn. A closed connection lingers until the peer's FIN so the peer never loses its last bytes to a reset. |
| `ServiceAdvertiser` | `DNSSDServiceAdvertiser` | The dns_sd API of Avahi's compatibility library (`CDNSSD` system library target, package `libavahi-compat-libdnssd-dev`); no dispatch-queue support there, so a read source on `DNSServiceRefSockFD` calls `DNSServiceProcessResult`. |
| `ServiceBrowsing` | `DNSSDServiceBrowser` | `DNSServiceBrowse` then `DNSServiceResolve` for the TXT record. |
| `SecretStore` | `FileSecretStore` | AES-256-GCM per account (`<dir>/secrets/<sha256(account)>.enc`, account name as authenticated data); random key in `<dir>/secrets/master.key` (0600, the file Camera Bridge OS creates at first boot; an older `<dir>/secrets.key` is moved there), never replaced when damaged. |
| `NetworkChangeMonitoring` | `NetlinkNetworkChangeMonitor` | `NETLINK_ROUTE` groups link / IPv4 address / IPv6 address; each settled burst is compared with the last state of the LAN interfaces (`InterfaceAddresses.stable()`: Ethernet and Wi-Fi only, no temporary, tentative, link-local or unique-local IPv6, deprecation flips ignored) plus the default gateway. Polls every 10 s where netlink is refused. |
| `PowerManaging` | `LinuxPowerManager` | No-ops; `hasBattery` reads `/sys/class/power_supply`. |
| `InstanceLocking` | `LinuxInstanceLock` | `flock` on `instance.lock`. |
| `HelperLaunching` | `ProcessHelperLauncher` | `Foundation.Process`; starts the child with an empty signal mask (libdispatch worker threads block all signals, which a child inherits). |
| `MediaCodecs` | `UnavailableMediaCodecs` | Placeholder that throws `MediaCodecError.unsupported`; the ffmpeg-based codecs live in `Codecs/`. |

Tests: `Tests/PlatformLinuxTests`, run by `Tools/linux-test.sh` (a Swift 6.4 container; it grants `CAP_NET_ADMIN` so the netlink test can add
a dummy interface).
