import BridgeEngine
import CameraAdapters
import Foundation

/// The sentences Settings builds from engine state, apart from the views so they can be tested.
enum SettingsText {
    // MARK: HomeKit

    /// "3 cameras · 2 turned on", "1 camera", "No cameras yet".
    static func cameraCount(_ cameras: [CameraConfiguration]) -> String {
        guard !cameras.isEmpty else { return String(localized: "No cameras yet") }
        let count = cameras.count == 1 ? String(localized: "1 camera") : String(localized: "\(cameras.count) cameras")
        let off = cameras.filter { !$0.isEnabled }.count
        guard off > 0 else { return count }
        return count + " · " + (off == 1 ? String(localized: "1 turned off") : String(localized: "\(off) turned off"))
    }

    /// One accessory's line in the HomeKit tab: where it stands with the Home app, and its port.
    /// "Added to Apple Home · Port 21100", "Not added yet · Port 21101", "Turned off".
    static func accessorySubtitle(for camera: CameraConfiguration, status: CameraStatus?) -> String {
        guard camera.isEnabled else { return String(localized: "Turned off") }
        var parts = [status?.isPaired == true ? String(localized: "Added to Apple Home") : String(localized: "Not added yet")]
        if let port = port(of: camera, status: status) { parts.append(String(localized: "Port \(String(port))")) }
        return parts.joined(separator: " · ")
    }

    /// The accessory's HAP port: the running one, else the one saved for the camera; nil while neither is known.
    static func port(of camera: CameraConfiguration, status: CameraStatus?) -> UInt16? {
        if let port = status?.hapPort, port != 0 { return port }
        return camera.hapPort == 0 ? nil : camera.hapPort
    }

    /// "CameraBridge Sensors" line: "Added to Apple Home · 4 sensors", "Not added yet · 1 sensor".
    static func sensorsBridgeSubtitle(_ bridge: SensorsBridgeStatus?) -> String {
        guard let bridge else { return String(localized: "Starts with the first camera") }
        let sensors = bridge.accessoryCount == 1 ? String(localized: "1 sensor") : String(localized: "\(bridge.accessoryCount) sensors")
        return (bridge.isPaired ? String(localized: "Added to Apple Home") : String(localized: "Not added yet")) + " · " + sensors
    }

    // MARK: Webhook

    /// What the Webhook tab says about the listener.
    static func webhookStatus(enabled: Bool, state: EngineState, problem: String?, port: UInt16) -> String {
        guard enabled else { return String(localized: "Off") }
        if problem != nil { return String(localized: "Not listening") }
        switch state {
        case .running: return String(localized: "Listening on port \(String(port))")
        case .starting: return String(localized: "Starting…")
        case .paused: return String(localized: "Paused with the bridge")
        case .stopped, .failed: return String(localized: "Not listening")
        }
    }

    // MARK: Camera profiles

    /// "Version 3 · 12 camera profiles".
    static func profileSummary(_ status: CameraProfileService.Status) -> String {
        let profiles = status.profileCount == 1 ? String(localized: "1 camera profile") : String(localized: "\(status.profileCount) camera profiles")
        return String(localized: "Version \(status.version)") + " · " + profiles
    }

    /// Where the feed in use came from.
    static func profileSource(_ status: CameraProfileService.Status) -> String {
        status.isDownloaded ? String(localized: "Downloaded from the Camera Bridge website") : String(localized: "Built into this version of Camera Bridge")
    }

    /// "Never", "Just now", "2 hours ago".
    static func lastChecked(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return String(localized: "Never") }
        guard now.timeIntervalSince(date) >= 60 else { return String(localized: "Just now") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// What the last Check Now found.
    static func checkResult(_ outcome: CameraProfileService.RefreshOutcome) -> (text: String, isProblem: Bool) {
        switch outcome {
        case .updated(let feed): (String(localized: "Updated to version \(feed.version)."), false)
        case .upToDate, .notDue: (String(localized: "You have the latest camera profiles."), false)
        case .failed: (String(localized: "Couldn’t reach the Camera Bridge website. Try again later."), true)
        }
    }

    // MARK: Data

    /// The data folder as the person knows it: "~/Library/…" for a path under their home folder. A sandboxed app's own
    /// home is its container, so `home` is the account's, from the user database.
    static func displayPath(_ url: URL, home: String = accountHomeDirectory()) -> String {
        let path = url.path
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The account's home folder (`getpwuid`), not the container's.
    static func accountHomeDirectory() -> String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return "" }
        return String(cString: directory)
    }
}
