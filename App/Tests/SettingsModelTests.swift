import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing

@Suite struct SettingsTabTests {
    @Test func everyTabHasAUniqueStableIdentity() {
        #expect(SettingsTab.allCases.map(\.rawValue) == ["general", "homeKit", "network", "webhook", "privacy", "diagnostics", "backup", "about"])
        #expect(Set(SettingsTab.allCases.map(\.symbol)).count == SettingsTab.allCases.count)
        #expect(SettingsTab(rawValue: "removedTab") == nil, "an unknown stored tab falls back to the default")
        #expect(SettingsTab.storageKey == "settingsTab")
    }
}

@Suite struct NetworkSettingsTests {
    @Test func sensorsBridgePortValidation() {
        var settings = BridgeSettings()
        settings.webhookPort = 21_090
        let cameraPorts: [UInt16] = [21_100, 21_101]
        func check(_ text: String) -> WebhookSettings.PortValidation {
            NetworkSettings.validatePort(text, for: .sensorsBridge, settings: settings, cameraPorts: cameraPorts)
        }
        #expect(check("21099") == .valid(21_099))
        #expect(check(" 30000 ") == .valid(30_000))
        #expect(check("80") == .invalid("Use a port from 1024 to 65535."))
        #expect(check("65536") == .invalid("Use a port from 1024 to 65535."))
        #expect(check("") == .invalid("Use a port from 1024 to 65535."))
        #expect(check("21090") == .invalid("Port 21090 is used by the webhook."))
        #expect(check("21101") == .invalid("Port 21101 is used by a camera."))
    }

    @Test func firstCameraPortOnlyNeedsToBeInRange() {
        let settings = BridgeSettings()   // webhook 21090, sensors bridge 21099
        func check(_ text: String) -> WebhookSettings.PortValidation {
            NetworkSettings.validatePort(text, for: .firstCameraPort, settings: settings, cameraPorts: [21_100])
        }
        #expect(check("21100") == .valid(21_100), "cameras that have a port keep it; the allocator skips used ones")
        #expect(check("21099") == .valid(21_099))
        #expect(check("1023") == .invalid("Use a port from 1024 to 65535."))
        #expect(check("x") == .invalid("Use a port from 1024 to 65535."))
    }

    @Test func onlyEthernetAndWiFiAddressesAreShown() {
        #expect(NetworkSettings.isShown(interface: "en0", address: "192.0.2.10"))
        #expect(NetworkSettings.isShown(interface: "en12", address: "10.0.0.4"))
        #expect(!NetworkSettings.isShown(interface: "lo0", address: "127.0.0.1"))
        #expect(!NetworkSettings.isShown(interface: "en0", address: "169.254.20.3"), "link-local")
        #expect(!NetworkSettings.isShown(interface: "utun4", address: "100.64.0.2"))
        #expect(!NetworkSettings.isShown(interface: "bridge100", address: "192.168.64.1"))
        #expect(!NetworkSettings.isShown(interface: "awdl0", address: "192.0.2.9"))
        #expect(!NetworkSettings.isShown(interface: "en", address: "192.0.2.9"))
    }

    @Test func readingTheAddressesNeverShowsLoopback() {
        let addresses = NetworkSettings.ipv4Addresses()
        #expect(addresses.allSatisfy { NetworkSettings.isShown(interface: $0.interface, address: $0.address) })
        #expect(Set(addresses.map(\.id)).count == addresses.count)
    }
}

@Suite struct SettingsTextTests {
    private func camera(_ name: String, enabled: Bool = true, port: UInt16 = 0) -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.70"), username: "")
        camera.isEnabled = enabled
        camera.hapPort = port
        return camera
    }

    private func status(_ camera: CameraConfiguration, paired: Bool, port: UInt16?) -> CameraStatus {
        CameraStatus(id: camera.id, name: camera.name, kind: camera.kind, vendor: camera.vendor, isPaired: paired, hapPort: port)
    }

    @Test func cameraCount() {
        #expect(SettingsText.cameraCount([]) == "No cameras yet")
        #expect(SettingsText.cameraCount([camera("A")]) == "1 camera")
        #expect(SettingsText.cameraCount([camera("A"), camera("B", enabled: false)]) == "2 cameras · 1 turned off")
        #expect(SettingsText.cameraCount([camera("A", enabled: false)]) == "1 camera · 1 turned off")
    }

    @Test func accessorySubtitles() {
        let porch = camera("Porch", port: 21_105)
        #expect(SettingsText.accessorySubtitle(for: porch, status: status(porch, paired: true, port: 21_100)) == "Added to Apple Home · Port 21100",
                "the running port wins over the saved one")
        #expect(SettingsText.accessorySubtitle(for: porch, status: status(porch, paired: false, port: nil)) == "Not added yet · Port 21105")
        #expect(SettingsText.accessorySubtitle(for: porch, status: nil) == "Not added yet · Port 21105")
        #expect(SettingsText.accessorySubtitle(for: camera("New"), status: nil) == "Not added yet", "no port allocated yet")
        #expect(SettingsText.accessorySubtitle(for: camera("Off", enabled: false, port: 21_106), status: nil) == "Turned off")
    }

    @Test func sensorsBridgeSubtitles() {
        #expect(SettingsText.sensorsBridgeSubtitle(nil) == "Starts with the first camera")
        #expect(SettingsText.sensorsBridgeSubtitle(SensorsBridgeStatus(isPaired: true, setupCode: "", setupURI: "", accessoryCount: 4))
                == "Added to Apple Home · 4 sensors")
        #expect(SettingsText.sensorsBridgeSubtitle(SensorsBridgeStatus(isPaired: false, setupCode: "", setupURI: "", accessoryCount: 1))
                == "Not added yet · 1 sensor")
    }

    @Test func webhookStatus() {
        #expect(SettingsText.webhookStatus(enabled: false, state: .running, problem: nil, port: 21_090) == "Off")
        #expect(SettingsText.webhookStatus(enabled: true, state: .running, problem: nil, port: 21_090) == "Listening on port 21090")
        #expect(SettingsText.webhookStatus(enabled: true, state: .running, problem: "port taken", port: 21_090) == "Not listening")
        #expect(SettingsText.webhookStatus(enabled: true, state: .paused, problem: nil, port: 21_090) == "Paused with the bridge")
        #expect(SettingsText.webhookStatus(enabled: true, state: .stopped, problem: nil, port: 21_090) == "Not listening")
    }

    @Test func profileTexts() {
        let downloaded = CameraProfileService.Status(version: "3", profileCount: 12, updated: nil, isDownloaded: true, lastCheck: nil)
        #expect(SettingsText.profileSummary(downloaded) == "Version 3 · 12 camera profiles")
        #expect(SettingsText.profileSummary(CameraProfileService.Status(version: "0", profileCount: 1, updated: nil, isDownloaded: false, lastCheck: nil))
                == "Version 0 · 1 camera profile")
        #expect(SettingsText.profileSource(downloaded) == "Downloaded from the Camera Bridge website")
        #expect(SettingsText.profileSource(CameraProfileService.Status(version: "0", profileCount: 0, updated: nil, isDownloaded: false, lastCheck: nil))
                == "Built into this version of Camera Bridge")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SettingsText.lastChecked(nil, now: now) == "Never")
        #expect(SettingsText.lastChecked(now.addingTimeInterval(-20), now: now) == "Just now")
        #expect(!SettingsText.lastChecked(now.addingTimeInterval(-7_200), now: now).isEmpty)
        #expect(SettingsText.checkResult(.upToDate) == ("You have the latest camera profiles.", false))
        #expect(SettingsText.checkResult(.failed).isProblem)
        #expect(SettingsText.checkResult(.updated(CameraProfileFeed(version: "5", updated: nil, profiles: []))).text == "Updated to version 5.")
    }

    @Test func dataFolderIsShownRelativeToTheAccountsHome() {
        let home = "/Users/someone"
        #expect(SettingsText.displayPath(URL(filePath: "/Users/someone/Library/Application Support/CameraBridge"), home: home)
                == "~/Library/Application Support/CameraBridge")
        #expect(SettingsText.displayPath(URL(filePath: "/Users/someoneelse/Library"), home: home) == "/Users/someoneelse/Library")
        #expect(SettingsText.displayPath(URL(filePath: "/tmp/x"), home: "") == "/tmp/x")
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct SettingsModelActionTests {
    @Test func checkNowAsksTheServerWhateverTheLastCheckAndTellsTheEngine() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsProfiles-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = Box(0)
        let body = Data(#"{"version": 7, "profiles": []}"#.utf8)
        let service = CameraProfileService(directory: directory, bundle: Bundle(for: FakeSetupService.self), fetch: { request in
            requests.value += 1
            return (body, HTTPURLResponse(url: request.url ?? CameraBridgeService.baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let scratch = ScratchDefaults()
        let model = AppModel(options: LaunchOptions(), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(), defaults: scratch.defaults,
                             profileService: service)
        model.refreshCameraProfileStatus()
        #expect(model.cameraProfileStatus?.lastCheck == nil)
        #expect(model.cameraProfileStatus?.isDownloaded == false)

        await model.checkCameraProfilesNow()
        #expect(requests.value == 1)
        #expect(model.cameraProfileCheckResult == .updated(CameraProfileFeed(version: "7", updated: nil, profiles: [])))
        #expect(model.cameraProfileStatus?.version == "7" && model.cameraProfileStatus?.isDownloaded == true)
        #expect(model.cameraProfileStatus?.lastCheck != nil)
        #expect(!model.isCheckingCameraProfiles)

        // Checked a moment ago: the automatic refresh isn't due, Check Now still asks.
        await model.checkCameraProfilesNow()
        #expect(requests.value == 2)
    }

    @Test func checkNowDoesNothingInPreviewMode() async {
        let requests = Box(0)
        let service = CameraProfileService(directory: FileManager.default.temporaryDirectory.appending(path: "SettingsProfiles-\(UUID().uuidString)"),
                                           fetch: { _ in
                                               requests.value += 1
                                               throw URLError(.notConnectedToInternet)
                                           })
        let scratch = ScratchDefaults()
        let model = AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                             defaults: scratch.defaults, profileService: service)
        await model.checkCameraProfilesNow()
        #expect(requests.value == 0)
        #expect(model.cameraProfileCheckResult == nil)
        #expect(model.notice != nil)
    }

    @Test func revealingAFolderThatDoesNotExistExplainsWhy() {
        let scratch = ScratchDefaults()
        let missing = FileManager.default.temporaryDirectory.appending(path: "NoSuchData-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = AppModel(options: LaunchOptions(), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(), defaults: scratch.defaults,
                             dataDirectory: missing)
        model.windowOpener = {}
        model.revealDataFolder()
        #expect(model.message?.title == "Couldn’t Show the Data Folder")
        #expect(model.message?.detail.contains("hasn’t saved anything yet") == true)
    }

    @Test func portChangesGoThroughTheEngineSettings() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        #expect(await fixture.model.updateSettings { $0.basePort = 23_400 })
        #expect(await fixture.model.updateSettings { $0.sensorsBridgePort = 23_401 })
        #expect(fixture.engine.settings.basePort == 23_400)
        #expect(fixture.engine.settings.sensorsBridgePort == 23_401)
        await fixture.tearDown()
    }
}
