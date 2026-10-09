import BridgeSupport
import BridgeWeb
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeDaemon
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite struct OptionsTests {
    @Test func defaults() throws {
        let options = try DaemonOptions.parse(arguments: [])
        #expect(options.port == 80)
        #expect(options.dataDirectory == nil)
        #expect(!options.development && !options.webLoopbackOnly)
        #expect(options.logLevel == .info)
        #expect(options.offersDemoCamera)
        #expect(options.preview == nil)
    }

    @Test func flagsAreParsedInBothSpellings() throws {
        let options = try DaemonOptions.parse(arguments: ["--data-dir", "/tmp/cb-data", "--port=8123", "--static-dir=/tmp/web", "--loopback-only", "--hap-base-port", "30000",
                                                          "--sensors-port=0", "--allowed-host", "bridge.example", "--allowed-host=other.example", "--log-level", "DEBUG",
                                                          "--fake-discovery", "--no-demo-camera", "--run-dir", "/opt/run", "--os-status-dir=/opt/status"])
        #expect(options.dataDirectory?.path == "/tmp/cb-data")
        #expect(options.port == 8123)
        #expect(options.staticDirectory?.path == "/tmp/web")
        #expect(options.webLoopbackOnly)
        #expect(options.hapBasePort == 30_000)
        #expect(options.sensorsBridgePort == 0)
        #expect(options.allowedHosts == ["bridge.example", "other.example"])
        #expect(options.logLevel == .debug)
        #expect(options.fakeDiscovery)
        #expect(!options.offersDemoCamera)
        #expect(options.runDirectory?.path == "/opt/run")
        #expect(options.requestDirectories.requests.path == "/opt/run/requests", "the request folder follows the run folder")
        #expect(options.requestDirectories.status.path == "/opt/status", "unless it is named")
    }

    @Test func developmentModeKeepsToItselfAndPicksPort8080() throws {
        let options = try DaemonOptions.parse(arguments: ["--dev"])
        #expect(options.development && options.webLoopbackOnly)
        #expect(options.port == 8080)
        #expect(try DaemonOptions.parse(arguments: ["--dev", "--port", "8099"]).port == 8099)
    }

    @Test func environmentIsUsedAndFlagsWin() throws {
        let environment = ["CAMERA_BRIDGE_DATA_DIR": "/var/x", "CAMERA_BRIDGE_PORT": "8001", "CAMERA_BRIDGE_ALLOWED_HOSTS": "a.example, b.example",
                           "CAMERA_BRIDGE_SETUP_TOKEN": "TOKEN-1", "CAMERA_BRIDGE_LOOPBACK_ONLY": "1", "CAMERA_BRIDGE_LOG_LEVEL": "warning"]
        let fromEnvironment = try DaemonOptions.parse(arguments: [], environment: environment)
        #expect(fromEnvironment.dataDirectory?.path == "/var/x")
        #expect(fromEnvironment.port == 8001)
        #expect(fromEnvironment.allowedHosts == ["a.example", "b.example"])
        #expect(fromEnvironment.setupToken == "TOKEN-1")
        #expect(fromEnvironment.webLoopbackOnly)
        #expect(fromEnvironment.logLevel == .warning)
        let overridden = try DaemonOptions.parse(arguments: ["--port", "9000", "--data-dir", "/other"], environment: environment)
        #expect(overridden.port == 9000)
        #expect(overridden.dataDirectory?.path == "/other")
    }

    @Test func theVariablesCameraBridgeOSSetsAreHonoured() throws {
        // Exactly what linux/os/units/camerabridged.service.in sets.
        let environment = ["CAMERABRIDGE_PLATFORM": "linux-os", "CAMERABRIDGE_DATA_DIR": "/var/lib/camera-bridge", "CAMERABRIDGE_WEB_ROOT": "/usr/share/camera-bridge/web",
                           "CAMERABRIDGE_HTTP_PORT": "80", "CAMERABRIDGE_RUN_DIR": "/run/camera-bridge", "CAMERABRIDGE_OS_REQUEST_DIR": "/run/camera-bridge/requests",
                           "CAMERABRIDGE_OS_STATUS_DIR": "/run/camera-bridge/status", "HOME": "/var/lib/camera-bridge"]
        let options = try DaemonOptions.parse(arguments: [], environment: environment)
        #expect(options.dataDirectory?.path == "/var/lib/camera-bridge")
        #expect(options.staticDirectory?.path == "/usr/share/camera-bridge/web")
        #expect(options.port == 80)
        #expect(options.runDirectory?.path == "/run/camera-bridge")
        #expect(options.osRequestDirectory?.path == "/run/camera-bridge/requests")
        #expect(options.osStatusDirectory?.path == "/run/camera-bridge/status")
        #expect(options.requestDirectories.requests.path == "/run/camera-bridge/requests" && options.requestDirectories.status.path == "/run/camera-bridge/status")
        // Another place for everything; flags still win.
        let moved = try DaemonOptions.parse(arguments: ["--port", "8123", "--web-root", "/w", "--os-request-dir", "/r"],
                                            environment: environment.merging(["CAMERABRIDGE_HTTP_PORT": "81"]) { $1 })
        #expect(moved.port == 8123 && moved.staticDirectory?.path == "/w" && moved.requestDirectories.requests.path == "/r")
        #expect(moved.requestDirectories.status.path == "/run/camera-bridge/status")
        // The older spelling still works, and the new one wins when both are set.
        let old = try DaemonOptions.parse(arguments: [], environment: ["CAMERA_BRIDGE_DATA_DIR": "/old", "CAMERA_BRIDGE_PORT": "8001"])
        #expect(old.dataDirectory?.path == "/old" && old.port == 8001)
        let both = try DaemonOptions.parse(arguments: [], environment: ["CAMERA_BRIDGE_DATA_DIR": "/old", "CAMERABRIDGE_DATA_DIR": "/new"])
        #expect(both.dataDirectory?.path == "/new")
        #expect(throws: DaemonOptions.UsageError.self) { try DaemonOptions.parse(arguments: [], environment: ["CAMERABRIDGE_HTTP_PORT": "eighty"]) }
    }

    @Test func withoutAnyOfThemTheDefaultsAreTheImagesFolders() throws {
        let options = try DaemonOptions.parse(arguments: [])
        #expect(options.requestDirectories.requests.path == "/run/camera-bridge/requests")
        #expect(options.requestDirectories.status.path == "/run/camera-bridge/status")
    }

    @Test func thePreviewTakesAnOptionalScenario() throws {
        #expect(try DaemonOptions.parse(arguments: ["--preview"]).preview == "standard")
        #expect(try DaemonOptions.parse(arguments: ["--preview", "empty"]).preview == "empty")
        #expect(try DaemonOptions.parse(arguments: ["--preview=network-denied"]).preview == "network-denied")
        let withFlagAfter = try DaemonOptions.parse(arguments: ["--preview", "--dev"])
        #expect(withFlagAfter.preview == "standard" && withFlagAfter.development)
        #expect(throws: DaemonOptions.UsageError.self) { try DaemonOptions.parse(arguments: ["--preview", "nonsense"]) }
    }

    @Test func aSetupCodeCanComeFromAFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.file("code")
        try Data("  ABCD-1234\n".utf8).write(to: file)
        #expect(try DaemonOptions.parse(arguments: ["--setup-token-file", file.path]).setupToken == "ABCD-1234")
        #expect(throws: DaemonOptions.UsageError.self) { try DaemonOptions.parse(arguments: ["--setup-token-file", directory.file("missing").path]) }
    }

    @Test(arguments: [["--port", "0"], ["--port", "70000"], ["--port", "abc"], ["--port"], ["--hap-base-port", "-1"], ["--log-level", "loud"], ["--wat"], ["--data-dir"], ["--allowed-host"]])
    func badCommandLinesAreRefused(arguments: [String]) {
        #expect(throws: DaemonOptions.UsageError.self) { try DaemonOptions.parse(arguments: arguments) }
    }

    @Test func helpAndVersion() throws {
        #expect(try DaemonOptions.parse(arguments: ["--help"]).showHelp)
        #expect(try DaemonOptions.parse(arguments: ["-h"]).showHelp)
        #expect(try DaemonOptions.parse(arguments: ["--version"]).showVersion)
        #expect(DaemonOptions.usage.contains("--data-dir"))
    }
}

@Suite struct StdoutLogSinkTests {
    private func sink(journal: Bool, level: LogLevel = .info, lines: Box<[String]>) -> StdoutLogSink {
        StdoutLogSink(minimumLevel: level, journal: journal) { line in lines.update { $0.append(line) } }
    }

    @Test func journalLinesCarrySyslogPriorities() {
        let lines = Box<[String]>([])
        let sink = sink(journal: true, level: .debug, lines: lines)
        for (level, priority) in [(LogLevel.error, 3), (.warning, 4), (.notice, 5), (.info, 6), (.debug, 7)] {
            sink.record(LogEntry(level: level, category: "Test", message: "hello"))
            #expect(lines.value.last == "<\(priority)>[Test] hello\n")
        }
    }

    @Test func plainLinesCarryATimestampAndTheCamera() {
        let lines = Box<[String]>([])
        let id = UUID()
        sink(journal: false, lines: lines).record(LogEntry(date: Date(timeIntervalSince1970: 0), level: .info, category: "Camera", message: "online", cameraID: id))
        #expect(lines.value.first?.hasPrefix("1970-01-01T00:00:00.000Z INFO [Camera] <\(id.uuidString.prefix(8))") == true)
    }

    @Test func belowTheLevelIsDropped() {
        let lines = Box<[String]>([])
        let sink = sink(journal: true, level: .warning, lines: lines)
        sink.record(LogEntry(level: .info, category: "x", message: "quiet"))
        sink.record(LogEntry(level: .warning, category: "x", message: "loud"))
        #expect(lines.value == ["<4>[x] loud\n"])
    }

    @Test func secretsAndNewlinesNeverReachTheJournal() {
        let lines = Box<[String]>([])
        let sink = sink(journal: true, lines: lines)
        sink.record(LogEntry(level: .error, category: "x", message: "cannot open rtsp://admin:hunter2@192.0.2.20/s and password=hunter2\nsecond line"))
        let text = lines.value.joined()
        #expect(!text.contains("hunter2"))
        #expect(text.components(separatedBy: "\n").count == 2, "one line, one trailing newline")
    }
}

#if canImport(Darwin) || canImport(Glibc)
@Suite(.timeLimit(.minutes(1))) struct SystemDTests {
    /// A unix datagram socket that systemd would own.
    private final class Receiver: @unchecked Sendable {
        let path: String
        private let descriptor: Int32

        init() throws {
            path = "/tmp/cbn-\(UInt32.random(in: 0...UInt32.max)).sock"
            #if canImport(Darwin)
            descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
            #else
            descriptor = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue), 0)
            #endif
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in Array(path.utf8).enumerated() { buffer[index] = byte }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw TransportError.failed("bind") }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        func receive() -> String? {
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            return count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : nil
        }

        deinit {
            close(descriptor)
            unlink(path)
        }
    }

    @Test func readyIsDeliveredToTheNotifySocket() throws {
        let receiver = try Receiver()
        #expect(SystemD.notify("READY=1\nSTATUS=Running", environment: ["NOTIFY_SOCKET": receiver.path]))
        #expect(receiver.receive() == "READY=1\nSTATUS=Running")
        #expect(SystemD.notify("WATCHDOG=1", environment: ["NOTIFY_SOCKET": receiver.path]))
        #expect(receiver.receive() == "WATCHDOG=1")
    }

    @Test func withoutASocketNothingHappens() {
        #expect(!SystemD.notify("READY=1", environment: [:]))
        #expect(!SystemD.notify("READY=1", environment: ["NOTIFY_SOCKET": ""]))
        #expect(!SystemD.notify("READY=1", environment: ["NOTIFY_SOCKET": "/nonexistent/dir/notify.sock"]))
        #expect(!SystemD.notify("READY=1", environment: ["NOTIFY_SOCKET": String(repeating: "x", count: 300)]))
    }

    @Test func theWatchdogPingsWellWithinHalfTheInterval() {
        #expect(SystemD.watchdogInterval(environment: [:]) == nil)
        #expect(SystemD.watchdogInterval(environment: ["WATCHDOG_USEC": "30000000"]) == .seconds(10))
        #expect(SystemD.watchdogInterval(environment: ["WATCHDOG_USEC": "0"]) == nil)
        #expect(SystemD.watchdogInterval(environment: ["WATCHDOG_USEC": "abc"]) == nil)
        #expect(SystemD.watchdogInterval(environment: ["WATCHDOG_USEC": "30000000", "WATCHDOG_PID": "1"]) == nil, "meant for another process")
        #expect(SystemD.watchdogInterval(environment: ["WATCHDOG_USEC": "30000000", "WATCHDOG_PID": "\(getpid())"]) == .seconds(10))
    }

    @Test func theJournalIsRecognised() {
        #expect(SystemD.logsToJournal(environment: ["JOURNAL_STREAM": "8:12345"]))
        #expect(!SystemD.logsToJournal(environment: [:]))
    }
}
#endif
