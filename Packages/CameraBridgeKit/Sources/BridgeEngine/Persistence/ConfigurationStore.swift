import BridgeSupport
import Foundation
import Synchronization

/// Everything `config.json` holds: bridge settings and the cameras. Passwords are never part of it (`CredentialStore`).
public struct BridgeConfiguration: Sendable, Codable, Equatable {
    public var settings: BridgeSettings
    public var cameras: [CameraConfiguration]

    public init(settings: BridgeSettings = BridgeSettings(), cameras: [CameraConfiguration] = []) {
        self.settings = settings
        self.cameras = cameras
    }
}

public enum ConfigurationStoreError: Error, Equatable, Sendable {
    /// The file's `schemaVersion` is newer than this build, or older without a migration. Such a file is never
    /// overwritten: `save` refuses too, so a downgrade cannot destroy a newer configuration.
    case unsupportedSchemaVersion(Int)
    /// Not a JSON object, no integer `schemaVersion`, `settings` not an object, `cameras` not a list, or a failing
    /// migration. (A camera entry this build cannot read does not make the file corrupt: see `ConfigurationStore`.)
    case corrupt(String)
}

/// Upgrades the JSON object of schema version `n` (the dictionary key) to version `n + 1` in place. The store sets
/// `schemaVersion` after each step.
public typealias ConfigurationMigration = @Sendable (inout [String: Any]) throws -> Void

/// `config.json` in the engine's data directory: `{"schemaVersion": 1, "settings": {…}, "cameras": […]}`, written
/// atomically with mode 0600 (the directory is created 0700). Older files pass through `migrations` (one step per
/// version) and are rewritten in the current version after the original is kept as `config.json.v<n>.bak`.
///
/// Cameras are read one entry at a time: an entry this build cannot read (an unknown `vendor` or `kind` from a newer
/// build, a missing `id`, …) is left out of the result with a warning but kept: `save` writes it back unchanged (after
/// the cameras it is given), so a downgrade or a hand edit never loses a camera and its HAP identity. Unreadable
/// optional fields take their defaults (`CameraConfiguration`, `BridgeSettings`). Thread-safe: file access is serialised.
public final class ConfigurationStore: Sendable {
    public static let currentSchemaVersion = 1
    public static let fileName = "config.json"
    /// Built-in migrations (none yet: version 1 is the first).
    public static let defaultMigrations: [Int: ConfigurationMigration] = [:]

    public let directory: URL
    public let fileURL: URL
    private let migrations: [Int: ConfigurationMigration]
    /// Camera entries of the last load that this build cannot read, in file order (written back by `save`).
    private let unreadableCameras = Mutex<[UnreadableCamera]>([])
    private static let log = Log(category: "Engine")

    private struct UnreadableCamera: Sendable {
        /// The entry's `id` when it has a valid one (a saved camera with the same id replaces it).
        var id: UUID?
        /// The entry as JSON.
        var json: Data
    }

    public init(directory: URL, migrations: [Int: ConfigurationMigration] = ConfigurationStore.defaultMigrations) {
        self.directory = directory
        self.fileURL = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
        self.migrations = migrations
    }

    /// The stored configuration, nil when there is no file yet. Migrates (and rewrites) older files. Cameras that
    /// repeat an earlier camera's id are dropped, unreadable camera entries are set aside (both with a warning).
    public func load() throws -> BridgeConfiguration? {
        try unreadableCameras.withLock { unreadable in try loadLocked(&unreadable) }
    }

    /// Like `load()`, but a missing file gives the defaults, and a corrupt file (also one whose migration fails) is
    /// renamed to `config.corrupt-<UTC timestamp>.json` (returned as `recoveredFrom`) and replaced by the defaults in
    /// memory. Files from a newer version, or older ones without a migration, still throw `unsupportedSchemaVersion`.
    public func loadOrRecover() throws -> (configuration: BridgeConfiguration, recoveredFrom: URL?) {
        try unreadableCameras.withLock { unreadable in
            do {
                return (try loadLocked(&unreadable) ?? BridgeConfiguration(), nil)
            } catch ConfigurationStoreError.corrupt(let reason) {
                unreadable = []
                let stamp = Self.timestamp(Date())
                let backup = PrivateFiles.unusedURL(in: directory) { $0 == 0 ? "config.corrupt-\(stamp).json" : "config.corrupt-\(stamp)-\($0).json" }
                try FileManager.default.moveItem(at: fileURL, to: backup)
                Self.log.error("config.json could not be read (\(reason)); it was moved to \(backup.lastPathComponent) and the defaults are used")
                do {
                    try PrivateFiles.write(Data(backup.lastPathComponent.utf8), to: recoveryNoticeURL)
                } catch {
                    Self.log.error("The notice about \(backup.lastPathComponent) could not be saved: \(error)")
                }
                return (BridgeConfiguration(), backup)
            }
        }
    }

    /// Names the damaged file the last recovery set aside (`config.recovered`, written by `loadOrRecover()`), until
    /// `clearRecoveryNotice()`: the configuration saved after a recovery loads normally, so without it a relaunch would
    /// forget why the cameras are gone before the person was told.
    static let recoveryNoticeFileName = "config.recovered"

    var recoveryNoticeURL: URL { directory.appending(path: Self.recoveryNoticeFileName, directoryHint: .notDirectory) }

    /// The damaged file a recovery set aside that nobody has dismissed yet, or nil.
    func recoveryNotice() -> URL? {
        guard let data = try? Data(contentsOf: recoveryNoticeURL),
              let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.hasPrefix("config.corrupt-"), !name.contains("/") else { return nil }
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// The person saw the notice: `recoveryNotice()` is nil from now on (the damaged file itself stays).
    func clearRecoveryNotice() throws {
        guard PrivateFiles.exists(recoveryNoticeURL) else { return }
        try FileManager.default.removeItem(at: recoveryNoticeURL)
    }

    /// Writes `configuration` in the current schema version (stream URLs without user info), followed by the camera
    /// entries the last load could not read (unless `configuration` has a camera with the same id). Refuses to replace a
    /// file from a newer version or an older one without a migration (`unsupportedSchemaVersion`); an older file with a
    /// migration is kept as `config.json.v<n>.bak` first.
    public func save(_ configuration: BridgeConfiguration) throws {
        try unreadableCameras.withLock { unreadable in
            if let version = storedSchemaVersion(), version != Self.currentSchemaVersion {
                guard version < Self.currentSchemaVersion, canMigrate(from: version) else {
                    throw ConfigurationStoreError.unsupportedSchemaVersion(version)
                }
                try keepBackup(of: Data(contentsOf: fileURL), version: version)
            }
            try PrivateFiles.prepareDirectory(directory)
            try PrivateFiles.write(try Self.encode(configuration, appending: unreadable), to: fileURL)
        }
    }

    // MARK: - Private

    private struct FileContents: Encodable {
        var schemaVersion: Int
        var settings: BridgeSettings
        var cameras: [CameraConfiguration]
    }

    private func loadLocked(_ unreadable: inout [UnreadableCamera]) throws -> BridgeConfiguration? {
        guard PrivateFiles.exists(fileURL) else {
            unreadable = []
            return nil
        }
        let original = try Data(contentsOf: fileURL)
        guard var object = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
            throw ConfigurationStoreError.corrupt("not a JSON object")
        }
        guard let version = Self.schemaVersion(in: object), version >= 0 else {
            throw ConfigurationStoreError.corrupt("no valid schemaVersion")
        }
        guard version <= Self.currentSchemaVersion else { throw ConfigurationStoreError.unsupportedSchemaVersion(version) }
        var current = version
        while current < Self.currentSchemaVersion {
            guard let migration = migrations[current] else { throw ConfigurationStoreError.unsupportedSchemaVersion(current) }
            do {
                try migration(&object)
            } catch {
                throw ConfigurationStoreError.corrupt("migration from version \(current) failed: \(error)")
            }
            current += 1
            object["schemaVersion"] = current
        }
        let (configuration, skipped) = try Self.decode(object)
        unreadable = skipped
        if version < Self.currentSchemaVersion {
            try keepBackup(of: original, version: version)
            try PrivateFiles.write(try Self.encode(configuration, appending: skipped), to: fileURL)
            Self.log.notice("config.json was upgraded from version \(version) to \(Self.currentSchemaVersion)")
        }
        return configuration
    }

    /// Settings and cameras from the (current-version) JSON object; camera entries that do not decode are returned
    /// separately.
    private static func decode(_ object: [String: Any]) throws -> (BridgeConfiguration, [UnreadableCamera]) {
        let decoder = JSONDecoder()
        var settings = BridgeSettings()
        switch object["settings"] {
        case nil, is NSNull:
            break
        case let value as [String: Any]:
            do {
                settings = try decoder.decode(BridgeSettings.self, from: JSONSerialization.data(withJSONObject: value))
            } catch {
                throw ConfigurationStoreError.corrupt("settings: \(describe(error))")
            }
        default:
            throw ConfigurationStoreError.corrupt("settings is not an object")
        }
        let entries: [Any]
        switch object["cameras"] {
        case nil, is NSNull: entries = []
        case let list as [Any]: entries = list
        default: throw ConfigurationStoreError.corrupt("cameras is not a list")
        }
        var cameras: [CameraConfiguration] = []
        var skipped: [UnreadableCamera] = []
        var seen = Set<UUID>()
        for (index, entry) in entries.enumerated() {
            guard let fields = entry as? [String: Any], let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
                log.warning("config.json: camera entry \(index + 1) is not an object and is dropped")
                continue
            }
            let camera: CameraConfiguration
            do {
                camera = try decoder.decode(CameraConfiguration.self, from: json)
            } catch {
                skipped.append(UnreadableCamera(id: (fields["id"] as? String).flatMap(UUID.init(uuidString:)), json: json))
                log.warning("config.json: camera entry \(index + 1) cannot be read by this version (\(describe(error))); "
                            + "it is not used but kept in the file")
                continue
            }
            if seen.insert(camera.id).inserted {
                cameras.append(camera)
            } else {
                log.warning("config.json lists camera \(camera.id.uuidString) twice; the later entry (\(camera.name)) is ignored")
            }
        }
        return (BridgeConfiguration(settings: settings, cameras: cameras), skipped)
    }

    /// The file's bytes: current schema version, cameras without stream credentials, then `unreadable` entries whose id
    /// is not among the cameras.
    private static func encode(_ configuration: BridgeConfiguration, appending unreadable: [UnreadableCamera]) throws -> Data {
        let file = FileContents(schemaVersion: currentSchemaVersion, settings: configuration.settings,
                                cameras: configuration.cameras.map(\.withoutStreamCredentials))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        let ids = Set(configuration.cameras.map(\.id))
        let kept = unreadable.filter { $0.id.map { !ids.contains($0) } ?? true }
        guard !kept.isEmpty, var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var cameras = object["cameras"] as? [Any] else { return data }
        for entry in kept {
            if let fields = try? JSONSerialization.jsonObject(with: entry.json) { cameras.append(fields) }
        }
        object["cameras"] = cameras
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// `config.json.v<version>.bak` (0600) with `original`, unless one exists.
    private func keepBackup(of original: Data, version: Int) throws {
        let backup = directory.appending(path: "\(Self.fileName).v\(version).bak", directoryHint: .notDirectory)
        guard !PrivateFiles.exists(backup) else { return }
        try PrivateFiles.write(original, to: backup)
    }

    /// Whether every step from `version` to the current version has a migration.
    private func canMigrate(from version: Int) -> Bool {
        version >= 0 && (version..<Self.currentSchemaVersion).allSatisfy { migrations[$0] != nil }
    }

    /// The version of the file on disk, nil when there is none or it cannot be read.
    private func storedSchemaVersion() -> Int? {
        guard PrivateFiles.exists(fileURL), let data = try? Data(contentsOf: fileURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return Self.schemaVersion(in: object)
    }

    /// An integral JSON number (a string or a fraction is not a version).
    private static func schemaVersion(in object: [String: Any]) -> Int? {
        guard let number = object["schemaVersion"] as? NSNumber else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// Where decoding failed, without values (the file holds the webhook token).
    private static func describe(_ error: any Error) -> String {
        guard let decodingError = error as? DecodingError else { return "invalid content" }
        let context: DecodingError.Context
        switch decodingError {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c): context = c
        @unknown default: return "invalid content"
        }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        if case .keyNotFound(let key, _) = decodingError { return "missing \(path.isEmpty ? key.stringValue : path + "." + key.stringValue)" }
        return "invalid value at \(path.isEmpty ? "top level" : path)"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
