#if os(macOS)
import Darwin
import Foundation
import Network

/// Finds another socket already holding a TCP port at an address a new listener would share.
///
/// Listeners use address reuse (`SO_REUSEADDR`) so a fixed HAP port rebinds right after a restart while old
/// connections sit in TIME_WAIT. With reuse the kernel refuses only an identical address: an all-interfaces listener
/// would silently share its port with another process's 127.0.0.1-only (or single-address) listener, which keeps that
/// address's connections, and a 127.0.0.1 listener would shadow a wildcard one. So before binding a fixed port, each
/// address the listener serves is bound once with `SO_REUSEADDR` — never listened on, closed at once. `EADDRINUSE`
/// means an unconnected socket (listening or merely bound) holds that exact address; TIME_WAIT and connected sockets
/// never match. An IPv4 wildcard probe also finds dual-stack `[::]` sockets.
enum ListenerPortProbe {
    enum Address: Sendable, Hashable, CustomStringConvertible {
        case ipv4(IPv4Address)
        case ipv6(IPv6Address, scopeID: UInt32 = 0)

        var description: String {
            switch self {
            case .ipv4(let address): "\(address)"
            case .ipv6(let address, let scopeID): scopeID == 0 ? "\(address)" : "\(address)%\(scopeID)"
            }
        }
    }

    /// Addresses to probe for a listener on 127.0.0.1 (`loopbackOnly`) or on every interface, loopback first (so a
    /// port held on loopback is reported without binding any other interface).
    static func addresses(loopbackOnly: Bool) -> [Address] {
        if loopbackOnly { return [.ipv4(.loopback), .ipv4(.any)] }
        var result: [Address] = [.ipv4(.loopback), .ipv6(.loopback), .ipv4(.any), .ipv6(.any)]
        for address in interfaceAddresses() where !result.contains(address) {
            result.append(address)
        }
        return result
    }

    /// The first of `addresses` at which `port` is already held, or nil. Other bind failures (an address that went
    /// away, a link-local address without a usable scope) are not conflicts.
    static func firstConflict(port: UInt16, among addresses: [Address]) -> Address? {
        addresses.first { bindError(port: port, at: $0) == EADDRINUSE }
    }

    /// 0 if a `SO_REUSEADDR` TCP socket can bind `address`:`port`, else the `errno` of the failing call.
    static func bindError(port: UInt16, at address: Address) -> Int32 {
        var enabled: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        switch address {
        case .ipv4(let ip):
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { return errno }
            defer { close(fd) }
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, optionSize) == 0 else { return errno }
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &socketAddress.sin_addr) { $0.copyBytes(from: ip.rawValue.prefix(4)) }
            let result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            return result == 0 ? 0 : errno
        case .ipv6(let ip, let scopeID):
            let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { return errno }
            defer { close(fd) }
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, optionSize) == 0,
                  setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, optionSize) == 0 else { return errno }
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = port.bigEndian
            socketAddress.sin6_scope_id = scopeID
            withUnsafeMutableBytes(of: &socketAddress.sin6_addr) { $0.copyBytes(from: ip.rawValue.prefix(16)) }
            let result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            return result == 0 ? 0 : errno
        }
    }

    /// Every IPv4/IPv6 address configured on this Mac's interfaces (`getifaddrs`). Link-local IPv6 addresses carry
    /// their interface index as `scopeID` (the kernel may embed it in bytes 2–3 instead, KAME style).
    static func interfaceAddresses() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Address] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = entry.pointee.ifa_addr else { continue }
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                let raw = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if let address = IPv4Address(withUnsafeBytes(of: raw) { Data($0) }) { result.append(.ipv4(address)) }
            case AF_INET6:
                let raw = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var bytes = withUnsafeBytes(of: raw.sin6_addr) { [UInt8]($0) }
                var scopeID = raw.sin6_scope_id
                if bytes.count == 16, bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {   // fe80::/10
                    if scopeID == 0 { scopeID = UInt32(bytes[2]) << 8 | UInt32(bytes[3]) }
                    bytes[2] = 0
                    bytes[3] = 0
                }
                if let address = IPv6Address(Data(bytes)) { result.append(.ipv6(address, scopeID: scopeID)) }
            default:
                break
            }
        }
        return result
    }
}
#endif
