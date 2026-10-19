import BridgeEngine
import Foundation

/// Settings › Network: port checks for the two ports the engine lets the person move besides the webhook's, and this
/// Mac's addresses.
enum NetworkSettings {
    /// A port field on the Network page.
    enum PortField: Equatable {
        /// `BridgeSettings.sensorsBridgePort`: the Sensors Bridge accessory's port.
        case sensorsBridge
        /// `BridgeSettings.basePort`: where the ports of cameras added from now on start (`PortAllocator`).
        case firstCameraPort
    }

    static let portRange: ClosedRange<Int> = 1_024...65_535

    /// The port in `text` when it can be used for `field`, else why not. `cameraPorts`: every port a camera has.
    static func validatePort(_ text: String, for field: PortField, settings: BridgeSettings, cameraPorts: [UInt16]) -> WebhookSettings.PortValidation {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), portRange.contains(value) else {
            return .invalid(String(localized: "Use a port from 1024 to 65535."))
        }
        let port = UInt16(value)
        switch field {
        case .sensorsBridge:
            if port == settings.webhookPort { return .invalid(String(localized: "Port \(String(port)) is used by the webhook.")) }
            if cameraPorts.contains(port) { return .invalid(String(localized: "Port \(String(port)) is used by a camera.")) }
        case .firstCameraPort:
            // Cameras that already have a port keep it; the allocator skips the webhook's and the sensors bridge's.
            break
        }
        return .valid(port)
    }

    /// One of this Mac's addresses.
    struct InterfaceAddress: Equatable, Identifiable {
        var interface: String
        var address: String
        var id: String { "\(interface) \(address)" }
    }

    /// Whether an address is worth showing: IPv4, not loopback or link-local, on a physical (Ethernet or Wi-Fi) interface
    /// rather than a tunnel or a system one (utun, awdl, llw, bridge, …).
    static func isShown(interface: String, address: String) -> Bool {
        guard interface.hasPrefix("en"), interface.dropFirst(2).allSatisfy(\.isNumber), !interface.dropFirst(2).isEmpty else { return false }
        return !address.hasPrefix("127.") && !address.hasPrefix("169.254.") && address != "0.0.0.0"
    }

    /// This Mac's IPv4 addresses on its network interfaces (`getifaddrs`), in interface order. Nothing is sent.
    static func ipv4Addresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let item = InterfaceAddress(interface: name, address: address)
            if isShown(interface: name, address: address), !result.contains(item) { result.append(item) }
        }
        return result
    }
}
