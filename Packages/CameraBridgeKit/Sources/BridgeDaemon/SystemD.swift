import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// systemd's notification protocol without libsystemd: one datagram to the unix socket in `NOTIFY_SOCKET` (`sd_notify(3)`). Under
/// `Type=notify` the service is "started" when it sends `READY=1`, and with `WatchdogSec=` it is restarted when `WATCHDOG=1` stops
/// arriving. Without `NOTIFY_SOCKET` (a shell, a Mac) everything here does nothing.
public enum SystemD {
    /// Sends `message` ("READY=1", "WATCHDOG=1", "STATUS=…", several lines separated by newlines). False when there is no socket or
    /// the datagram could not be sent.
    @discardableResult
    public static func notify(_ message: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let path = environment["NOTIFY_SOCKET"], !path.isEmpty else { return false }
        return send(Array(message.utf8), toSocketAt: path)
    }

    /// How often to say `WATCHDOG=1`: a third of `WATCHDOG_USEC` (systemd advises less than half; Camera Bridge OS asks for a ping at
    /// least every WatchdogSec/2, so a late wake-up still leaves margin), nil when the service has no watchdog.
    public static func watchdogInterval(environment: [String: String] = ProcessInfo.processInfo.environment) -> Duration? {
        guard let text = environment["WATCHDOG_USEC"], let microseconds = Int64(text), microseconds > 0 else { return nil }
        if let pid = environment["WATCHDOG_PID"], let owner = Int32(pid), owner != getpid() { return nil }
        return .microseconds(max(microseconds / 3, 100_000))
    }

    /// Whether this process was started by journald-aware systemd (log lines then carry `<priority>` prefixes).
    public static func logsToJournal(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["JOURNAL_STREAM"] != nil
    }

    private static func send(_ bytes: [UInt8], toSocketAt path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        var name = Array(path.utf8)
        if name.first == UInt8(ascii: "@") { name[0] = 0 }   // an abstract socket
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !name.isEmpty, name.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in name.enumerated() { buffer[index] = byte }
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        #if canImport(Darwin)
        let kind = SOCK_DGRAM
        let flags: Int32 = 0
        #else
        let kind = Int32(SOCK_DGRAM.rawValue)
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        let descriptor = socket(AF_UNIX, kind, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // A path ends with a NUL byte that counts; an abstract name (leading NUL) is exactly its bytes.
        let length = socklen_t((MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2) + name.count + (name.first == 0 ? 0 : 1))
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes, bytes.count, flags, $0, length) }
        }
        return sent == bytes.count
    }
}
