import Foundation

/// Test-only helpers shared by test targets and `cbctl` (never linked by the app).
/// Wave 1 adds `RTSPTestServer` (W1-5); Wave 2 adds `HAPTestController`, `HDSTestClient` and `SRTPTestReceiver` (W2-2).
public enum TestSupportModule {
    /// Creates a unique temporary directory for a test and returns its URL (a `TemporaryDirectory`'s).
    public static func makeTemporaryDirectory(prefix: String = "CameraBridgeTests") throws -> URL {
        try TemporaryDirectory(prefix: prefix).url
    }
}

/// A fresh, uniquely named directory under the system temporary directory, removed by `remove()`. The one copy for every
/// test target (PortabilityTests' SharedTestHelperTests keeps it from being redefined in Tests/).
public struct TemporaryDirectory: Sendable {
    public let url: URL

    /// Creates `<temporary directory>/<prefix>-<UUID>`.
    public init(prefix: String = "CameraBridgeTests") throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Removes the directory and everything in it (no error if it is already gone).
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// The URL of the file `name` in the directory (not created).
    public func file(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }

    /// The names of the directory's entries, sorted (empty when it cannot be read).
    public func contents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).sorted()
    }
}
