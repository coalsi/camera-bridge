import BridgeEngine
import BridgeSupport
import CameraAdapters
import RTSP
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct AppModelTests {
    private func model(preview: Bool, showsOnboarding: Bool = false, defaults: UserDefaults,
                       loginItems: InMemoryLoginItemService = InMemoryLoginItemService(), engine: BridgeEngine = BridgeEngine.preview(),
                       writeSettings: AppModel.SettingsWriter? = nil) -> AppModel {
        AppModel(options: LaunchOptions(usesPreviewEngine: preview, showsOnboarding: showsOnboarding), engine: engine,
                 loginItems: loginItems, defaults: defaults, previewLatency: .zero, writeSettings: writeSettings)
    }

    @Test func launchArgumentSelectsThePreviewEngineAndInMemoryLoginItem() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(true, forKey: "previewEngine")
        let model = AppModel.launching(defaults: scratch.defaults)
        #expect(model.isPreview)
        #expect(model.engine.cameras.count == 5)
        #expect(model.loginItemsAreSimulated)
    }

    @Test func previewModeLeavesTheSampleEngineUntouched() async {
        let scratch = ScratchDefaults()
        let model = model(preview: true, defaults: scratch.defaults)
        await model.toggleBridgeRunning()
        #expect(model.engine.state == .running)
        #expect(model.notice?.contains("Preview") == true)
        await model.setKeepMacAwake(true)
        #expect(!model.engine.settings.keepMacAwake)
        await model.removeCamera(id: PreviewSample.firstCameraID(in: model.engine))
        #expect(model.engine.cameras.count == 5)
        #expect(model.message == nil)
    }

    @Test func previewModeAnswersDiscoveryAndProbeFromFixtures() async throws {
        let scratch = ScratchDefaults()
        let model = model(preview: true, defaults: scratch.defaults)
        let found = await model.discoverCameras()
        #expect(!found.isEmpty && found.allSatisfy { $0.host.hasPrefix("192.0.2.") })
        let result = try await model.probeCamera(vendor: .reolink, endpoint: CameraEndpoint(host: "192.0.2.22"), username: "admin",
                                                 password: "pw", mainStreamURL: nil, subStreamURL: nil)
        #expect(result.vendor == .reolink && result.capabilities.isDoorbell)
        let auto = try await model.probeCamera(vendor: nil, endpoint: CameraEndpoint(host: "192.0.2.30"), username: "admin",
                                               password: "pw", mainStreamURL: nil, subStreamURL: nil)
        #expect(auto.vendor == .hikvision)
        let id = UUID()
        var config = CameraConfiguration(id: id, name: "Porch", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: "192.0.2.22"),
                                         username: "admin")
        config.capabilities = result.capabilities
        try await model.addCamera(config, password: "pw")
        let pairing = try #require(model.pairingCode(for: id))
        #expect(pairing.setupURI.hasPrefix("X-HM://") && pairing.setupCode.count == 10)
        #expect(model.engine.cameras.count == 5)
    }

    @Test func onboardingAppearsOnTheFirstLiveLaunchOnly() async {
        let scratch = ScratchDefaults()
        let first = model(preview: false, defaults: scratch.defaults)
        #expect(first.needsOnboarding && first.opensManagerAtLaunch)
        await first.completeOnboarding()
        #expect(!first.needsOnboarding && !first.isOnboardingPresented)
        #expect(!model(preview: false, defaults: scratch.defaults).needsOnboarding)

        let preview = model(preview: true, defaults: ScratchDefaults().defaults)
        #expect(!preview.needsOnboarding && !preview.opensManagerAtLaunch)
        #expect(model(preview: true, showsOnboarding: true, defaults: ScratchDefaults().defaults).needsOnboarding)
    }

    @Test func didFinishLaunchingPresentsOnboardingWhenNeeded() {
        let scratch = ScratchDefaults()
        let model = model(preview: true, showsOnboarding: true, defaults: scratch.defaults)
        model.didFinishLaunching()
        #expect(model.isOnboardingPresented)
    }

    @Test func showManagerSelectsTheDestinationAndOpensTheWindow() {
        let scratch = ScratchDefaults()
        let model = model(preview: true, defaults: scratch.defaults)
        var opened = 0
        model.windowOpener = { opened += 1 }
        model.showManager(selecting: .sensorsBridge)
        #expect(model.selection == .sensorsBridge && opened == 1)
        model.showManager()
        #expect(model.selection == .sensorsBridge && opened == 2)   // keeps the current destination
        model.showAddCamera()
        #expect(model.isAddCameraPresented && opened == 3)
    }

    @Test func showSettingsOpensTheSettingsWindowOnceTheOpenerExists() {
        let scratch = ScratchDefaults()
        let model = model(preview: true, defaults: scratch.defaults)
        var opened = 0
        model.showSettings()   // before the status item installed the opener
        model.settingsOpener = { opened += 1 }
        #expect(opened == 1)
        model.showSettings()
        #expect(opened == 2)
    }

    /// The status item installs the window opener after launch; an earlier request opens the window then.
    @Test func managerRequestedBeforeTheOpenerExistsOpensOnceInstalled() {
        let scratch = ScratchDefaults()
        let model = AppModel(options: LaunchOptions(usesPreviewEngine: true, opensManagerAtLaunch: true), engine: BridgeEngine.preview(),
                             loginItems: InMemoryLoginItemService(), defaults: scratch.defaults, previewLatency: .zero)
        model.didFinishLaunching()
        var opened = 0
        model.windowOpener = { opened += 1 }
        #expect(opened == 1)
        model.windowOpener = { opened += 1 }
        #expect(opened == 1)
    }

    @Test func managerOpensOnTheOverview() {
        let scratch = ScratchDefaults()
        let model = model(preview: true, defaults: scratch.defaults)
        model.windowOpener = {}
        #expect(model.defaultSelection == .overview)
        model.showManager()
        #expect(model.selection == .overview)
        // A page chosen before stays; showing a destination replaces it.
        model.selection = .camera(PreviewSample.firstCameraID(in: model.engine))
        model.showManager()
        #expect(model.selection == .camera(PreviewSample.firstCameraID(in: model.engine)))
    }

    @Test func theViewerOpensOnACameraAndTheCameraPageClosesIt() {
        let scratch = ScratchDefaults()
        let model = model(preview: true, defaults: scratch.defaults)
        let id = PreviewSample.firstCameraID(in: model.engine)
        model.selection = .overview
        model.expandCamera(id)
        #expect(model.expandedCameraID == id)
        model.openCameraPage(id)
        #expect(model.expandedCameraID == nil && model.selection == .camera(id))
        model.expandCamera(id)
        model.closeExpandedCamera()
        #expect(model.expandedCameraID == nil && model.selection == .camera(id))
    }

    @Test func launchAtLoginFollowsTheLoginItemService() {
        let scratch = ScratchDefaults()
        let service = InMemoryLoginItemService()
        let model = model(preview: false, defaults: scratch.defaults, loginItems: service)
        #expect(!model.launchAtLogin)
        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin && service.status == .enabled)
        model.setLaunchAtLogin(false)
        #expect(!model.launchAtLogin && service.status == .disabled)

        service.statusAfterRegister = .requiresApproval
        model.setLaunchAtLogin(true)
        #expect(model.loginItemStatus == .requiresApproval && model.launchAtLogin)
        #expect(service.openedSystemSettings == 1)

        service.status = .enabled   // changed in System Settings
        model.refreshLoginItemStatus()
        #expect(model.loginItemStatus == .enabled)
    }

    /// Review finding (W4 round 4): the menu's Launch at Login checkmark showed a status read when the app was last
    /// activated: opening a menu bar menu doesn't activate this agent app, so turning CameraBridge off in System Settings
    /// › General › Login Items left it checked. The status is read live.
    @Test func launchAtLoginReadsTheLiveStatus() {
        let scratch = ScratchDefaults()
        let service = InMemoryLoginItemService()
        service.status = .enabled
        let model = model(preview: false, defaults: scratch.defaults, loginItems: service)
        #expect(model.launchAtLogin)
        service.status = .disabled   // removed in System Settings, the app not activated since
        #expect(!model.launchAtLogin && model.loginItemStatus == .disabled)
        service.status = .requiresApproval
        #expect(model.launchAtLogin && model.loginItemStatus == .requiresApproval, "on, waiting for approval (the menu offers it)")
    }

    /// Review finding (W4 round 4): preview mode ran on the live app's defaults (same app, same domain), so Get Started
    /// there marked the live app's onboarding complete, and its next real first run skipped the welcome guide.
    @Test func previewModeKeepsItsOwnDefaults() async {
        let live = ScratchDefaults(), preview = ScratchDefaults()
        live.defaults.set(true, forKey: LaunchOptions.previewEngineKey)
        live.defaults.set(true, forKey: LaunchOptions.showOnboardingKey)
        let model = AppModel.launching(defaults: live.defaults, previewDefaults: preview.defaults)
        #expect(model.isPreview && model.needsOnboarding)
        await model.completeOnboarding()
        #expect(model.hasCompletedOnboarding, "remembered in preview mode's own defaults")
        #expect(live.defaults.object(forKey: AppModel.onboardingCompletedKey) == nil, "the live app's onboarding is untouched")
        let liveLaunch = AppModel(options: LaunchOptions(), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                                  defaults: live.defaults, previewLatency: .zero)
        #expect(liveLaunch.needsOnboarding, "the live app's first run still shows the welcome guide")
    }

    @Test func loginItemFailuresAreSurfaced() {
        let scratch = ScratchDefaults()
        let service = InMemoryLoginItemService()
        service.registerError = FakeError.unreachable
        let model = model(preview: false, defaults: scratch.defaults, loginItems: service)
        model.setLaunchAtLogin(true)
        #expect(!model.launchAtLogin)
        #expect(model.message?.title == "Couldn’t Change Launch at Login")
        #expect(model.message?.detail == "The camera didn't respond.")
    }

    /// Live mode sends the change to the engine, which applies it to its settings as they are when the change's turn
    /// comes (a change made while the engine is busy must not undo another).
    @Test func liveSettingsChangesReachTheEngine() async {
        let scratch = ScratchDefaults()
        let written = Box<[BridgeSettings]>([])
        let engine = BridgeEngine.preview()
        let model = model(preview: false, defaults: scratch.defaults, engine: engine, writeSettings: { change in
            var settings = engine.settings
            change(&settings)
            written.value.append(settings)
        })
        await model.setKeepMacAwake(true)
        #expect(written.value.count == 1 && written.value.first?.keepMacAwake == true)
        #expect(written.value.first?.webhookToken == model.engine.settings.webhookToken)   // everything else unchanged
        #expect(model.message == nil && model.notice == nil)
        #expect(await model.updateSettings { _ in } == true)                                // no change, no write
        #expect(written.value.count == 1)
    }

    @Test func liveSettingsFailuresAreShown() async {
        let scratch = ScratchDefaults()
        let model = model(preview: false, defaults: scratch.defaults, writeSettings: { _ in throw FakeError.unreachable })
        model.windowOpener = {}
        let applied = await model.updateSettings { $0.logLevel = .debug }
        #expect(!applied)
        #expect(model.message?.title == "Couldn’t Change Settings" && model.message?.detail == "The camera didn't respond.")
    }

    /// A menu bar action that fails while the manager window is closed opens it, so the alert is seen. Review finding
    /// (W4 App): one that fails while the window is open behind other apps brings it forward too — CameraBridge is an
    /// agent app that using its menu bar item doesn't activate, so the alert sat on a background window.
    @Test func failuresBringTheManagerForward() async {
        let scratch = ScratchDefaults()
        let service = InMemoryLoginItemService()
        service.registerError = FakeError.unreachable
        let model = model(preview: false, defaults: scratch.defaults, loginItems: service,
                          writeSettings: { _ in throw FakeError.unreachable })
        var opened = 0
        model.windowOpener = { opened += 1 }
        model.setLaunchAtLogin(true)
        #expect(opened == 1 && model.message?.title == "Couldn’t Change Launch at Login")

        model.managerWindowDidAppear()
        await model.setKeepMacAwake(true)
        #expect(opened == 2 && model.message?.title == "Couldn’t Change Settings", "open but maybe behind other apps: brought forward")

        model.managerWindowDidDisappear()
        #expect(model.message == nil)                // no stale alert the next time the window opens
        await model.setKeepMacAwake(true)
        #expect(opened == 3 && model.message != nil)
    }

    /// Review finding (W4 App): Fix… opened the whole welcome guide with the Local Network fix below the fold and "Get
    /// Started" as its only button. It opens a sheet with just the Local Network check and its fix; the guide says
    /// Done once onboarding is complete.
    @Test func fixingLocalNetworkAccessOpensItsOwnSheet() async {
        let scratch = ScratchDefaults()
        let model = model(preview: true, defaults: scratch.defaults)
        var opened = 0
        model.windowOpener = { opened += 1 }
        model.presentLocalNetworkFix()
        #expect(model.presentedSheet == .localNetworkAccess && opened == 1)
        model.presentedSheet = nil
        model.showAddCamera()
        model.presentLocalNetworkFix()
        #expect(model.presentedSheet == .addCamera, "one sheet at a time")

        #expect(OnboardingContent.dismissTitle(hasCompletedOnboarding: false) == "Get Started")
        #expect(OnboardingContent.dismissTitle(hasCompletedOnboarding: true) == "Done")
    }

    /// One sheet at a time: Add Camera… waits while onboarding is up (and the other way round).
    @Test func sheetsNeverStack() async {
        let scratch = ScratchDefaults()
        let model = model(preview: true, showsOnboarding: true, defaults: scratch.defaults)
        model.windowOpener = {}
        model.didFinishLaunching()
        #expect(model.presentedSheet == .onboarding && model.isOnboardingPresented)
        model.showAddCamera()
        #expect(model.presentedSheet == .onboarding && !model.isAddCameraPresented)
        await model.completeOnboarding()
        #expect(model.presentedSheet == nil)
        model.showAddCamera()
        #expect(model.presentedSheet == .addCamera)
        model.presentOnboarding()
        #expect(model.presentedSheet == .addCamera)
        model.isAddCameraPresented = false
        #expect(model.presentedSheet == nil)
    }

    @Test func cameraUpdatesReportWhetherTheyWereApplied() async {
        let scratch = ScratchDefaults()
        let preview = model(preview: true, defaults: scratch.defaults)
        let config = preview.engine.configurations[0]
        #expect(await preview.updateCamera(config) == false)          // preview mode: skipped with a notice
        #expect(preview.notice != nil)
        let live = model(preview: false, defaults: scratch.defaults)
        live.windowOpener = {}
        let applied = await live.updateCamera(config)
        #expect(applied == (live.message == nil))                     // false exactly when the engine's error is shown
        if !applied { #expect(live.message?.title == "Couldn’t Update “Driveway”") }
    }

    @Test func errorDescriptions() {
        #expect(AppModel.describe(TransportError.localNetworkDenied)
                == "Local Network access is denied. Allow Camera Bridge in System Settings › Privacy & Security › Local Network.")
        #expect(AppModel.describe(TransportError.addressInUse) == "Another app uses the port.")
        #expect(AppModel.describe(FakeError.unreachable) == "The camera didn't respond.")
        let cocoa = AppModel.describe(CocoaError(.fileNoSuchFile))
        #expect(!cocoa.isEmpty && !cocoa.contains("CocoaError"))
    }

    /// Every error the engine and the camera adapters throw reads as a sentence on screen (wizard pages, alerts), never
    /// as a Swift type or case name; an error nobody mapped says so plainly and leaves the case name to the log.
    @Test func errorsNeverShowSwiftNames() {
        #expect(AppModel.describe(CameraAdapterError.unauthorized) == "The camera rejected the user name or password.")
        #expect(AppModel.describe(RTSPError.unauthorized) == "The camera rejected the user name or password for its video stream.")
        // Review finding (W4 App): an HTTPS-only camera ended here with no hint at the port or HTTPS.
        #expect(AppModel.describe(EngineError.noCameraAPI(host: "192.0.2.20"))
                == "No Hikvision, Reolink or ONVIF interface answered at 192.0.2.20. Check the address and ports (turn on Use HTTPS if the camera only answers HTTPS), or go back and choose Camera Type › RTSP URL.")
        #expect(AppModel.describe(EngineError.invalidSettings("the webhook token must have at least 16 characters"))
                == "These settings can’t be used: the webhook token must have at least 16 characters.")
        #expect(AppModel.describe(ConfigurationStoreError.unsupportedSchemaVersion(2)).contains("newer version of Camera Bridge"))
        #expect(AppModel.describe(RTSPError.unsupportedCodec("MJPEG")).contains("MJPEG"))

        let errors: [any Error] = [
            CameraAdapterError.unauthorized, CameraAdapterError.httpStatus(503), CameraAdapterError.invalidResponse("deviceInfo"),
            CameraAdapterError.soapFault("ter:ActionNotSupported"), CameraAdapterError.apiError(command: "Login", code: 1),
            CameraAdapterError.unsupported("no media profile"),
            RTSPError.unauthorized, RTSPError.notFound, RTSPError.badStatus(454), RTSPError.protocolError("bad header"), RTSPError.timeout,
            RTSPError.noVideoTrack, RTSPError.unsupportedCodec("MJPEG"),
            EngineError.unknownCamera, EngineError.duplicateCamera, EngineError.cameraNotRunning,
            EngineError.invalidSettings("the webhook token must have at least 16 characters"), EngineError.configurationUnavailable("corrupt"),
            EngineError.noCameraAPI(host: "192.0.2.20"),
            ConfigurationStoreError.unsupportedSchemaVersion(2), ConfigurationStoreError.corrupt("not JSON"),
            HTTPClientError.notHTTPResponse, CredentialStoreError.undecodablePassword, PortAllocationError.noFreePort(startingAt: 21_100),
            CancellationError(),
            PlainTestError.notImplemented("BridgeEngine.addCamera"),
        ]
        for error in errors {
            let text = AppModel.describe(error)
            let typeName = String(describing: type(of: error))
            #expect(!text.isEmpty && !text.contains(typeName) && !text.contains("(\"") && text.hasSuffix("."), "\(typeName): \(text)")
        }
        #expect(AppModel.describe(PlainTestError.notImplemented("BridgeEngine.addCamera")) == ErrorText.unexpected)
        #expect(ErrorText.logDescription(PlainTestError.notImplemented("BridgeEngine.addCamera"))
                == "PlainTestError.notImplemented(\"BridgeEngine.addCamera\")")
        #expect(ErrorText.logDescription(CameraAdapterError.httpStatus(503)) == "CameraAdapterError.httpStatus(503)")
    }

    /// Error text is shown on screen (alerts, probe failures), so it gets the same redaction as the log.
    @Test func displayedErrorsNeverShowCredentials() {
        let url = AppModel.describe(DescribedError(text: "RTSP 401 Unauthorized for rtsp://admin:hunter2@192.0.2.21:554/Streaming/101"))
        #expect(!url.contains("hunter2") && url.contains("192.0.2.21:554/Streaming/101"))
        let query = AppModel.describe(TransportError.failed("GET http://192.0.2.22/api.cgi?cmd=Login&password=hunter2 failed"))
        #expect(!query.contains("hunter2") && !query.contains("http://"), "the platform's text stays in the log")
        let plain = AppModel.describe(PlainTestError.notImplemented("rtsp://viewer:hunter2@192.0.2.24/live"))
        #expect(!plain.contains("hunter2"))
    }

    /// Review finding (W4 round 4): `TransportError.failed` carries the platform's text, and the app showed it as it was
    /// ("POSIXErrorCode(rawValue: 64): Host is down"; "HTTP request failed (URLError -1003)" for a mistyped host name),
    /// while the engine and the stream status worded the same errors their own ways. The engine words them once
    /// (`BridgeEngine.readableReason`); the app makes a sentence of that and adds what to do.
    @Test func platformErrorTextNeverReachesTheScreen() {
        let networkError = "A network error occurred. Check the camera’s address and that it is on your network. The log in Settings has the details."
        for raw in ["POSIXErrorCode(rawValue: 64): Host is down", "HTTP request failed (URLError -1003)", "-65554: NoSuchRecord"] {
            #expect(AppModel.describe(TransportError.failed(raw)) == networkError, "\(raw)")
        }
        let errors: [any Error] = [TransportError.timedOut, TransportError.connectionRefused, TransportError.closed, TransportError.addressInUse,
                                   TransportError.localNetworkDenied, RTSPError.timeout, RTSPError.notFound, CameraAdapterError.unauthorized,
                                   CameraAdapterError.httpStatus(503), ConfigurationStoreError.corrupt("x"), PortAllocationError.noFreePort(startingAt: 21_100)]
        for error in errors {
            #expect(AppModel.describe(error).lowercased().hasPrefix(BridgeEngine.readableReason(error).lowercased()), "one wording: \(error)")
        }
        #expect(AppModel.describe(CameraAdapterError.httpStatus(503)) == "The camera answered with an error (HTTP 503). Check the camera type and ports.")
        #expect(AppModel.describe(RTSPError.timeout) == "The camera’s video stream didn’t answer in time.")
    }
}

enum PlainTestError: Error {
    case notImplemented(String)
}

struct DescribedError: LocalizedError {
    var text: String
    var errorDescription: String? { text }
}

enum PreviewSample {
    static func firstCameraID(in engine: BridgeEngine) -> UUID {
        engine.cameras.first?.id ?? UUID()
    }
}
