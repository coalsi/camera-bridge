import Foundation
import Testing

/// The unsandboxed Developer ID build takes over the sandboxed build's data, copying only. Everything here happens in a scratch
/// "home folder": the real ~/Library/Containers is never read or written.
@Suite(.timeLimit(.minutes(1))) struct LegacySandboxMigrationTests {
    private let bundleID = "com.example.CameraBridgeTests"

    /// A scratch home with an old container holding `config.json` (and a pairing file), optionally preferences.
    private func makeHome(withConfig: Bool = true, preferences: [String: Any]? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        let data = LegacySandboxMigration.containerData(bundleID: bundleID, home: home)
        let support = data.appending(path: "Library/Application Support/CameraBridge/hap/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("pairing".utf8).write(to: support.appending(path: "pairings.json"))
        if withConfig {
            try Data("{\"schemaVersion\":1}".utf8).write(to: data.appending(path: "Library/Application Support/CameraBridge/config.json"))
        }
        if let preferences {
            let folder = data.appending(path: "Library/Preferences", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (preferences as NSDictionary).write(to: folder.appending(path: "\(bundleID).plist"))
        }
        return home
    }

    @Test func copiesTheConfigurationAndLeavesTheContainerAlone() throws {
        let home = try makeHome(preferences: ["onboardingCompleted": true, "AppleLanguages": ["fr"]])
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appending(path: "Library/Application Support/CameraBridge", directoryHint: .isDirectory)
        let scratch = ScratchDefaults()

        let outcome = LegacySandboxMigration.migrate(bundleID: bundleID, home: home, dataDirectory: target, defaults: scratch.defaults)

        #expect(outcome.copiedData)
        #expect(outcome.copiedPreferences == 1)   // Apple* keys are the system's, not ours
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "config.json").path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "hap/abc/pairings.json").path))
        #expect(scratch.defaults.bool(forKey: "onboardingCompleted"))
        // The container is still complete.
        let old = LegacySandboxMigration.containerData(bundleID: bundleID, home: home)
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "Library/Application Support/CameraBridge/config.json").path))
    }

    @Test func runsOnlyOnce() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appending(path: "Library/Application Support/CameraBridge", directoryHint: .isDirectory)
        let scratch = ScratchDefaults()
        LegacySandboxMigration.migrate(bundleID: bundleID, home: home, dataDirectory: target, defaults: scratch.defaults)
        try FileManager.default.removeItem(at: target)   // the person deleted their cameras since

        let second = LegacySandboxMigration.migrate(bundleID: bundleID, home: home, dataDirectory: target, defaults: scratch.defaults)

        #expect(second == LegacySandboxMigration.Outcome())
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func neverReplacesAConfigurationTheNewBuildAlreadyHas() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appending(path: "Library/Application Support/CameraBridge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: target.appending(path: "config.json"))
        let scratch = ScratchDefaults()

        let outcome = LegacySandboxMigration.migrate(bundleID: bundleID, home: home, dataDirectory: target, defaults: scratch.defaults)

        #expect(!outcome.copiedData)
        #expect(try String(contentsOf: target.appending(path: "config.json"), encoding: .utf8) == "mine")
    }

    @Test func keepsPreferencesTheNewBuildAlreadySet() throws {
        let home = try makeHome(withConfig: false, preferences: ["sharesSetupReports": true, "onboardingCompleted": true])
        defer { try? FileManager.default.removeItem(at: home) }
        let scratch = ScratchDefaults()
        scratch.defaults.set(false, forKey: "sharesSetupReports")

        let outcome = LegacySandboxMigration.migrate(bundleID: bundleID, home: home, dataDirectory: home.appending(path: "none"),
                                                     defaults: scratch.defaults)

        #expect(!outcome.copiedData)   // the old container has no configuration
        #expect(outcome.copiedPreferences == 1)
        #expect(scratch.defaults.bool(forKey: "sharesSetupReports") == false)
        #expect(scratch.defaults.bool(forKey: "onboardingCompleted"))
    }

    @Test func doesNothingWithoutAContainer() {
        let home = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        let scratch = ScratchDefaults()
        let outcome = LegacySandboxMigration.migrate(bundleID: bundleID, home: home, dataDirectory: home.appending(path: "data"),
                                                     defaults: scratch.defaults)
        #expect(outcome == LegacySandboxMigration.Outcome())
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }
}
