import BridgeSupport
import Foundation

extension AccessoryServer {
    /// Characters of a controller identifier written to the log as they are (controllers use UUID strings).
    private static func isLoggable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_", ".", ":": true
        default: false
        }
    }

    static let maximumLoggedIdentifierLength = 64

    /// A controller identifier as it may appear in the log. Identifiers come from the peer — in pair-verify M3 before any
    /// authentication — so every character outside ASCII letters, digits and `-_.:` becomes `?` (no line breaks or
    /// escape sequences that could forge log lines) and more than 64 characters are cut, noting the original size.
    static func loggable(controllerID: String) -> String {
        guard !controllerID.isEmpty else { return "\"\"" }
        let characters = controllerID.prefix(maximumLoggedIdentifierLength).map { character -> Character in
            character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy(isLoggable) ? character : "?"
        }
        let text = String(characters)
        return controllerID.count > maximumLoggedIdentifierLength ? "\(text)… (\(controllerID.utf8.count) bytes)" : text
    }

    /// Logs a warning that an unauthenticated peer can trigger at will (failed pair-verify, malformed input, pair-setup
    /// while locked out), at most once per `kind` and remote address per minute; the next one says how many were dropped.
    func warnUnauthenticated(_ kind: String, from remoteAddress: String, _ message: @autoclosure () -> String) {
        unauthenticatedWarnings.log(message(), kind: kind, from: remoteAddress, level: .warning, to: log)
    }

    /// The same limit for an info line an unauthenticated peer can cause (connection churn: the cap on unverified
    /// connections, idle unverified connections, pair-setup while another one runs). `remoteAddress` nil: at most once
    /// per minute from any address (for lines every connect can cause).
    func noteUnauthenticated(_ kind: String, from remoteAddress: String?, _ message: @autoclosure () -> String) {
        unauthenticatedWarnings.log(message(), kind: kind, from: remoteAddress, level: .info, to: log)
    }
}

/// Rate limit for log lines unauthenticated peers can cause: per key at most one per `interval`; `admit` returns how many
/// were suppressed since the last one that passed. Remembers at most `capacity` keys (the least recently logged one is
/// forgotten first), so many peer addresses cannot grow it without bound. Package-wide: HDS limits its pre-hello lines
/// with it too.
package struct UnauthenticatedWarningLimiter {
    private struct Entry {
        var logged: ContinuousClock.Instant
        var suppressed: Int
    }

    let interval: Duration
    let capacity: Int
    private var entries: [String: Entry] = [:]

    package init(interval: Duration = .seconds(60), capacity: Int = 256) {
        self.interval = interval
        self.capacity = max(1, capacity)
    }

    /// nil = do not log; otherwise the number of warnings with this key suppressed since the last one logged.
    mutating func admit(_ key: String, at now: ContinuousClock.Instant = .now) -> Int? {
        if let entry = entries[key] {
            if now - entry.logged < interval {
                entries[key]?.suppressed += 1
                return nil
            }
            entries[key] = Entry(logged: now, suppressed: 0)
            return entry.suppressed
        }
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.logged < $1.value.logged })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(logged: now, suppressed: 0)
        return 0
    }

    /// Writes `message` to `log` at `level` unless a line of this `kind` from `remoteAddress` (from any address when nil)
    /// was written within `interval`; the next one written says how many were not.
    package mutating func log(_ message: @autoclosure () -> String, kind: String, from remoteAddress: String?, level: LogLevel, to log: Log) {
        guard let suppressed = admit(remoteAddress.map { "\(kind)|\($0)" } ?? kind) else { return }
        var text = message()
        if suppressed > 0 { text += " (\(suppressed) more like this\(remoteAddress.map { " from \($0)" } ?? "") not logged)" }
        switch level {
        case .debug: log.debug(text)
        case .info: log.info(text)
        case .notice: log.notice(text)
        case .warning: log.warning(text)
        case .error: log.error(text)
        }
    }

    /// Keys currently remembered (tests).
    var trackedKeyCount: Int { entries.count }
}
