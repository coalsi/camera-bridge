import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing

@Suite struct ConfigurationBackupTests {
    private func camera(_ name: String, id: UUID = UUID(), enabled: Bool = true) -> CameraConfiguration {
        var camera = CameraConfiguration(id: id, name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.50"), username: "viewer")
        camera.mainStreamURL = URL(string: "rtsp://viewer:hunter2@192.0.2.50:554/main")
        camera.isEnabled = enabled
        camera.hapPort = 21_105
        return camera
    }

    @Test func aBackupHasNoPasswordsAndNoWebhookToken() throws {
        var settings = BridgeSettings()
        settings.webhookToken = "tokentokentokentokentoken0000"
        let backup = ConfigurationBackup(settings: settings, cameras: [camera("Porch")], appVersion: "1.0 (1)")
        let text = String(decoding: try backup.encoded(), as: UTF8.self)
        #expect(!text.contains("hunter2"), "user info is removed from stream addresses")
        #expect(!text.contains("tokentoken"), "the webhook token is a credential")
        #expect(!text.localizedCaseInsensitiveContains("webhookToken"))
        #expect(text.contains("\"kind\" : \"CameraBridgeBackup\""))
        #expect(backup.cameras[0].mainStreamURL?.absoluteString == "rtsp://192.0.2.50:554/main")
    }

    @Test func aBackupReadsBackAsWritten() throws {
        var settings = BridgeSettings()
        settings.keepMacAwake = true
        settings.logLevel = .debug
        settings.basePort = 22_000
        settings.sensorsBridgePort = 22_500
        let original = ConfigurationBackup(settings: settings, cameras: [camera("Porch"), camera("Garage")],
                                           exportedAt: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "1.0 (1)")
        let reading = try ConfigurationBackup.read(original.encoded())
        #expect(reading.unreadableCameras == 0)
        #expect(reading.backup == original)
    }

    @Test func otherFilesAreNotBackups() {
        #expect(throws: ConfigurationBackup.ReadError.notABackup) { try ConfigurationBackup.read(Data("hello".utf8)) }
        #expect(throws: ConfigurationBackup.ReadError.notABackup) { try ConfigurationBackup.read(Data(#"{"cameras": []}"#.utf8)) }
        // CameraBridge's own config.json isn't a backup either (it holds the token and has no kind).
        #expect(throws: ConfigurationBackup.ReadError.notABackup) {
            try ConfigurationBackup.read(Data(#"{"schemaVersion": 1, "settings": {}, "cameras": []}"#.utf8))
        }
        #expect(throws: ConfigurationBackup.ReadError.notABackup) {
            try ConfigurationBackup.read(Data(#"{"kind": "CameraBridgeBackup", "version": 1, "cameras": []}"#.utf8))
        }
    }

    @Test func aNewerBackupIsRefused() throws {
        let json = #"{"kind": "CameraBridgeBackup", "version": 2, "settings": {}, "cameras": []}"#
        #expect(throws: ConfigurationBackup.ReadError.newerVersion(2)) { try ConfigurationBackup.read(Data(json.utf8)) }
    }

    @Test func aCameraThisVersionCannotReadCostsThatCameraOnly() throws {
        let good = try ConfigurationBackup(settings: BridgeSettings(), cameras: [camera("Porch")]).encoded()
        var object = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        var cameras = try #require(object["cameras"] as? [Any])
        cameras.append(["id": UUID().uuidString, "name": "From the future", "vendor": "notAVendor"])
        cameras.append("not even an object")
        object["cameras"] = cameras
        let reading = try ConfigurationBackup.read(JSONSerialization.data(withJSONObject: object))
        #expect(reading.backup.cameras.map(\.name) == ["Porch"])
        #expect(reading.unreadableCameras == 2)
    }

    @Test func aCameraListedTwiceIsImportedOnce() throws {
        let id = UUID()
        let backup = ConfigurationBackup(settings: BridgeSettings(), cameras: [camera("First", id: id), camera("Second", id: id)])
        #expect(try ConfigurationBackup.read(backup.encoded()).backup.cameras.map(\.name) == ["First"])
    }

    @Test func importingAddsOnlyCamerasThatAreNotSetUpAndTurnsThemOff() {
        let known = camera("Porch")
        let backup = ConfigurationBackup(settings: BridgeSettings(), cameras: [known, camera("Garage"), camera("Doorbell", enabled: false)])
        let plan = backup.plan(existing: [known], unreadableCameras: 1)
        #expect(plan.camerasToAdd.map(\.name) == ["Garage", "Doorbell"])
        #expect(plan.camerasToAdd.allSatisfy { !$0.isEnabled }, "no password yet: signing in with nothing would lock the camera's account")
        #expect(plan.alreadySetUp == ["Porch"])
        #expect(plan.unreadableCameras == 1)
        #expect(!plan.isEmpty)
        #expect(backup.plan(existing: backup.cameras).isEmpty)
    }

    @Test func settingsAreRestoredWithoutTouchingTheToken() {
        var saved = BridgeSettings()
        saved.keepMacAwake = true
        saved.logLevel = .error
        saved.webhookEnabled = true
        saved.webhookPort = 23_000
        saved.sensorsBridgePort = 23_001
        saved.basePort = 23_100
        var current = BridgeSettings()
        current.webhookToken = "keepthistokenkeepthistoken00"
        ConfigurationBackup.Settings(saved).applied(to: &current)
        #expect(current.keepMacAwake && current.webhookEnabled)
        #expect(current.logLevel == .error)
        #expect(current.webhookPort == 23_000 && current.sensorsBridgePort == 23_001 && current.basePort == 23_100)
        #expect(current.webhookToken == "keepthistokenkeepthistoken00")
    }

    @Test func fileNamesAreSortableAndHaveOurExtension() {
        let name = ConfigurationBackup.fileName(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(name.hasPrefix("CameraBridge-Backup-20"))
        #expect(name.hasSuffix(".camerabridge-backup"))
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct ConfigurationImportTests {
    private func camera(_ name: String) -> CameraConfiguration {
        CameraConfiguration(name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.60"), username: "viewer")
    }

    @Test func importingAddsTheCamerasTurnedOffAndRestoresSettingsKeepingTheToken() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        // The first save loads (and creates) the configuration; its token is the one the import must keep.
        #expect(await fixture.model.updateSettings { $0.logLevel = .notice })
        let token = fixture.engine.settings.webhookToken
        var settings = BridgeSettings()
        settings.keepMacAwake = false
        settings.logLevel = .warning
        settings.webhookPort = 0
        settings.sensorsBridgePort = 0
        let backup = ConfigurationBackup(settings: settings, cameras: [camera("Porch"), camera("Garage")])
        let plan = backup.plan(existing: fixture.engine.configurations)

        let outcome = await fixture.model.applyImport(plan, restoreSettings: true)

        #expect(outcome.added == ["Porch", "Garage"])
        #expect(!outcome.hasFailures)
        #expect(outcome.restoredSettings)
        #expect(fixture.engine.configurations.map(\.name) == ["Porch", "Garage"])
        #expect(fixture.engine.configurations.allSatisfy { !$0.isEnabled })
        #expect(fixture.engine.settings.logLevel == .warning)
        #expect(fixture.engine.settings.webhookToken == token)
        await fixture.tearDown()
    }

    @Test func aCameraAddedMeanwhileIsLeftAlone() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        let porch = camera("Porch")
        try await fixture.engine.addCamera(porch, password: nil)
        var imported = porch
        imported.name = "Renamed in the backup"
        let plan = ConfigurationBackup.ImportPlan(camerasToAdd: [imported], alreadySetUp: [], unreadableCameras: 0,
                                                  settings: ConfigurationBackup.Settings(BridgeSettings()))

        let outcome = await fixture.model.applyImport(plan, restoreSettings: false)

        #expect(outcome.added.isEmpty && outcome.skippedExisting == 1)
        #expect(fixture.engine.configurations.map(\.name) == ["Porch"])
        #expect(!outcome.restoredSettings)
        await fixture.tearDown()
    }

    @Test func previewModeImportsNothing() async {
        let model = AppModel.preview()
        let before = model.engine.configurations
        let plan = ConfigurationBackup(settings: BridgeSettings(), cameras: [camera("Porch")]).plan(existing: before)
        let outcome = await model.applyImport(plan, restoreSettings: true)
        #expect(outcome.added.isEmpty && !outcome.restoredSettings)
        #expect(model.engine.configurations == before)
    }

    @Test func theBackupModelShowsThePlanFirstAndAppliesItOnConfirmation() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        let backup = ConfigurationBackup(settings: BridgeSettings(), cameras: [camera("Porch")])
        let model = BackupModel()

        try model.prepare(backup.encoded(), for: fixture.model)
        let pending = try #require(model.pending)
        #expect(pending.plan.camerasToAdd.map(\.name) == ["Porch"])
        #expect(fixture.engine.configurations.isEmpty, "nothing changes before the person confirms")

        await model.confirmImport(pending, for: fixture.model, restoreSettings: false)
        #expect(model.pending == nil)
        #expect(fixture.engine.configurations.map(\.name) == ["Porch"])
        #expect(model.status?.isError == false)
        #expect(model.status?.text.contains("Added 1 camera") == true)
        await fixture.tearDown()
    }

    @Test func aFileThatIsNotABackupIsReportedAndChangesNothing() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        let model = BackupModel()
        #expect(throws: ConfigurationBackup.ReadError.notABackup) { try model.prepare(Data("nope".utf8), for: fixture.model) }
        #expect(model.pending == nil)
        await fixture.tearDown()
    }

    @Test func theOutcomeSummaryNamesWhatHappened() {
        var outcome = ImportOutcome(skippedExisting: 1)
        outcome.added = ["Porch", "Garage"]
        outcome.restoredSettings = true
        #expect(outcome.summary == "Added 2 cameras, turned off until you enter their passwords. 1 camera was already set up. Settings restored.")
        outcome.failed = [("Gate", "no")]
        #expect(outcome.hasFailures)
        #expect(outcome.summary.contains("Couldn’t add Gate."))
    }
}
