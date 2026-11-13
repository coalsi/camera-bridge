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

Beside the protocols: `KernelClock.synchronization()` (public; `KernelClock.Synchronization`: `synchronized`, `unsynchronized`, `unknown(errno:)`)
reads the kernel's clock state with `adjtimex` and no mode bits (`CTimex` system library target: `<sys/timex.h>`, which Swift's Glibc module leaves
out). Synchronized is neither `TIME_ERROR` nor `STA_UNSYNC`, which chrony with `rtcsync` clears. The daemon hands it to the NVR's age rule
(`ArchivePlatformPolicy.isClockSynchronized`); a call a sandbox refuses is `unknown`, which the age rule treats as not synchronized.

Tests: `Tests/PlatformLinuxTests`, run by `Tools/linux-test.sh` (a Swift 6.4 container; it grants `CAP_NET_ADMIN` so the netlink test can add
a dummy interface).

## Additions beyond the contract

`KernelClock`, `KernelClock.synchronization`, `KernelClock.Synchronization` (2026-11-11, docs/CONTRACT_CHANGES.md).

Away from home (2026-11-12, docs/CONTRACT_CHANGES.md; BridgeWeb README, "Away from home"): `GlobalIPv6Address` (a global unicast IPv6 address as the kernel holds it, with its preferred lifetime and whether it is temporary or deprecated), `InterfaceAddresses.globalIPv6` (the global addresses of the interface with the IPv6 default route, in address order: temporary and deprecated ones are listed, marked, and the caller chooses the stable one) and `InterfaceAddresses.ipv6DefaultRouteInterface` (the interface of the lowest-metric IPv6 default route on a LAN interface, read from `/proc/self/net/ipv6_route`; a tunnel such as `wg-away` is never one). Internal: `KernelAddress.preferredLifetime` (the address attribute `IFA_CACHEINFO`'s `ifa_prefered`, in seconds; nil means forever).
