#if os(Linux)
import Foundation
import Glibc

/// An address as the kernel lists it (`RTM_NEWADDR`).
struct KernelAddress: Equatable, Sendable {
    var interfaceIndex: UInt32
    /// `AF_INET` or `AF_INET6`.
    var family: Int32
    var prefixLength: Int
    /// `IFA_F_*` (the 32-bit `IFA_FLAGS` when the kernel sends it, else the 8-bit header field).
    var flags: UInt32
    /// 4 or 16 bytes.
    var bytes: [UInt8]

    static let temporary: UInt32 = 0x01        // IFA_F_TEMPORARY: a privacy address; rotates daily
    static let duplicateFailed: UInt32 = 0x08  // IFA_F_DADFAILED
    static let deprecated: UInt32 = 0x20       // IFA_F_DEPRECATED: its preferred lifetime ran out (and flips back when renewed)
    static let tentative: UInt32 = 0x40        // IFA_F_TENTATIVE: duplicate address detection is still running
}

/// The few `NETLINK_ROUTE` structures this module needs, declared here: `linux/netlink.h` and `linux/rtnetlink.h` are not part of
/// the Glibc module. Layouts and values are the kernel's stable ABI.
enum Netlink {
    static let routeProtocol: Int32 = 0           // NETLINK_ROUTE
    static let groupLink: UInt32 = 0x1            // RTMGRP_LINK
    static let groupIPv4Address: UInt32 = 0x10    // RTMGRP_IPV4_IFADDR
    static let groupIPv6Address: UInt32 = 0x100   // RTMGRP_IPV6_IFADDR

    private static let getAddress: UInt16 = 22    // RTM_GETADDR
    private static let newAddress: UInt16 = 20    // RTM_NEWADDR
    private static let requestFlag: UInt16 = 0x1  // NLM_F_REQUEST
    private static let dumpFlag: UInt16 = 0x300   // NLM_F_DUMP
    private static let doneMessage: UInt16 = 3    // NLMSG_DONE
    private static let errorMessage: UInt16 = 2   // NLMSG_ERROR
    private static let headerSize = 16            // struct nlmsghdr
    private static let addressMessageSize = 8     // struct ifaddrmsg
    private static let attributeHeaderSize = 4    // struct rtattr
    private static let attributeAddress: UInt16 = 1   // IFA_ADDRESS
    private static let attributeLocal: UInt16 = 2     // IFA_LOCAL
    private static let attributeFlags: UInt16 = 8     // IFA_FLAGS

    /// A non-blocking, close-on-exec `NETLINK_ROUTE` socket bound to the multicast `groups`; nil when the kernel (or a sandbox)
    /// does not allow it.
    static func openSocket(groups: UInt32) -> Int32? {
        let descriptor = Glibc.socket(AF_NETLINK, Int32(SOCK_RAW.rawValue) | Int32(SOCK_NONBLOCK.rawValue) | Int32(SOCK_CLOEXEC.rawValue), routeProtocol)
        guard descriptor >= 0 else { return nil }
        // struct sockaddr_nl { u16 family; u16 pad; u32 pid; u32 groups; }
        var address = [UInt8](repeating: 0, count: 12)
        address.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: sa_family_t(AF_NETLINK), toByteOffset: 0, as: sa_family_t.self)
            raw.storeBytes(of: groups, toByteOffset: 8, as: UInt32.self)
        }
        let bound = address.withUnsafeBytes { raw in
            Glibc.bind(descriptor, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        guard bound == 0 else {
            _ = Glibc.close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Reads and drops what is queued on `descriptor`. Returns false when the kernel dropped messages (`ENOBUFS`): the caller must
    /// assume anything changed.
    static func drain(_ descriptor: Int32) -> Bool {
        var intact = true
        withUnsafeTemporaryAllocation(byteCount: 8192, alignment: 8) { buffer in
            for _ in 0..<256 {
                let count = recv(descriptor, buffer.baseAddress, buffer.count, 0)
                if count > 0 { continue }
                if count < 0, errno == ENOBUFS { intact = false; continue }
                if count < 0, errno == EINTR { continue }
                return
            }
        }
        return intact
    }

    /// Every address of every interface (`RTM_GETADDR` dump). Empty when the dump fails or takes longer than two seconds.
    static func dumpAddresses() -> [KernelAddress] {
        let descriptor = Glibc.socket(AF_NETLINK, Int32(SOCK_RAW.rawValue) | Int32(SOCK_CLOEXEC.rawValue), routeProtocol)
        guard descriptor >= 0 else { return [] }
        defer { _ = Glibc.close(descriptor) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // nlmsghdr { u32 len; u16 type; u16 flags; u32 seq; u32 pid; } + ifaddrmsg { u8 family, prefixlen, flags, scope; u32 index }
        var request = [UInt8](repeating: 0, count: headerSize + addressMessageSize)
        request.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(raw.count), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: getAddress, toByteOffset: 4, as: UInt16.self)
            raw.storeBytes(of: requestFlag | dumpFlag, toByteOffset: 6, as: UInt16.self)
            raw.storeBytes(of: UInt32(1), toByteOffset: 8, as: UInt32.self)
        }
        let sent = request.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return [] }

        var found: [KernelAddress] = []
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        for _ in 0..<64 {   // bounded: a dump is a handful of datagrams
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return found }
            if parse(buffer[0..<count], into: &found) { return found }
        }
        return found
    }

    /// Appends the addresses in one datagram of messages; true once the dump is complete (or failed).
    private static func parse(_ datagram: ArraySlice<UInt8>, into found: inout [KernelAddress]) -> Bool {
        let bytes = Array(datagram)
        var offset = 0
        while offset + headerSize <= bytes.count {
            let length = Int(load(UInt32.self, bytes, offset))
            let type = load(UInt16.self, bytes, offset + 4)
            guard length >= headerSize, offset + length <= bytes.count else { return true }
            if type == doneMessage || type == errorMessage { return true }
            if type == newAddress, length >= headerSize + addressMessageSize {
                let body = offset + headerSize
                let family = Int32(bytes[body])
                var address = KernelAddress(interfaceIndex: load(UInt32.self, bytes, body + 4), family: family, prefixLength: Int(bytes[body + 1]),
                                            flags: UInt32(bytes[body + 2]), bytes: [])
                var local: [UInt8]?
                var attribute = body + addressMessageSize
                while attribute + attributeHeaderSize <= offset + length {
                    let size = Int(load(UInt16.self, bytes, attribute))
                    let kind = load(UInt16.self, bytes, attribute + 2)
                    guard size >= attributeHeaderSize, attribute + size <= offset + length else { break }
                    let payload = Array(bytes[(attribute + attributeHeaderSize)..<(attribute + size)])
                    switch kind {
                    case attributeAddress: address.bytes = payload
                    case attributeLocal: local = payload
                    case attributeFlags where payload.count == 4: address.flags = load(UInt32.self, payload, 0)
                    default: break
                    }
                    attribute += (size + 3) & ~3
                }
                // On a point-to-point link IFA_LOCAL is the address of this end and IFA_ADDRESS the peer's.
                if let local { address.bytes = local }
                if (family == AF_INET && address.bytes.count == 4) || (family == AF_INET6 && address.bytes.count == 16) { found.append(address) }
            }
            offset += (length + 3) & ~3
        }
        return false
    }

    private static func load<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], _ offset: Int) -> T {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
#endif
