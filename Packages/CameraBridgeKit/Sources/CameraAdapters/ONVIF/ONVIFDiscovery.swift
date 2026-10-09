import BridgeSupport
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// WS-Discovery (ONVIF Core §7.3) over BSD UDP multicast (portable): a `Probe` for `dn:NetworkVideoTransmitter` sent to
/// 239.255.255.250:3702 on every IPv4 multicast interface (joining the group on each), then `ProbeMatches` collected
/// until the timeout.
public enum ONVIFDiscovery {
    static let multicastGroup = "239.255.255.250"
    static let port: UInt16 = 3702
    private static let log = Log(category: "discovery")

    public static func discover(timeout: Duration = .seconds(3)) async -> [DiscoveredCamera] {
        let probe = probeMessage(messageID: UUID().uuidString.lowercased())
        let datagrams: [(data: Data, sender: String?)] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: MulticastProbe.run(probe: probe, group: multicastGroup, port: port, timeout: timeout))
            }
        }
        let cameras = merge(datagrams.flatMap { parseProbeMatches($0.data, sender: $0.sender) })
        log.info("WS-Discovery found \(cameras.count) device(s)")
        return cameras
    }

    /// A SOAP 1.2 WS-Discovery Probe (WS-Addressing 2004/08, as ONVIF devices expect).
    static func probeMessage(messageID: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:dn="http://www.onvif.org/ver10/network/wsdl">\
        <s:Header>\
        <a:Action s:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>\
        <a:MessageID>uuid:\(XMLTree.escape(messageID))</a:MessageID>\
        <a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>\
        <a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>\
        </s:Header>\
        <s:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></s:Body>\
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    /// Parses a `ProbeMatches` datagram. The host is the first IPv4 XAddr host (else the first XAddr, else `sender`).
    static func parseProbeMatches(_ data: Data, sender: String?) -> [DiscoveredCamera] {
        guard let tree = try? XMLTree.parse(data) else { return [] }
        return tree.descendants("ProbeMatch").compactMap { match in
            let xAddrs = (match.child("XAddrs")?.text ?? "").split(whereSeparator: \.isWhitespace).compactMap { token -> URL? in
                guard let url = URL(string: String(token)), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                      url.host != nil else { return nil }
                return url
            }
            let scopes = (match.child("Scopes")?.text ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            func scope(_ prefix: String) -> String? {
                guard let value = scopes.first(where: { $0.lowercased().hasPrefix(prefix) })?.dropFirst(prefix.count) else { return nil }
                let text = String(value).replacingOccurrences(of: "+", with: " ")
                let decoded = text.removingPercentEncoding ?? text
                return decoded.isEmpty ? nil : decoded
            }
            let hosts = xAddrs.compactMap { $0.host(percentEncoded: false) }
            guard let host = hosts.first(where: { !$0.contains(":") }) ?? hosts.first ?? sender else { return nil }
            return DiscoveredCamera(host: host, name: scope("onvif://www.onvif.org/name/"), hardware: scope("onvif://www.onvif.org/hardware/"),
                                    xAddrs: xAddrs)
        }
    }

    /// One entry per host (first seen order), XAddrs merged.
    static func merge(_ cameras: [DiscoveredCamera]) -> [DiscoveredCamera] {
        var order: [String] = []
        var byHost: [String: DiscoveredCamera] = [:]
        for camera in cameras {
            if var existing = byHost[camera.host] {
                existing.name = existing.name ?? camera.name
                existing.hardware = existing.hardware ?? camera.hardware
                for url in camera.xAddrs where !existing.xAddrs.contains(url) { existing.xAddrs.append(url) }
                byHost[camera.host] = existing
            } else {
                order.append(camera.host)
                byHost[camera.host] = camera
            }
        }
        return order.compactMap { byHost[$0] }
    }
}

/// Blocking BSD-socket multicast probe (run off the cooperative pool).
enum MulticastProbe {
    private static let log = Log(category: "discovery")

    static func run(probe: Data, group: String, port: UInt16, timeout: Duration) -> [(data: Data, sender: String?)] {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #else
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard fd >= 0 else {
            log.warning("WS-Discovery: socket() failed (errno \(errno))")
            return []
        }
        defer { close(fd) }

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: 0)
        #if canImport(Darwin)
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            log.warning("WS-Discovery: bind() failed (errno \(errno))")
            return []
        }

        var ttl: UInt8 = 4
        _ = setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var groupAddress = in_addr()
        guard inet_pton(AF_INET, group, &groupAddress) == 1 else { return [] }
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr = groupAddress
        #if canImport(Darwin)
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        func send() {
            let sent = probe.withUnsafeBytes { buffer in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 { log.debug("WS-Discovery: sendto failed (errno \(errno))") }
        }

        let interfaces = ipv4MulticastInterfaces()
        for interface in interfaces {
            var membership = ip_mreq(imr_multiaddr: groupAddress, imr_interface: interface)
            _ = setsockopt(fd, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size))
            var outgoing = interface
            _ = setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size))
            send()
        }
        if interfaces.isEmpty { send() }

        var results: [(data: Data, sender: String?)] = []
        let deadline = ContinuousClock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while ContinuousClock.now < deadline {
            let remaining = deadline - ContinuousClock.now
            // Clamp before converting: a long timeout must not overflow the Int32 poll interval.
            let remainingSeconds = max(0, min(remaining.components.seconds, 1))
            let milliseconds = Int32(max(1, min(200, remainingSeconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, milliseconds) > 0 else { continue }
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &fromLength) }
                }
            }
            guard count > 0 else { continue }
            results.append((Data(buffer[0..<count]), ipString(from.sin_addr)))
            if results.count > 256 { break }
        }
        return results
    }

    /// IPv4 addresses of interfaces that are up, multicast-capable and not loopback.
    static func ipv4MulticastInterfaces() -> [in_addr] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [in_addr] = []
        var seen: Set<UInt32> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = UInt32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_MULTICAST) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if seen.insert(ipv4.s_addr).inserted { result.append(ipv4) }
        }
        return result
    }

    static func ipString(_ address: in_addr) -> String? {
        var address = address
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return nil }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
