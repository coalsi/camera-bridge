#if os(Linux)
import Foundation
import Glibc

/// An IP address read from a socket address: a bare literal (no port, no zone), the family, and the zone (interface name)
/// of a link-local IPv6 address.
struct IPEndpointAddress: Equatable, Sendable {
    var host: String
    var isIPv6: Bool
    var zone: String?
}

enum SocketAddresses {
    /// The address in `storage`. IPv4-mapped IPv6 addresses are reported as IPv4; nil for other families.
    static func address(of storage: sockaddr_storage) -> IPEndpointAddress? {
        var storage = storage
        return withUnsafeBytes(of: &storage) { raw -> IPEndpointAddress? in
            switch Int32(raw.loadUnaligned(as: sa_family_t.self)) {
            case AF_INET:
                var address = raw.loadUnaligned(as: sockaddr_in.self)
                guard let host = presentation(family: AF_INET, of: &address.sin_addr, capacity: Int(INET_ADDRSTRLEN)) else { return nil }
                return IPEndpointAddress(host: host, isIPv6: false, zone: nil)
            case AF_INET6:
                var address = raw.loadUnaligned(as: sockaddr_in6.self)
                let bytes = withUnsafeBytes(of: &address.sin6_addr) { Array($0) }
                if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                    return IPEndpointAddress(host: bytes[12...].map(String.init).joined(separator: "."), isIPv6: false, zone: nil)
                }
                guard let host = presentation(family: AF_INET6, of: &address.sin6_addr, capacity: Int(INET6_ADDRSTRLEN)) else { return nil }
                return IPEndpointAddress(host: host, isIPv6: true, zone: address.sin6_scope_id == 0 ? nil : interfaceName(index: address.sin6_scope_id))
            default:
                return nil
            }
        }
    }

    /// The port in `storage` (host order), 0 for other families.
    static func port(of storage: sockaddr_storage) -> UInt16 {
        var storage = storage
        return withUnsafeBytes(of: &storage) { raw -> UInt16 in
            switch Int32(raw.loadUnaligned(as: sa_family_t.self)) {
            case AF_INET: UInt16(bigEndian: raw.loadUnaligned(as: sockaddr_in.self).sin_port)
            case AF_INET6: UInt16(bigEndian: raw.loadUnaligned(as: sockaddr_in6.self).sin6_port)
            default: 0
            }
        }
    }

    /// `getsockname` (`peer: false`) or `getpeername` (`peer: true`) of `descriptor`.
    static func name(of descriptor: Int32, peer: Bool) -> sockaddr_storage? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { peer ? getpeername(descriptor, $0, &length) : getsockname(descriptor, $0, &length) }
        }
        return result == 0 ? storage : nil
    }

    /// The interface name of `index` ("eth0"), nil when there is none.
    static func interfaceName(index: UInt32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(index, &name) != nil else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The socket address for a numeric `host` (IPv4 or IPv6; IPv6 may carry `%zone`) and `port`; nil if `host` is not numeric.
    static func numeric(host: String, port: UInt16) -> (storage: sockaddr_storage, length: socklen_t, family: Int32)? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }
        return copy(list)
    }

    /// Every address `host` resolves to (a name lookup, blocking: call it off the cooperative pool), IPv4 first.
    static func resolve(host: String, port: UInt16) -> [(storage: sockaddr_storage, length: socklen_t, family: Int32)] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hints.ai_flags = AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return [] }
        defer { freeaddrinfo(list) }
        var found: [(storage: sockaddr_storage, length: socklen_t, family: Int32)] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            if let item = copy(entry) { found.append(item) }
        }
        return found.filter { $0.family == AF_INET } + found.filter { $0.family != AF_INET }
    }

    private static func copy(_ entry: UnsafeMutablePointer<addrinfo>) -> (storage: sockaddr_storage, length: socklen_t, family: Int32)? {
        guard let address = entry.pointee.ai_addr, entry.pointee.ai_family == AF_INET || entry.pointee.ai_family == AF_INET6 else { return nil }
        var storage = sockaddr_storage()
        let length = min(Int(entry.pointee.ai_addrlen), MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: length)) }
        return (storage, socklen_t(length), entry.pointee.ai_family)
    }

    private static func presentation<T>(family: Int32, of address: inout T, capacity: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: capacity + 1)
        let converted = withUnsafeBytes(of: &address) { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(capacity)) != nil }
        guard converted else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A `sockaddr_storage` holding the IPv4 wildcard / loopback address or the IPv6 wildcard.
    static func local(port: UInt16, family: Int32, loopback: Bool) -> (storage: sockaddr_storage, length: socklen_t) {
        var storage = sockaddr_storage()
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: &address) { Array($0) }) }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: loopback ? UInt32(0x7F00_0001).bigEndian : 0)
        withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: &address) { Array($0) }) }
        return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
#endif
