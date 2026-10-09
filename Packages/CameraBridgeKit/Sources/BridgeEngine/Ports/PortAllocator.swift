import BridgeSupport
import Foundation

public enum PortAllocationError: Error, Equatable, Sendable {
    /// No usable port within the scan (`scanLimit` ports from `startingAt`, never past 65535).
    case noFreePort(startingAt: UInt16)
}

/// HAP port allocation (integration brief §6: fixed ports from 21100, away from Scrypted's 30000–50000, Homebridge's
/// 51267/52629/8581 and the ephemeral range, with a free-port check at startup).
///
/// - `assignPorts` (pure) gives every camera without a port — or with a duplicate or reserved one —
///   `BridgeSettings.basePort` + the lowest free offset; the result is persisted in `CameraConfiguration.hapPort`, so a
///   camera keeps its port across restarts and other cameras' removal.
/// - `isAvailable` is the free-port check: it connects to 127.0.0.1:`port`, then [::1]:`port` (refused = free). It never
///   binds, because a probe listener is released asynchronously and would make the real bind that follows fail. It
///   cannot tell this process's own listeners from others' (pass them to `resolvePorts` as `listening`) and misses
///   listeners bound only to a LAN address.
/// - `firstAvailablePort` / `resolvePorts` scan upward from a taken port; `bind(from:…)` is the authoritative scan for
///   starting a server (it also catches LAN-only listeners): it retries the next port while the bind itself fails with
///   `.addressInUse`.
public struct PortAllocator: Sendable {
    public static let defaultScanLimit = 100
    /// Lowest port handed out (no privileged ports).
    public static let lowestPort: UInt16 = 1_024

    private let transport: any NetworkTransport
    private let log = Log(category: "Engine")

    public init(transport: any NetworkTransport) {
        self.transport = transport
    }

    /// Ports no camera may use: the sensors bridge's and the webhook's (also while the webhook is off).
    public static func reservedPorts(for settings: BridgeSettings) -> Set<UInt16> {
        [settings.sensorsBridgePort, settings.webhookPort]
    }

    /// Cameras with a unique, unreserved port keep it; the others get the lowest free port from `basePort` (at least
    /// 1024), in list order. When none is left below 65536 the port stays 0 (the server then picks an ephemeral one).
    public static func assignPorts(to cameras: [CameraConfiguration], settings: BridgeSettings) -> [CameraConfiguration] {
        var used = reservedPorts(for: settings)
        var result = cameras
        var needsPort: [Int] = []
        for index in result.indices {
            let port = result[index].hapPort
            if port != 0, !used.contains(port) {
                used.insert(port)
            } else {
                needsPort.append(index)
            }
        }
        var candidate = max(Int(settings.basePort), Int(lowestPort))
        for index in needsPort {
            while candidate <= Int(UInt16.max), used.contains(UInt16(candidate)) { candidate += 1 }
            guard candidate <= Int(UInt16.max) else {
                result[index].hapPort = 0
                Log(category: "Engine", cameraID: result[index].id)
                    .warning("No HAP port left from \(settings.basePort) for \(result[index].name); an ephemeral port is used")
                continue
            }
            result[index].hapPort = UInt16(candidate)
            used.insert(UInt16(candidate))
        }
        return result
    }

    /// Free-port check: false when something accepts connections on 127.0.0.1:`port` or [::1]:`port` (a listener on
    /// loopback or on every interface, IPv4 or IPv6). Refused or unanswered connections count as free, as does port 0.
    public func isAvailable(_ port: UInt16) async -> Bool {
        guard port != 0 else { return true }
        for host in ["127.0.0.1", "::1"] {
            do {
                let connection = try await transport.connect(host: host, port: port, timeout: .seconds(1))
                connection.close()
                return false
            } catch {
                continue
            }
        }
        return true
    }

    /// `preferred` when it is free (`isAvailable`), else the next free port above it that is not in `reserved`,
    /// looking at no more than `scanLimit` ports.
    public func firstAvailablePort(from preferred: UInt16, avoiding reserved: Set<UInt16>, scanLimit: Int = defaultScanLimit) async throws -> UInt16 {
        for port in Self.candidates(from: preferred, avoiding: [], scanLimit: scanLimit) {
            if !reserved.contains(port), await isAvailable(port) { return port }
        }
        throw PortAllocationError.noFreePort(startingAt: preferred)
    }

    /// Assigns missing ports (`assignPorts`), then moves every enabled camera whose port is taken to the next free one
    /// (not another camera's, not reserved). Persist the result.
    ///
    /// `listening`: ports this process's own servers already listen on (running cameras' HAP servers). They are kept
    /// without a check, since the check would find the camera's own server and move it. Without it, call this only
    /// before any camera server starts (at startup).
    public func resolvePorts(for cameras: [CameraConfiguration], settings: BridgeSettings,
                             listening: Set<UInt16> = []) async -> [CameraConfiguration] {
        var result = Self.assignPorts(to: cameras, settings: settings)
        for index in result.indices where result[index].isEnabled && result[index].hapPort != 0 {
            let port = result[index].hapPort
            guard !listening.contains(port) else { continue }
            guard await !isAvailable(port) else { continue }
            let others = Set(result.indices.filter { $0 != index }.map { result[$0].hapPort })
            do {
                let moved = try await firstAvailablePort(from: port, avoiding: others.union(Self.reservedPorts(for: settings)))
                Log(category: "Engine", cameraID: result[index].id).notice("HAP port \(port) of \(result[index].name) is in use; using \(moved)")
                result[index].hapPort = moved
            } catch {
                log.warning("HAP port \(port) of \(result[index].name) is in use and no free port follows it")
            }
        }
        return result
    }

    /// Calls `attempt` with `preferred` and, while it throws `TransportError.addressInUse`, with each following port not in
    /// `reserved` (at most `scanLimit` ports). Returns the port that worked and `attempt`'s result; other errors are
    /// rethrown at once. Port 0 is tried once (ephemeral).
    public static func bind<T>(from preferred: UInt16, avoiding reserved: Set<UInt16>, scanLimit: Int = defaultScanLimit,
                               _ attempt: (UInt16) async throws -> T) async throws -> (port: UInt16, value: T) {
        for port in candidates(from: preferred, avoiding: reserved, scanLimit: scanLimit) {
            do {
                return (port, try await attempt(port))
            } catch TransportError.addressInUse {
                continue
            }
        }
        throw PortAllocationError.noFreePort(startingAt: preferred)
    }

    /// `preferred`, `preferred + 1`, … (at most `scanLimit` ports, never past 65535) without `reserved`.
    private static func candidates(from preferred: UInt16, avoiding reserved: Set<UInt16>, scanLimit: Int) -> [UInt16] {
        guard preferred != 0 else { return [0] }
        let last = min(Int(preferred) + max(0, scanLimit) - 1, Int(UInt16.max))
        guard last >= Int(preferred) else { return [] }
        return (Int(preferred)...last).map { UInt16($0) }.filter { !reserved.contains($0) }
    }
}
