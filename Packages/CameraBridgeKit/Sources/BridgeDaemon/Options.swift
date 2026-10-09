import BridgeEngine
import BridgeSupport
import Foundation

/// What `camerabridged` was asked to do, from its flags and environment variables (a flag wins over a variable). Each setting has
/// a `CAMERABRIDGE_*` variable, the spelling Camera Bridge OS sets (`linux/os/README.md`), and the older `CAMERA_BRIDGE_*`
/// spelling; when both are set, `CAMERABRIDGE_*` wins.
public struct DaemonOptions: Equatable, Sendable {
    public static let defaultDataDirectory = "/var/lib/camera-bridge"
    public static let defaultRunDirectory = "/run/camera-bridge"

    public var dataDirectory: URL?
    public var port: UInt16 = 80
    public var staticDirectory: URL?
    /// The web interface listens on 127.0.0.1 only.
    public var webLoopbackOnly = false
    /// Development: the engine on loopback only, nothing advertised, secrets in memory (what a Mac always does).
    public var development = false
    /// Show the engine's sample data (five cameras, nothing is started) instead of running the bridge.
    public var preview: String?
    public var hapBasePort: UInt16?
    public var sensorsBridgePort: UInt16?
    public var allowedHosts: [String] = []
    public var setupToken: String?
    /// The runtime folder of the operating system; the request and status folders default to `requests` and `status` inside it.
    public var runDirectory: URL?
    /// Where privileged requests are dropped for the system's root helper (Camera Bridge OS).
    public var osRequestDirectory: URL?
    /// Where the system publishes its status files.
    public var osStatusDirectory: URL?
    public var logLevel: LogLevel = .info
    /// Dev only: the Add Camera page finds three sample cameras (RFC 5737 addresses) instead of searching the network.
    public var fakeDiscovery = false
    public var offersDemoCamera = true
    public var showVersion = false
    public var showHelp = false

    public init() {}

    /// The folders of the operating system's request protocol: explicit settings, else inside the run folder (`/run/camera-bridge`).
    public var requestDirectories: (requests: URL, status: URL) {
        let run = runDirectory ?? URL(fileURLWithPath: Self.defaultRunDirectory, isDirectory: true)
        return (osRequestDirectory ?? run.appending(path: "requests", directoryHint: .isDirectory),
                osStatusDirectory ?? run.appending(path: "status", directoryHint: .isDirectory))
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible, Sendable {
        public var message: String
        public var description: String { message }
    }

    public static let usage = """
        camerabridged: the Camera Bridge OS daemon (the bridge engine and its web interface).

        Usage: camerabridged [options]

          --data-dir PATH        where the bridge keeps its configuration (default \(defaultDataDirectory); required on a Mac)
          --port N               web interface port (default 80; 8080 with --dev)
          --static-dir PATH      the web interface's files (default: /usr/share/camera-bridge/web, or linux/web next to the program)
                                 (also --web-root)
          --loopback-only        serve the web interface on 127.0.0.1 only
          --dev                  development: loopback only, nothing advertised on the network, secrets kept in memory
          --preview [SCENARIO]   serve the engine's sample data (standard, empty, network-denied, damaged-config); starts nothing
          --hap-base-port N      first HomeKit accessory port (default 21100)
          --sensors-port N       the sensors bridge's port (0: any free port)
          --allowed-host NAME    accept this host name in the address too (repeatable)
          --setup-token-file P   first-run setup asks for the code in this file (or CAMERA_BRIDGE_SETUP_TOKEN)
          --run-dir PATH         the operating system's runtime folder (default \(defaultRunDirectory))
          --os-request-dir PATH  where requests for the system's root helper are written (default: requests in the run folder)
          --os-status-dir PATH   where the system publishes its status (default: status in the run folder)
          --log-level LEVEL      debug, info, notice, warning or error (default info)
          --fake-discovery       development: the Add Camera page finds sample cameras
          --no-demo-camera       leave the demo camera out of the camera types
          --version, --help

        Environment (flags win): CAMERABRIDGE_DATA_DIR, CAMERABRIDGE_HTTP_PORT, CAMERABRIDGE_WEB_ROOT, CAMERABRIDGE_RUN_DIR,
        CAMERABRIDGE_OS_REQUEST_DIR, CAMERABRIDGE_OS_STATUS_DIR (what Camera Bridge OS sets), and CAMERA_BRIDGE_DATA_DIR, _PORT,
        _STATIC_DIR, _LOOPBACK_ONLY, _ALLOWED_HOSTS (comma separated), _SETUP_TOKEN, _LOG_LEVEL.

        """

    /// Parses `arguments` (without the program name) over `environment`.
    public static func parse(arguments: [String], environment: [String: String] = [:]) throws -> DaemonOptions {
        var options = DaemonOptions()
        var portGiven = false
        /// The first non-empty of the variable's two spellings (`CAMERABRIDGE_X` before `CAMERA_BRIDGE_X`).
        func variable(_ names: String...) -> (name: String, value: String)? {
            for name in names { if let value = environment[name], !value.isEmpty { return (name, value) } }
            return nil
        }
        if let (_, value) = variable("CAMERABRIDGE_DATA_DIR", "CAMERA_BRIDGE_DATA_DIR") { options.dataDirectory = URL(fileURLWithPath: value, isDirectory: true) }
        if let (name, value) = variable("CAMERABRIDGE_HTTP_PORT", "CAMERA_BRIDGE_PORT") {
            options.port = try port(value, name: name)
            portGiven = true
        }
        if let (_, value) = variable("CAMERABRIDGE_WEB_ROOT", "CAMERA_BRIDGE_STATIC_DIR") { options.staticDirectory = URL(fileURLWithPath: value, isDirectory: true) }
        if let (_, value) = variable("CAMERABRIDGE_RUN_DIR") { options.runDirectory = URL(fileURLWithPath: value, isDirectory: true) }
        if let (_, value) = variable("CAMERABRIDGE_OS_REQUEST_DIR") { options.osRequestDirectory = URL(fileURLWithPath: value, isDirectory: true) }
        if let (_, value) = variable("CAMERABRIDGE_OS_STATUS_DIR") { options.osStatusDirectory = URL(fileURLWithPath: value, isDirectory: true) }
        if let (_, value) = variable("CAMERABRIDGE_LOOPBACK_ONLY", "CAMERA_BRIDGE_LOOPBACK_ONLY"), ["1", "true", "yes"].contains(value.lowercased()) {
            options.webLoopbackOnly = true
        }
        if let (_, value) = variable("CAMERABRIDGE_ALLOWED_HOSTS", "CAMERA_BRIDGE_ALLOWED_HOSTS") {
            options.allowedHosts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let (_, value) = variable("CAMERABRIDGE_SETUP_TOKEN", "CAMERA_BRIDGE_SETUP_TOKEN") { options.setupToken = value }
        if let (name, value) = variable("CAMERABRIDGE_LOG_LEVEL", "CAMERA_BRIDGE_LOG_LEVEL") { options.logLevel = try level(value, name: name) }

        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            var name = argument
            var inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inline = String(argument[argument.index(after: equals)...])
            }
            func value() throws -> String {
                if let inline { return inline }
                guard let next = remaining.first, !next.hasPrefix("--") else { throw UsageError(message: "\(name) needs a value.") }
                remaining.removeFirst()
                return next
            }
            switch name {
            case "--data-dir": options.dataDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--port":
                options.port = try port(try value(), name: name)
                portGiven = true
            case "--static-dir", "--web-root": options.staticDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--loopback-only": options.webLoopbackOnly = true
            case "--dev":
                options.development = true
                options.webLoopbackOnly = true
            case "--preview":
                // The scenario is optional: take the next word unless it is another flag.
                if let inline {
                    options.preview = inline
                } else if let next = remaining.first, !next.hasPrefix("--") {
                    options.preview = next
                    remaining.removeFirst()
                } else {
                    options.preview = "standard"
                }
                if PreviewScenario(rawValue: options.preview ?? "") == nil {
                    throw UsageError(message: "Unknown preview scenario “\(options.preview ?? "")”. Use \(PreviewScenario.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
            case "--hap-base-port": options.hapBasePort = try port(try value(), name: name)
            case "--sensors-port": options.sensorsBridgePort = try port(try value(), name: name, allowZero: true)
            case "--allowed-host": options.allowedHosts.append(try value())
            case "--setup-token-file":
                let path = try value()
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw UsageError(message: "The setup code file \(path) can’t be read.") }
                let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { options.setupToken = token }
            case "--run-dir": options.runDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--os-request-dir": options.osRequestDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--os-status-dir": options.osStatusDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--log-level": options.logLevel = try level(try value(), name: name)
            case "--fake-discovery": options.fakeDiscovery = true
            case "--no-demo-camera": options.offersDemoCamera = false
            case "--version", "-v": options.showVersion = true
            case "--help", "-h": options.showHelp = true
            default: throw UsageError(message: "Unknown option “\(argument)”. Try --help.")
            }
        }
        if options.development, !portGiven { options.port = 8080 }
        return options
    }

    private static func port(_ text: String, name: String, allowZero: Bool = false) throws -> UInt16 {
        guard let value = UInt16(text), allowZero || value != 0 else { throw UsageError(message: "\(name) needs a port number from 1 to 65535.") }
        return value
    }

    private static func level(_ text: String, name: String) throws -> LogLevel {
        guard let level = LogLevel.allCases.first(where: { DiagnosticsLog.levelName($0).lowercased() == text.lowercased() }) else {
            throw UsageError(message: "\(name): the log level must be debug, info, notice, warning or error.")
        }
        return level
    }
}
