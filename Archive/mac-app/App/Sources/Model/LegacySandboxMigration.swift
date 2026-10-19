import Foundation

/// Camera Bridge used to run in the App Sandbox, so its configuration and preferences lived in
/// `~/Library/Containers/<bundle id>/Data/…`. The Developer ID build is not sandboxed and uses `~/Library/Application Support`
/// and `~/Library/Preferences`. On the first launch of the unsandboxed build this copies the old data over, so cameras,
/// pairings (their secrets are in the login keychain, which the sandbox never changed) and settings carry on.
///
/// Copy only: nothing in the container is changed or deleted, and nothing is copied over data that already exists.
enum LegacySandboxMigration {
    /// Set once the check has run, so it runs once.
    static let doneKey = "legacySandboxMigrationDone"

    struct Outcome: Equatable {
        /// The container's data folder was copied to the data directory.
        var copiedData = false
        /// How many preferences were taken over from the container's preferences file.
        var copiedPreferences = 0
    }

    /// `~/Library/Containers/<bundleID>/Data` for the real home folder `home`.
    static func containerData(bundleID: String, home: URL) -> URL {
        home.appending(path: "Library/Containers/\(bundleID)/Data", directoryHint: .isDirectory)
    }

    /// Takes over what the sandboxed app left behind, once.
    /// - Parameters:
    ///   - dataDirectory: the unsandboxed app's data directory (`…/Application Support/CameraBridge`).
    ///   - home: the real home folder (`FileManager.homeDirectoryForCurrentUser`; tests pass a scratch folder).
    @discardableResult
    static func migrate(bundleID: String, home: URL, dataDirectory: URL, defaults: UserDefaults,
                        fileManager: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        guard !defaults.bool(forKey: doneKey) else { return outcome }
        var finished = true
        defer { if finished { defaults.set(true, forKey: doneKey) } }

        let container = containerData(bundleID: bundleID, home: home)
        guard fileManager.fileExists(atPath: container.path) else { return outcome }

        // The configuration: only when this build has none of its own yet.
        let oldData = container.appending(path: "Library/Application Support/CameraBridge", directoryHint: .isDirectory)
        let hasOwnConfiguration = fileManager.fileExists(atPath: dataDirectory.appending(path: "config.json").path)
        if !hasOwnConfiguration, fileManager.fileExists(atPath: oldData.appending(path: "config.json").path) {
            do {
                try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
                // config.json last: a copy that stops half way leaves no configuration, and the next launch tries again.
                let items = try fileManager.contentsOfDirectory(at: oldData, includingPropertiesForKeys: nil)
                    .sorted { ($0.lastPathComponent == "config.json" ? 1 : 0) < ($1.lastPathComponent == "config.json" ? 1 : 0) }
                for item in items {
                    let target = dataDirectory.appending(path: item.lastPathComponent)
                    if !fileManager.fileExists(atPath: target.path) { try fileManager.copyItem(at: item, to: target) }
                }
                outcome.copiedData = true
            } catch {
                finished = false   // the container is untouched; the next launch tries again
                return outcome
            }
        }

        // Preferences (onboarding done, switches, the sidebar): keys this build has not set itself.
        let oldPreferences = container.appending(path: "Library/Preferences/\(bundleID).plist")
        if let old = NSDictionary(contentsOf: oldPreferences) as? [String: Any] {
            for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("Apple") && !key.hasPrefix("NS") && key != doneKey {
                defaults.set(value, forKey: key)
                outcome.copiedPreferences += 1
            }
        }
        return outcome
    }
}
