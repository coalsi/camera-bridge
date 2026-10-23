import BridgeSupport
import Foundation

/// What the daemon keeps about the secure address (`secure-address.json` in the data directory). No key is in it.
struct SecureAddressState: Codable, Equatable, Sendable {
    /// From the website's `register`; nil until registered.
    var name: String?
    var host: String?
    /// The home address last sent to the website.
    var address: String?
    /// The last timestamp the website was sent (milliseconds): never goes backwards, also after a restart.
    var lastTimestamp: Int64 = 0
    /// Whether `http://camera-bridge.local` sends browsers to the secure address once a certificate is in place. On unless turned off.
    var redirect: Bool = true
    /// Certificate tries since the last success, and when the next may be asked for.
    var attempts: Int = 0
    var nextAttempt: Date?
    /// The website's failures in a row (no answer, not ready, a server error, too many requests) and when to ask it again: optional, so a
    /// state file from before them still reads.
    var websiteFailures: Int?
    var websiteWaitUntil: Date?

    static let fileName = "secure-address.json"

    static func load(from directory: URL) -> SecureAddressState {
        let url = directory.appending(path: fileName, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder.iso.decode(SecureAddressState.self, from: data) else { return SecureAddressState() }
        return state
    }

    func save(to directory: URL) {
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? PrivateFiles.write(data, to: directory.appending(path: Self.fileName, directoryHint: .notDirectory))
    }
}
