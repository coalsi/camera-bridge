import Foundation

/// The CameraBridge website and its small API (camera profiles, optional setup reports). One constant for the base URL.
enum CameraBridgeService {
    /// The site's address. Everything below is built from it.
    static let baseURL = URL(string: "https://www.camera-bridge.app")!   // a literal that is a valid URL

    static var website: URL { baseURL }
    static var support: URL { baseURL.appending(path: "support") }
    static var privacyPolicy: URL { baseURL.appending(path: "privacy") }
    static var terms: URL { baseURL.appending(path: "terms") }
    static var supportedCameras: URL { baseURL.appending(path: "cameras") }
    /// The documentation site.
    static let documentation = URL(string: "https://docs.camera-bridge.app")!   // a literal that is a valid URL
    /// The source code (free for personal and noncommercial use: PolyForm Noncommercial 1.0.0).
    static let sourceCode = URL(string: "https://github.com/coalsi/camera-bridge")!   // a literal that is a valid URL
    /// The PolyForm Noncommercial License 1.0.0 that Camera Bridge is under.
    static let license = URL(string: "https://polyformproject.org/licenses/noncommercial/1.0.0/")!   // a literal that is a valid URL
    /// The update list Sparkle reads (`SUFeedURL` in Info.plist).
    static var appcast: URL { baseURL.appending(path: "appcast.xml") }

    static var cameraProfilesEndpoint: URL { baseURL.appending(path: "api/v1/camera-profiles") }
    static var setupReportsEndpoint: URL { baseURL.appending(path: "api/v1/setup-reports") }

    /// Header sent with setup reports (the server ignores requests without it).
    static let clientHeaderName = "X-CameraBridge-Client"
    static let clientHeaderValue = "1"
}

/// Version and system text for About and for setup reports.
enum AppInfo {
    static var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–" }
    static var copyright: String { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "© 2026 Corey Silvia" }

    /// "macOS 27.0" (the patch number only when it isn't 0).
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "macOS \(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }
}
