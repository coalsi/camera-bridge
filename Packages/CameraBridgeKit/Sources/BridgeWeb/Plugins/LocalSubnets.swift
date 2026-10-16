import Foundation

/// The bridge's own private IPv4 networks, for a plugin that needs to find a device by its MAC address: touching every host of a subnet
/// makes the kernel learn their MAC addresses (the neighbour table, `NeighborTable`). The addresses come from the engine
/// (`BridgeBackend.localIPv4Addresses()`).
enum LocalSubnets {
    /// The setup hotspot's own network (Camera Bridge OS without a network): never swept.
    static let hotspotPrefix = "10.42.0."

    /// The private ones of `addresses` (not loopback, not link-local, not the setup hotspot).
    static func privateAddresses(_ addresses: [String]) -> [String] {
        Array(Set(addresses.filter { isPrivate($0) && !$0.hasPrefix(hotspotPrefix) })).sorted()
    }
    /// 10/8, 172.16/12, 192.168/16.
    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }

    /// Every other host of the /24 around each of `addresses` (a bridge on a larger network sweeps only its own /24: enough for a home, and
    /// bounded).
    static func sweepTargets(addresses: [String]) -> [String] {
        var hosts: [String] = []
        for address in privateAddresses(addresses) {
            let parts = address.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            for last in 1...254 where "\(prefix).\(last)" != address { hosts.append("\(prefix).\(last)") }
        }
        return Array(Set(hosts)).sorted()
    }
}
