import Foundation
import Testing

// The test targets' lock-protected value (`Box`), polling wait (`eventually`), in-memory transport (`FakeByteQueue`,
// `FakeTCPConnection`, `FakeTCPListener`, `FakeNetworkTransport`) and temporary directory (`TemporaryDirectory`) live
// once, in TestSupport. Copies in each target drifted apart (sync vs async and `@Sendable` conditions, 5/10/20 ms polls,
// a missing default timeout; HDSTests' transport gained cancellable receives and scripted bind failures HAPCameraTests'
// copy lacked, which alone had stallable sends), so they are not redefined in Tests/. Purpose-built transports with
// other behaviour (refusing, stalling, flaky, scripted connects) stay in their targets under other names. Pure text
// scan; this file (which quotes the old forms) is skipped.
//
// Exempt: Tests/BridgeSupportTests keeps private copies, so the lowest module's tests do not depend on TestSupport
// (which pulls in HAP, HDS, RTP, RTSP and FMP4).

private let thisFile = URL(fileURLWithPath: #filePath).standardizedFileURL
private let exemptTestDirectories = ["Tests/BridgeSupportTests/"]

/// A top-level function taking a `() -> Bool` condition and returning `async -> Bool`: a copy of `eventually`.
private let pollerPattern =
    #"^(?:(?:public|internal|fileprivate|private) )?func (\w+)(?:<[^>]*>)?\([^{]*?-> Bool\)\s*async\s*(?:throws\s*)?->\s*Bool\b"#
/// A generic class whose first stored property is a `Mutex` or `NSLock`: a copy of `Box`.
private let lockBoxPattern = #"^(?:(?:public|internal|fileprivate|private) )?final class (\w+)<\w+(?:: Sendable)?>: (?:@unchecked )?Sendable \{\n"#
    + #"(?:[ \t]*(?://.*)?\n)*[ \t]*(?:(?:public|private) )?let \w+(?::\s*Mutex<|\s*=\s*Mutex[<(]|\s*=\s*NSLock\(\))"#
/// One of the in-memory transport fakes, by name.
private let fakeTransportPattern =
    #"^(?:(?:public|internal|fileprivate|private) )?final class (Fake(?:ByteQueue|TCPConnection|TCPListener|NetworkTransport))\b"#
/// A connection type that hands out two connected in-memory ends: a renamed copy of `FakeTCPConnection`.
private let connectionPairPattern = #"static func pair\([^)]*\)\s*->\s*\(client: (\w+), server: \w+\)"#
/// A type whose first stored property is `url: URL`, set from `FileManager.default.temporaryDirectory` before the type's
/// first closing brace: a copy of `TemporaryDirectory`.
private let temporaryDirectoryTypePattern = #"^(?:(?:public|internal|fileprivate|private) )?(?:struct|final class|class) (\w+)[^{\n]*\{\n"#
    + #"(?:[ \t]*(?://.*)?\n)*[ \t]*(?:public )?let url: URL\n[^}]*?FileManager\.default\.temporaryDirectory"#
/// A throwing function returning a URL that creates a directory under `FileManager.default.temporaryDirectory`: a copy
/// of `TestSupportModule.makeTemporaryDirectory(prefix:)`.
private let temporaryDirectoryFunctionPattern =
    #"func (\w+)\([^)]*\)\s*throws\s*->\s*URL\s*\{[^}]*?FileManager\.default\.temporaryDirectory[^}]*?createDirectory"#

/// `path:line: name` for every match of `pattern` (the name is its first capture).
private func definitions(_ pattern: String, in files: [(path: String, text: String)]) throws -> [String] {
    let regex = try Regex(pattern).anchorsMatchLineEndings()
    return files.flatMap { file in
        file.text.matches(of: regex).map { match in
            let line = file.text[..<match.range.lowerBound].count { $0 == "\n" } + 1
            let name = match.output[1].substring.map(String.init) ?? "?"
            return "\(file.path):\(line): \(name)"
        }
    }
}

private func swiftSources(in directory: String) -> [(path: String, text: String)] {
    swiftFiles(under: packageDirectory.appending(path: directory, directoryHint: .isDirectory))
        .filter { $0.standardizedFileURL != thisFile }
        .compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let path = String(url.standardizedFileURL.path.dropFirst(packageDirectory.standardizedFileURL.path.count))
            return (path.hasPrefix("/") ? String(path.dropFirst()) : path, text)
        }
}

@Suite struct SharedTestHelperTests {
    private let tests = swiftSources(in: "Tests").filter { file in !exemptTestDirectories.contains { file.path.hasPrefix($0) } }
    private let testSupport = swiftSources(in: "Sources/TestSupport")

    @Test func scannerSeesTheTestTargets() {
        #expect(tests.count > 50)
        #expect(tests.contains { $0.path.hasPrefix("Tests/HAPTests/") })
        #expect(!tests.contains { $0.path.hasSuffix("SharedTestHelperTests.swift") })
    }

    @Test func testSupportDefinesBoxAndEventuallyOnce() throws {
        #expect(try definitions(pollerPattern, in: testSupport).map { $0.split(separator: " ").last.map(String.init) } == ["eventually"])
        #expect(try definitions(lockBoxPattern, in: testSupport).map { $0.split(separator: " ").last.map(String.init) } == ["Box"])
    }

    @Test func testSupportDefinesTheFakeTransportAndTemporaryDirectoryOnce() throws {
        let names = { (pattern: String) in try definitions(pattern, in: testSupport).map { $0.split(separator: " ").last.map(String.init) ?? "" } }
        #expect(try names(fakeTransportPattern).sorted() == ["FakeByteQueue", "FakeNetworkTransport", "FakeTCPConnection", "FakeTCPListener"])
        #expect(try names(connectionPairPattern) == ["FakeTCPConnection"])
        #expect(try names(temporaryDirectoryTypePattern) == ["TemporaryDirectory"])
        // `TestSupportModule.makeTemporaryDirectory(prefix:)` is built on `TemporaryDirectory`, not a second copy.
        #expect(try names(temporaryDirectoryFunctionPattern) == [])
    }

    @Test func testTargetsDoNotRedefineThem() throws {
        let pollers = try definitions(pollerPattern, in: tests)
        #expect(pollers.isEmpty, "polling helper redefined; use TestSupport's `eventually`:\n\(pollers.joined(separator: "\n"))")
        let boxes = try definitions(lockBoxPattern, in: tests)
        #expect(boxes.isEmpty, "lock-protected box redefined; use TestSupport's `Box`:\n\(boxes.joined(separator: "\n"))")
        let fakes = try definitions(fakeTransportPattern, in: tests) + definitions(connectionPairPattern, in: tests)
        #expect(fakes.isEmpty,
                "in-memory transport redefined; use TestSupport's `FakeNetworkTransport`:\n\(fakes.joined(separator: "\n"))")
        let directories = try definitions(temporaryDirectoryTypePattern, in: tests) + definitions(temporaryDirectoryFunctionPattern, in: tests)
        #expect(directories.isEmpty,
                "temporary-directory helper redefined; use TestSupport's `TemporaryDirectory`:\n\(directories.joined(separator: "\n"))")
    }

    /// The detectors against every form the copies took, and against look-alikes that are not copies.
    @Test func detectorsFindTheOldCopies() throws {
        let copies = """
        func waitUntil(timeout: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
        }
        private func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
        }
        func pollUntil(_ timeout: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
                       _ condition: () async -> Bool) async -> Bool {
        }
        final class Box<Value: Sendable>: Sendable {
            private let storage: Mutex<Value>
        }
        private final class Box<Value: Sendable>: Sendable {
            let value: Mutex<Value>
        }
        final class ValueBox<T: Sendable>: Sendable {
            private let value = Mutex<T?>(nil)
        }
        /// Minimal lock-protected box.
        final class SendableBox<Value: Sendable>: @unchecked Sendable {
            private let lock = NSLock()
        }
        """
        let lookAlikes = """
        final class Recorder<Element: Sendable>: Sendable {
            private let storage = Box<[Element]>([])
        }
        private final class CollectorBox: Sendable {
            private let state = Mutex(Collected())
        }
        func value<T: Sendable>(of task: Task<T, Never>, within timeout: Duration = .seconds(5)) async -> T? {
        }
            func waitForTXT(timeout: Duration = .seconds(5), _ condition: ([String: String]) -> Bool) async -> Bool {
            }
        """
        let names = { (pattern: String, text: String) in
            try definitions(pattern, in: [("t", text)]).map { $0.split(separator: " ").last.map(String.init) ?? "" }
        }
        #expect(try names(pollerPattern, copies) == ["waitUntil", "eventually", "pollUntil"])
        #expect(try names(lockBoxPattern, copies) == ["Box", "Box", "ValueBox", "SendableBox"])
        #expect(try names(pollerPattern, lookAlikes) == [])
        #expect(try names(lockBoxPattern, lookAlikes) == [])
    }

    /// The transport and temporary-directory detectors against the forms the copies took, and against the purpose-built
    /// fakes and inline temporary paths the test targets keep.
    @Test func detectorsFindTheOldTransportAndDirectoryCopies() throws {
        let copies = #"""
        final class FakeByteQueue: Sendable {
        }
        final class FakeTCPConnection: TCPConnection {
            static func pair() -> (client: FakeTCPConnection, server: FakeTCPConnection) {
            }
            static func pair(remoteAddress: String = "127.0.0.1") -> (client: FakeTCPConnection, server: FakeTCPConnection) {
            }
        }
        private final class FakeTCPListener: TCPListener {
        }
        final class FakeNetworkTransport: NetworkTransport {
        }
        final class PipeConnection: TCPConnection {
            static func pair() -> (client: PipeConnection, server: PipeConnection) {
            }
        }
        /// A fresh directory under the system temporary directory, removed by `remove()`.
        struct TemporaryDirectory: Sendable {
            let url: URL

            init() throws {
                url = FileManager.default.temporaryDirectory.appending(path: "BridgeEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        final class ScratchFolder {
            // Removed in deinit.
            let url: URL
            init() { url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }
        }
        public static func makeTemporaryDirectory(prefix: String = "CameraBridgeTests") throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        """#
        let lookAlikes = #"""
        final class FakeTransport: NetworkTransport {
        }
        final class FakeConnection: TCPConnection {
        }
        final class FakeListener: TCPListener {
        }
        private final class StalledConnection: TCPConnection {
        }
        func pair(_ id: UUID) async throws -> HAPTestController {
        }
        @Suite(.timeLimit(.minutes(1))) struct LostIdentityTests {
            private static func temporaryDirectory() -> URL {
                FileManager.default.temporaryDirectory.appending(path: "LostIdentityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            }
        }
        struct Fixture {
            let url: URL
            let data: Data
        }
        @Test func fileStoreRejectsCorruptState() throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "HAPStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
        }
        """#
        let names = { (pattern: String, text: String) in
            try definitions(pattern, in: [("t", text)]).map { $0.split(separator: " ").last.map(String.init) ?? "" }
        }
        #expect(try names(fakeTransportPattern, copies) == ["FakeByteQueue", "FakeTCPConnection", "FakeTCPListener", "FakeNetworkTransport"])
        #expect(try names(connectionPairPattern, copies) == ["FakeTCPConnection", "FakeTCPConnection", "PipeConnection"])
        #expect(try names(temporaryDirectoryTypePattern, copies) == ["TemporaryDirectory", "ScratchFolder"])
        #expect(try names(temporaryDirectoryFunctionPattern, copies) == ["makeTemporaryDirectory"])
        #expect(try names(fakeTransportPattern, lookAlikes) == [])
        #expect(try names(connectionPairPattern, lookAlikes) == [])
        #expect(try names(temporaryDirectoryTypePattern, lookAlikes) == [])
        #expect(try names(temporaryDirectoryFunctionPattern, lookAlikes) == [])
    }
}
