import BridgeSupport
import CameraAdapters
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

@Suite(.timeLimit(.minutes(1))) struct ConfigurationStoreTests {
    private func sampleConfiguration() -> BridgeConfiguration {
        var driveway = CameraConfiguration(id: UUID(uuidString: "0B8A2E4C-1111-4000-8000-000000000001") ?? UUID(), name: "Driveway",
                                           kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.21"), username: "admin")
        driveway.mainStreamURL = URL(string: "rtsp://192.0.2.21:554/ISAPI/Streaming/channels/101")
        driveway.sensors.person = true
        driveway.hapPort = 21_100
        driveway.capabilities = CameraCapabilities(events: [.motion, .person], snapshotAPI: true)
        var door = CameraConfiguration(name: "Front Door", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: "192.0.2.22"),
                                       username: "admin")
        door.motionHoldSeconds = 45
        var settings = BridgeSettings()
        settings.webhookEnabled = true
        settings.basePort = 22_000
        return BridgeConfiguration(settings: settings, cameras: [driveway, door])
    }

    @Test func missingFileLoadsNothing() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        #expect(try ConfigurationStore(directory: directory.url).load() == nil)
    }

    @Test func savesVersionedPrivateFileAtomicallyAndLoadsItBack() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let dataDirectory = directory.url.appending(path: "CameraBridge", directoryHint: .isDirectory)
        let store = ConfigurationStore(directory: dataDirectory)
        let configuration = sampleConfiguration()
        try store.save(configuration)
        #expect(store.fileURL == dataDirectory.appending(path: "config.json"))
        #expect(try posixPermissions(of: store.fileURL) == 0o600)
        #expect(try posixPermissions(of: dataDirectory) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path(percentEncoded: false)) == ["config.json"],
                "no temporary files left behind")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(Set(object.keys) == ["schemaVersion", "settings", "cameras"])
        #expect(try store.load() == configuration)
        #expect(try ConfigurationStore(directory: dataDirectory).load() == configuration)

        var changed = configuration
        changed.cameras.removeLast()
        try store.save(changed)
        #expect(try store.load() == changed)
        #expect(try posixPermissions(of: store.fileURL) == 0o600)
    }

    @Test func streamURLsAreSavedWithoutCredentials() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        var configuration = sampleConfiguration()
        configuration.cameras[0].mainStreamURL = URL(string: "rtsp://admin:hunter2@192.0.2.21:554/ISAPI/Streaming/channels/101")
        configuration.cameras[0].subStreamURL = URL(string: "rtsp://viewer@192.0.2.21:554/ISAPI/Streaming/channels/102")
        try store.save(configuration)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("hunter2") && !text.contains("viewer@"))
        let loaded = try #require(try store.load())
        #expect(loaded.cameras[0].mainStreamURL?.absoluteString == "rtsp://192.0.2.21:554/ISAPI/Streaming/channels/101")
        #expect(loaded.cameras[0].subStreamURL?.absoluteString == "rtsp://192.0.2.21:554/ISAPI/Streaming/channels/102")
    }

    @Test func newerFilesAreRejectedAndNeverOverwritten() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        let newer = Data(#"{"schemaVersion": 7, "settings": {}, "cameras": [], "future": true}"#.utf8)
        try newer.write(to: store.fileURL)
        #expect(throws: ConfigurationStoreError.unsupportedSchemaVersion(7)) { _ = try store.load() }
        #expect(throws: ConfigurationStoreError.unsupportedSchemaVersion(7)) { _ = try store.loadOrRecover() }
        #expect(throws: ConfigurationStoreError.unsupportedSchemaVersion(7)) { try store.save(BridgeConfiguration()) }
        #expect(try Data(contentsOf: store.fileURL) == newer)
    }

    @Test(arguments: ["not json", "[1, 2]", #"{"settings": {}, "cameras": []}"#, #"{"schemaVersion": "1"}"#,
                      #"{"schemaVersion": 1, "settings": 5, "cameras": []}"#,
                      #"{"schemaVersion": 1, "settings": {}, "cameras": 5}"#, #"{"schemaVersion": -1}"#])
    func malformedFilesAreCorrupt(_ text: String) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        try Data(text.utf8).write(to: store.fileURL)
        #expect {
            _ = try store.load()
        } throws: { error in
            if case ConfigurationStoreError.corrupt = error { return true }
            return false
        }
    }

    @Test func corruptFilesAreMovedAsideOnRecovery() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        try Data("{ truncated".utf8).write(to: store.fileURL)
        let (configuration, recoveredFrom) = try store.loadOrRecover()
        #expect(configuration.cameras.isEmpty)
        let backup = try #require(recoveredFrom)
        #expect(backup.lastPathComponent.hasPrefix("config.corrupt-") && backup.pathExtension == "json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ truncated")
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false)))
        // A missing file is not a recovery.
        let (fresh, none) = try store.loadOrRecover()
        #expect(fresh.cameras.isEmpty && none == nil)
    }

    @Test func missingFieldsTakeTheirDefaults() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        let id = UUID()
        let text = """
        {"schemaVersion": 1, "settings": {"basePort": 23000},
         "cameras": [{"id": "\(id.uuidString)", "name": "Porch", "kind": "camera", "vendor": "rtsp",
                      "endpoint": {"host": "192.0.2.9", "httpPort": 80, "rtspPort": 554, "useHTTPS": false},
                      "sensors": {"person": true}}]}
        """
        try Data(text.utf8).write(to: store.fileURL)
        let loaded = try #require(try store.load())
        #expect(loaded.settings.basePort == 23_000)
        #expect(loaded.settings.sensorsBridgePort == 21_099 && loaded.settings.webhookPort == 21_090 && !loaded.settings.webhookEnabled)
        #expect(loaded.settings.webhookToken.count == 32 && loaded.settings.webhookToken.allSatisfy(\.isHexDigit))
        let camera = try #require(loaded.cameras.first)
        let defaults = CameraConfiguration(id: id, name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.9"),
                                           username: "")
        var expected = defaults
        expected.sensors.person = true
        #expect(camera == expected)
    }

    @Test func duplicateCameraIDsKeepTheFirst() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        var configuration = sampleConfiguration()
        var copy = configuration.cameras[0]
        copy.name = "Copy"
        configuration.cameras.append(copy)
        try store.save(configuration)
        let loaded = try #require(try store.load())
        #expect(loaded.cameras.map(\.name) == ["Driveway", "Front Door"])
    }

    @Test func migrationHookUpgradesOlderFilesAndKeepsABackup() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // A hypothetical version 0 that called the list "cameraList" and had no settings.
        let migrations: [Int: ConfigurationMigration] = [
            0: { object in
                object["cameras"] = object.removeValue(forKey: "cameraList") ?? []
                object["settings"] = [String: Any]()
            },
        ]
        let store = ConfigurationStore(directory: directory.url, migrations: migrations)
        let id = UUID()
        let original = """
        {"schemaVersion": 0, "cameraList": [{"id": "\(id.uuidString)", "name": "Old", "kind": "doorbell", "vendor": "demo",
          "endpoint": {"host": "localhost", "httpPort": 80, "rtspPort": 554, "useHTTPS": false}}]}
        """
        try Data(original.utf8).write(to: store.fileURL)
        let loaded = try #require(try store.load())
        #expect(loaded.cameras.map(\.id) == [id] && loaded.cameras.first?.kind == .doorbell)
        // Rewritten in the current version, original kept next to it.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ConfigurationStore.currentSchemaVersion)
        let backup = directory.file("config.json.v0.bak")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(try posixPermissions(of: backup) == 0o600)
        #expect(try store.load() == loaded)

        // Without a migration for version 0 the file is unsupported (and left alone).
        try Data(original.utf8).write(to: store.fileURL)
        #expect(throws: ConfigurationStoreError.unsupportedSchemaVersion(0)) { _ = try ConfigurationStore(directory: directory.url).load() }
    }

    @Test func unreadableCameraEntriesAreSetAsideAndWrittenBack() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        let porch = UUID(), future = UUID(), garage = UUID()
        let endpoint = #"{"host": "192.0.2.9", "httpPort": 80, "rtspPort": 554, "useHTTPS": false}"#
        let text = """
        {"schemaVersion": 1, "settings": {"basePort": 23000},
         "cameras": [{"id": "\(porch.uuidString)", "name": "Porch", "kind": "camera", "vendor": "rtsp", "endpoint": \(endpoint)},
                     {"id": "\(future.uuidString)", "name": "Future", "kind": "camera", "vendor": "dahua", "endpoint": \(endpoint),
                      "hapPort": 21105},
                     {"name": "No id", "kind": "camera", "vendor": "rtsp", "endpoint": \(endpoint)},
                     5,
                     {"id": "\(garage.uuidString)", "name": "Garage", "kind": "floodlight", "vendor": "onvif", "endpoint": \(endpoint)}]}
        """
        try Data(text.utf8).write(to: store.fileURL)
        let loaded = try #require(try store.load(), "one unreadable camera does not make the whole file corrupt")
        #expect(loaded.cameras.map(\.id) == [porch])
        #expect(loaded.settings.basePort == 23_000)

        var changed = loaded
        changed.cameras[0].name = "Front Porch"
        try store.save(changed)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let entries = try #require(object["cameras"] as? [[String: Any]])
        #expect(entries.compactMap { $0["name"] as? String } == ["Front Porch", "Future", "No id", "Garage"], "kept, in file order")
        #expect(entries.first { $0["name"] as? String == "Future" }?["vendor"] as? String == "dahua")
        #expect(entries.first { $0["name"] as? String == "Future" }?["hapPort"] as? Int == 21_105, "kept unchanged")
        #expect(try posixPermissions(of: store.fileURL) == 0o600)

        // A fresh store (next launch) reads the same cameras and still keeps the others.
        let next = ConfigurationStore(directory: directory.url)
        #expect(try next.load()?.cameras.map(\.name) == ["Front Porch"])
        // A camera saved with an unreadable entry's id replaces that entry.
        var replacement = CameraConfiguration(id: future, name: "Future", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.9"),
                                              username: "")
        replacement.hapPort = 21_105
        try next.save(BridgeConfiguration(settings: changed.settings, cameras: changed.cameras + [replacement]))
        let final = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let names = (final["cameras"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["Front Porch", "Future", "No id", "Garage"])
        #expect(try ConfigurationStore(directory: directory.url).load()?.cameras.map(\.id) == [porch, future])
    }

    @Test func unreadableOptionalValuesTakeTheirDefaults() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        let id = UUID()
        let text = """
        {"schemaVersion": 1, "settings": {"logLevel": 42, "webhookPort": -1, "basePort": 23000, "webhookToken": "abc"},
         "cameras": [{"id": "\(id.uuidString)", "name": "Porch", "kind": "camera", "vendor": "rtsp",
                      "endpoint": {"host": "192.0.2.9", "httpPort": 80, "rtspPort": 554, "useHTTPS": false},
                      "motionSource": "radar", "hapPort": 70000, "motionHoldSeconds": 45, "mainStreamURL": 7,
                      "capabilities": {"events": ["motion", "smoke"]}, "username": "admin"}]}
        """
        try Data(text.utf8).write(to: store.fileURL)
        let loaded = try #require(try store.load())
        #expect(loaded.settings.logLevel == .info && loaded.settings.webhookPort == 21_090)
        #expect(loaded.settings.basePort == 23_000 && loaded.settings.webhookToken == "abc", "readable values are kept")
        let camera = try #require(loaded.cameras.first)
        #expect(camera.motionSource == .cameraEvents && camera.hapPort == 0 && camera.mainStreamURL == nil && camera.capabilities == nil)
        #expect(camera.motionHoldSeconds == 45 && camera.username == "admin")
    }

    /// docs/CONTRACT_CHANGES.md 2026-10-01: the new stream/quality fields are missing from a config written before they
    /// existed; decoding must still succeed and fall back to their `init` defaults.
    @Test func cameraConfigurationWithoutTheNewStreamFieldsDecodesToTheirDefaults() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        let id = UUID()
        let text = """
        {"schemaVersion": 1, "settings": {},
         "cameras": [{"id": "\(id.uuidString)", "name": "Backyard", "kind": "camera", "vendor": "rtsp",
                      "endpoint": {"host": "192.0.2.10", "httpPort": 80, "rtspPort": 554, "useHTTPS": false}, "username": "admin"}]}
        """
        try Data(text.utf8).write(to: store.fileURL)
        let loaded = try #require(try store.load())
        let camera = try #require(loaded.cameras.first)
        #expect(camera.liveStreamMode == .automatic)
        #expect(camera.liveQualityMode == .matchHomeKitRequest)
        #expect(camera.liveMaxBitrateOverride == .auto)
        #expect(camera.recordingStreamMode == .automatic)
        #expect(camera.recordingQualityMode == .matchHubRequest)
    }

    /// A value from a future build (a case this build does not know) falls back to its default rather than corrupting
    /// the whole camera entry.
    @Test func cameraConfigurationWithUnknownStreamEnumCasesFallsBackToDefaults() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url)
        let id = UUID()
        let text = """
        {"schemaVersion": 1, "settings": {},
         "cameras": [{"id": "\(id.uuidString)", "name": "Backyard", "kind": "camera", "vendor": "rtsp",
                      "endpoint": {"host": "192.0.2.10", "httpPort": 80, "rtspPort": 554, "useHTTPS": false}, "username": "admin",
                      "liveStreamMode": "fromTheFuture", "liveMaxBitrateOverride": "mbps99"}]}
        """
        try Data(text.utf8).write(to: store.fileURL)
        let loaded = try #require(try store.load())
        let camera = try #require(loaded.cameras.first)
        #expect(camera.liveStreamMode == .automatic)
        #expect(camera.liveMaxBitrateOverride == .auto)
    }

    @Test func cameraConfigurationRoundTripsTheNewStreamFields() throws {
        var camera = CameraConfiguration(name: "Front", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.1"), username: "u")
        camera.liveStreamMode = .alwaysSub
        camera.liveQualityMode = .originalQuality
        camera.liveMaxBitrateOverride = .mbps4
        camera.recordingStreamMode = .sub
        camera.recordingQualityMode = .originalWhenPossible
        let data = try JSONEncoder().encode(camera)
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: data)
        #expect(decoded.liveStreamMode == .alwaysSub && decoded.liveQualityMode == .originalQuality)
        #expect(decoded.liveMaxBitrateOverride == .mbps4 && decoded.recordingStreamMode == .sub && decoded.recordingQualityMode == .originalWhenPossible)
    }

    @Test func preferredConfigMethodRoundTripsDefaultsToNilAndIgnoresUnknownValues() throws {
        var camera = CameraConfiguration(name: "Front", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.1"), username: "u")
        #expect(camera.preferredConfigMethod == nil)
        camera.preferredConfigMethod = .hikvisionISAPI
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: try JSONEncoder().encode(camera))
        #expect(decoded.preferredConfigMethod == .hikvisionISAPI)

        // Written by an older build: no key. By a newer build: a method this one does not know.
        func decode(_ extra: String) throws -> CameraConfiguration {
            let text = """
            {"id": "\(UUID().uuidString)", "name": "Back", "kind": "camera", "vendor": "hikvision",
             "endpoint": {"host": "192.0.2.10", "httpPort": 80, "rtspPort": 554, "useHTTPS": false}, "username": "admin"\(extra)}
            """
            return try JSONDecoder().decode(CameraConfiguration.self, from: Data(text.utf8))
        }
        #expect(try decode("").preferredConfigMethod == nil)
        #expect(try decode(#", "preferredConfigMethod": "quantumLink""#).preferredConfigMethod == nil)
        #expect(try decode(#", "preferredConfigMethod": "onvifMinimal""#).preferredConfigMethod == .onvifMinimal)
    }

    @Test func recoveryMovesAsideAFileWhoseMigrationFails() throws {
        struct Broken: Error {}
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url, migrations: [0: { _ in throw Broken() }])
        let original = Data(#"{"schemaVersion": 0, "cameraList": []}"#.utf8)
        try original.write(to: store.fileURL)
        let (configuration, recoveredFrom) = try store.loadOrRecover()
        #expect(configuration.cameras.isEmpty)
        let backup = try #require(recoveredFrom)
        #expect(backup.lastPathComponent.hasPrefix("config.corrupt-"))
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func saveRefusesOlderFilesWithoutAMigrationAndBacksUpMigratableOnes() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let original = Data(#"{"schemaVersion": 0, "cameraList": []}"#.utf8)
        try original.write(to: directory.file("config.json"))
        let plain = ConfigurationStore(directory: directory.url)
        #expect(throws: ConfigurationStoreError.unsupportedSchemaVersion(0)) { try plain.save(BridgeConfiguration()) }
        #expect(try Data(contentsOf: plain.fileURL) == original, "never overwritten")

        let migrating = ConfigurationStore(directory: directory.url, migrations: [0: { _ in }])
        try migrating.save(BridgeConfiguration())
        #expect(try Data(contentsOf: directory.file("config.json.v0.bak")) == original)
        #expect(try migrating.load() == BridgeConfiguration(settings: try #require(try migrating.load()).settings))
    }

    @Test func failingMigrationIsReportedAsCorrupt() throws {
        struct Broken: Error {}
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ConfigurationStore(directory: directory.url, migrations: [0: { _ in throw Broken() }])
        try Data(#"{"schemaVersion": 0}"#.utf8).write(to: store.fileURL)
        #expect {
            _ = try store.load()
        } throws: { error in
            if case ConfigurationStoreError.corrupt(let message) = error { return message.contains("version 0") }
            return false
        }
    }
}
