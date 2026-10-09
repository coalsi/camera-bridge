import BridgeSupport
import Foundation

/// The go2rtc configuration Camera Bridge writes (go2rtc 1.9; github.com/AlexxIT/go2rtc, MIT). One generator for the helper
/// that serves the cameras and for the short-lived one behind the sign-in page.
///
/// - Everything listens on 127.0.0.1 only, on ports the manager picked. The web API asks for a password even from the same
///   Mac (`local_auth`); the RTSP server does not (go2rtc never asks for one on loopback).
/// - Only the modules the supported sources need start. go2rtc can run programs and scripts (`exec`, `echo`, `expr`,
///   `ffmpeg`), read files, forward ports and open tunnels (`ngrok`, `pinggy`): none of that is started, so even a request
///   to the helper's API cannot run anything.
/// - The file never holds a secret. A secret is written as `${CB_…}`, which go2rtc replaces with the environment variable of
///   that name when it reads the file (its documented `${VAR}` support); the manager puts the values in the helper's
///   environment. The file is 0600 in a private folder, and it is removed once the helper answers and at exit.
public struct Go2RTCConfig: Sendable, Equatable {
    /// One stream: `name` is the RTSP path; the source reaches go2rtc through the environment variable `variable`.
    public struct Stream: Sendable, Equatable {
        public var name: String
        public var variable: String

        public init(name: String, variable: String) {
            self.name = name
            self.variable = variable
        }
    }

    /// Modules of the serving helper: the API, the RTSP server and the camera sources.
    public static let servingModules = ["api", "rtsp", "ring", "nest", "tuya", "wyze", "tapo", "doorbird", "dvrip", "xiaomi"]
    /// Modules of the sign-in page: the API with the pages' account lookups, no RTSP server.
    public static let setupModules = ["api", "ring", "nest", "tuya", "wyze"]
    /// API paths of the serving helper: its info (the health check) and the stream list.
    public static let servingAPIPaths = ["/api", "/api/streams"]
    /// API paths of the sign-in page: go2rtc's own pages (`/`) and the account lookups they call.
    public static let setupAPIPaths = ["/", "/api", "/api/streams", "/api/ring", "/api/nest", "/api/tuya", "/api/wyze"]

    /// The environment variable the API password is in.
    public static let passwordVariable = "CB_API_PASSWORD"
    public static let apiUsername = "camerabridge"

    public var apiPort: UInt16
    /// nil: no RTSP server (the sign-in page).
    public var rtspPort: UInt16?
    public var streams: [Stream]
    public var modules: [String]
    public var apiPaths: [String]
    /// Ask for the API password from this Mac too (the serving helper). The sign-in page is opened in a browser and has none.
    public var requiresAPIPassword: Bool
    public var logLevel: String

    public init(apiPort: UInt16, rtspPort: UInt16?, streams: [Stream] = [], modules: [String] = Go2RTCConfig.servingModules,
                apiPaths: [String] = Go2RTCConfig.servingAPIPaths, requiresAPIPassword: Bool = true, logLevel: String = "info") {
        self.apiPort = apiPort
        self.rtspPort = rtspPort
        self.streams = streams
        self.modules = modules
        self.apiPaths = apiPaths
        self.requiresAPIPassword = requiresAPIPassword
        self.logLevel = logLevel
    }

    /// The file's text (YAML).
    public var yaml: String {
        var lines: [String] = []
        lines.append("app:")
        lines.append("  modules: [\(modules.joined(separator: ", "))]")
        lines.append("api:")
        lines.append("  listen: \"127.0.0.1:\(apiPort)\"")
        lines.append("  allow_paths: [\(apiPaths.joined(separator: ", "))]")
        if requiresAPIPassword {
            lines.append("  username: \"\(Self.apiUsername)\"")
            lines.append("  password: '${\(Self.passwordVariable)}'")
            lines.append("  local_auth: true")
        }
        if let rtspPort {
            lines.append("rtsp:")
            lines.append("  listen: \"127.0.0.1:\(rtspPort)\"")
        }
        lines.append("log:")
        lines.append("  level: \(logLevel)")
        lines.append("  format: text")
        lines.append("  time: \"\"")
        if streams.isEmpty {
            lines.append("streams: {}")
        } else {
            lines.append("streams:")
            for stream in streams {
                lines.append("  \(Self.quoted(stream.name)): '${\(stream.variable)}'")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A stream name: letters, digits, `-` and `_` only (it is a URL path and a YAML key).
    public static func isValidStreamName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 80 && name.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    /// A value for the helper's environment, as it must be to sit inside the single quotes of the file: `'` doubled (go2rtc
    /// substitutes the text before it parses the YAML).
    public static func environmentValue(forSource source: String) -> String {
        source.replacingOccurrences(of: "'", with: "''")
    }

    private static func quoted(_ name: String) -> String {
        "'\(name.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// A password for one run of the helper's API: 32 random bytes, hex.
    public static func randomPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
