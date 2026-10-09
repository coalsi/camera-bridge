import BridgeEngine
import BridgeSupport
import Foundation

/// A configuration backup (Settings › Backup): the cameras and the bridge settings as a JSON file the person keeps.
///
/// What it holds: each camera's name, kind, address, user name, stream addresses (without credentials), motion, sensor,
/// audio, live view and recording options, and the bridge's ports, log level and keep-awake choice. What it never holds:
/// camera passwords (they stay in the Keychain), the webhook token, HomeKit pairings and setup codes. Importing adds the
/// cameras that aren't set up yet (matched by their ID) and leaves the others alone.
struct ConfigurationBackup: Codable, Equatable {
    /// Marks the file as one of ours (`decode` refuses anything else).
    static let kind = "CameraBridgeBackup"
    static let currentVersion = 1
    static let fileExtension = "camerabridge-backup"

    /// The bridge settings a backup carries: all of `BridgeSettings` except the webhook token (a bearer credential:
    /// systems that use it keep working, and a restored webhook gets a fresh one only if this Mac has none).
    struct Settings: Codable, Equatable {
        var webhookEnabled: Bool
        var webhookPort: UInt16
        var keepMacAwake: Bool
        var sensorsBridgePort: UInt16
        var logLevel: LogLevel
        var basePort: UInt16

        init(_ settings: BridgeSettings) {
            webhookEnabled = settings.webhookEnabled
            webhookPort = settings.webhookPort
            keepMacAwake = settings.keepMacAwake
            sensorsBridgePort = settings.sensorsBridgePort
            logLevel = settings.logLevel
            basePort = settings.basePort
        }

        /// `settings` with these values; the webhook token stays the one it has.
        func applied(to settings: inout BridgeSettings) {
            settings.webhookEnabled = webhookEnabled
            settings.webhookPort = webhookPort
            settings.keepMacAwake = keepMacAwake
            settings.sensorsBridgePort = sensorsBridgePort
            settings.logLevel = logLevel
            settings.basePort = basePort
        }
    }

    var kind: String
    var version: Int
    var exportedAt: Date
    /// "1.0 (1)" of the app that wrote it.
    var appVersion: String
    var settings: Settings
    var cameras: [CameraConfiguration]

    init(settings: BridgeSettings, cameras: [CameraConfiguration], exportedAt: Date = Date(), appVersion: String = "") {
        kind = Self.kind
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.settings = Settings(settings)
        // No user info in stream addresses: a password typed into an address must not end up in a file.
        self.cameras = cameras.map(\.withoutStreamCredentials)
    }

    // MARK: Writing

    /// "CameraBridge-Backup-20261002-141500.camerabridge-backup"
    static func fileName(_ date: Date = Date()) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "CameraBridge-Backup-%04d%02d%02d-%02d%02d%02d.\(fileExtension)", components.year ?? 0, components.month ?? 0,
                      components.day ?? 0, components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    // MARK: Reading

    enum ReadError: Error, Equatable, LocalizedError {
        /// Not JSON, or JSON that isn't a CameraBridge backup.
        case notABackup
        /// Written by a newer CameraBridge than this one.
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .notABackup:
                String(localized: "This file isn’t a Camera Bridge backup.")
            case .newerVersion:
                String(localized: "This backup was made by a newer version of Camera Bridge. Update Camera Bridge, then try again.")
            }
        }
    }

    /// A backup read from a file, and how many camera entries in it could not be read (a camera from a newer version,
    /// for example: it is left out, the rest is imported).
    struct Reading: Equatable {
        var backup: ConfigurationBackup
        var unreadableCameras: Int
    }

    /// Reads the camera entries one at a time, so one this version cannot read costs that camera only.
    static func read(_ data: Data) throws -> Reading {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["kind"] as? String == Self.kind, let version = (object["version"] as? NSNumber).flatMap({ Int(exactly: $0.doubleValue) }) else {
            throw ReadError.notABackup
        }
        guard version <= currentVersion else { throw ReadError.newerVersion(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let settingsObject = object["settings"], let settingsData = try? JSONSerialization.data(withJSONObject: settingsObject),
              let settings = try? decoder.decode(Settings.self, from: settingsData),
              let entries = object["cameras"] as? [Any] else {
            throw ReadError.notABackup
        }
        var cameras: [CameraConfiguration] = []
        var unreadable = 0
        var seen = Set<UUID>()
        for entry in entries {
            guard JSONSerialization.isValidJSONObject(entry), let json = try? JSONSerialization.data(withJSONObject: entry),
                  let camera = try? decoder.decode(CameraConfiguration.self, from: json) else {
                unreadable += 1
                continue
            }
            if seen.insert(camera.id).inserted { cameras.append(camera) }
        }
        let exportedAt = (object["exportedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? Date(timeIntervalSince1970: 0)
        var backup = ConfigurationBackup(settings: BridgeSettings(), cameras: cameras, exportedAt: exportedAt,
                                         appVersion: object["appVersion"] as? String ?? "")
        backup.settings = settings
        return Reading(backup: backup, unreadableCameras: unreadable)
    }

    // MARK: Importing

    /// What importing would do, shown before anything changes.
    struct ImportPlan: Equatable {
        /// Cameras this Mac doesn't have yet, in the file's order. They are added turned off (`importedCamera`).
        var camerasToAdd: [CameraConfiguration]
        /// Names of the cameras that are already set up here (same ID): left as they are.
        var alreadySetUp: [String]
        var unreadableCameras: Int
        var settings: Settings

        var isEmpty: Bool { camerasToAdd.isEmpty }
    }

    func plan(existing: [CameraConfiguration], unreadableCameras: Int = 0) -> ImportPlan {
        let known = Set(existing.map(\.id))
        return ImportPlan(camerasToAdd: cameras.filter { !known.contains($0.id) }.map(Self.importedCamera),
                          alreadySetUp: cameras.filter { known.contains($0.id) }.map(\.name), unreadableCameras: unreadableCameras,
                          settings: settings)
    }

    /// An imported camera has no password yet and no HomeKit pairing on this Mac. It is added turned off, so it doesn't
    /// keep signing in with nothing (cameras lock an account after a few failed sign-ins); the person enters its
    /// password on its page and turns it on.
    static func importedCamera(_ camera: CameraConfiguration) -> CameraConfiguration {
        var imported = camera.withoutStreamCredentials
        imported.isEnabled = false
        return imported
    }
}
