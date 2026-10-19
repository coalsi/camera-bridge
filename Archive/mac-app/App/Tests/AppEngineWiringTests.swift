import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Network
import Synchronization
import Testing

/// The app model over a real engine on `BridgeEnvironment.testing` in a temporary directory (loopback only, no Bonjour,
/// in-memory secrets, no power assertions). Without cameras the engine opens no listener and publishes nothing.
/// `transport` replaces the engine's network transport (Local Network tests: never touches the network).
final class LiveEngineFixture {
    let directory: URL
    let scratch = ScratchDefaults()
    let engine: BridgeEngine
    let model: AppModel
    /// Times the model asked for the manager window.
    private(set) var windowRequests = 0
    /// Times the model asked for the Settings window.
    private(set) var settingsRequests = 0
    private let lookups = Box(0)
    /// Times the model looked up the default gateway.
    var gatewayLookups: Int { lookups.value }

    init(onboardingCompleted: Bool = false, configuration: String? = nil, gateway: String? = nil, existingDirectory: URL? = nil,
         transport: (any NetworkTransport)? = nil, localNetworkAnswerWait: Duration = BridgeEngine.localNetworkAnswerWait,
         localNetworkRecheckInterval: Duration = .seconds(10)) throws {
        directory = existingDirectory ?? Self.makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let configuration { try Data(configuration.utf8).write(to: directory.appending(path: "config.json")) }
        if onboardingCompleted { scratch.defaults.set(true, forKey: AppModel.onboardingCompletedKey) }
        var environment = BridgeEnvironment.testing(directory: directory)
        if let transport { environment.platform.transport = transport }
        engine = BridgeEngine(environment: environment)
        let lookups = lookups
        model = AppModel(options: LaunchOptions(), engine: engine, loginItems: InMemoryLoginItemService(), defaults: scratch.defaults,
                         previewLatency: .zero, gatewayAddress: {
                             lookups.value += 1
                             return gateway
                         }, localNetworkAnswerWait: localNetworkAnswerWait, localNetworkRecheckInterval: localNetworkRecheckInterval)
        model.windowOpener = { [unowned self] in windowRequests += 1 }
        model.settingsOpener = { [unowned self] in settingsRequests += 1 }
    }

    /// A fixture whose configuration already has `cameras` (saved by another engine that never starts, with ports away
    /// from other services).
    static func withCameras(_ cameras: [CameraConfiguration], onboardingCompleted: Bool, gateway: String? = nil,
                            transport: (any NetworkTransport)? = nil, localNetworkAnswerWait: Duration = BridgeEngine.localNetworkAnswerWait,
                            localNetworkRecheckInterval: Duration = .seconds(10)) async throws -> LiveEngineFixture {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seed = BridgeEngine(environment: .testing(directory: directory))
        var settings = seed.settings
        settings.basePort = UInt16.random(in: 22_000...28_000)   // away from Scrypted, Homebridge and the ephemeral range
        settings.sensorsBridgePort = 0
        settings.webhookPort = 0
        try await seed.updateSettings(settings)
        for camera in cameras { try await seed.addCamera(camera, password: nil) }
        return try LiveEngineFixture(onboardingCompleted: onboardingCompleted, gateway: gateway, existingDirectory: directory, transport: transport,
                                     localNetworkAnswerWait: localNetworkAnswerWait, localNetworkRecheckInterval: localNetworkRecheckInterval)
    }

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CameraBridgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A camera that is configured but never connects (disabled, documentation address).
    static func disabledCamera(_ name: String = "Gate") -> CameraConfiguration {
        var camera = CameraConfiguration(name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.40"), username: "")
        camera.isEnabled = false
        return camera
    }

    func tearDown() async {
        await model.prepareToTerminate()
        await engine.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForLog(_ message: String) async -> Bool {
        await eventually { self.engine.recentLogs.contains { $0.message == message } }
        return engine.recentLogs.contains { $0.message == message }
    }
}

/// Connections answer `.localNetworkDenied` (what macOS does while its Local Network alert waits for the person, and
/// after a denial) until `allow()`, then are refused (the host answered: access granted) — except `unreachableHosts`,
/// which then time out (a camera that is unplugged). Counts attempts; never touches the network.
nonisolated final class LocalNetworkGate: NetworkTransport {
    private let state = Mutex((allowed: false, deniedFirst: Int?.none, attempts: 0, hosts: [String]()))
    private let unreachableHosts: Set<String>

    /// `deniedAttempts`: allow by itself after that many denied attempts (the person clicks Allow while the alert is up).
    init(allowAfter deniedAttempts: Int? = nil, unreachableHosts: Set<String> = []) {
        self.unreachableHosts = unreachableHosts
        state.withLock { $0.deniedFirst = deniedAttempts }
    }

    var attempts: Int { state.withLock { $0.attempts } }
    /// The host of every attempt, in order.
    var hosts: [String] { state.withLock { $0.hosts } }

    func allow() { state.withLock { $0.allowed = true } }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        throw TransportError.failed("not used by these tests")
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        let allowed = state.withLock { state -> Bool in
            state.attempts += 1
            state.hosts.append(host)
            if let limit = state.deniedFirst, state.attempts > limit { state.allowed = true }
            return state.allowed
        }
        guard allowed else { throw TransportError.localNetworkDenied }
        throw unreachableHosts.contains(host) ? TransportError.timedOut : TransportError.connectionRefused
    }
}

/// The testing environment's transport, except that `taken` can't be listened on (another app holds it).
nonisolated final class PortTakenTransport: NetworkTransport {
    private let inner: any NetworkTransport
    private let taken: UInt16

    init(inner: any NetworkTransport, taken: UInt16) {
        self.inner = inner
        self.taken = taken
    }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        if port == taken { throw TransportError.addressInUse }
        return try await inner.listen(port: port, loopbackOnly: loopbackOnly)
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        try await inner.connect(host: host, port: port, timeout: timeout)
    }
}

/// What the live app does at launch, from the menu, on wake and at quit (plan W3-3), against a real engine.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AppEngineWiringTests {
    /// The engine starts at launch even on the first run: without cameras it publishes nothing, and adding a camera
    /// waits for onboarding (the sheets never stack).
    @Test func firstLaunchStartsTheEngineBehindOnboarding() async throws {
        let fixture = try LiveEngineFixture()
        let model = fixture.model, engine = fixture.engine
        model.didFinishLaunching()
        #expect(model.presentedSheet == .onboarding && fixture.windowRequests == 1)
        await eventually { engine.state == .running }
        #expect(engine.state == .running)
        #expect(await fixture.waitForLog("Bridge running with 0 cameras"))
        #expect(engine.sensorsBridge == nil, "nothing is published before the first camera")
        #expect(model.bridgeIssue == nil)
        model.showAddCamera()
        #expect(model.presentedSheet == .onboarding, "cameras are added after onboarding")

        await model.completeOnboarding()
        #expect(model.hasCompletedOnboarding && model.presentedSheet == nil && engine.state == .running)
        await fixture.tearDown()
    }

    @Test func laterLaunchesStartInTheMenuBarOnly() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        fixture.model.didFinishLaunching()
        #expect(fixture.model.presentedSheet == nil && fixture.windowRequests == 0)
        await eventually { fixture.engine.state == .running }
        #expect(fixture.engine.state == .running)
        await fixture.tearDown()
    }

    /// `-showOnboarding YES` shows the guide again without holding the bridge back.
    @Test func showingOnboardingAgainKeepsTheBridgeRunning() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        let model = AppModel(options: LaunchOptions(showsOnboarding: true), engine: fixture.engine, loginItems: InMemoryLoginItemService(),
                             defaults: fixture.scratch.defaults, previewLatency: .zero, gatewayAddress: { nil })
        model.windowOpener = {}
        model.didFinishLaunching()
        #expect(model.presentedSheet == .onboarding)
        await eventually { fixture.engine.state == .running }
        #expect(fixture.engine.state == .running)
        await fixture.tearDown()
    }

    @Test func pauseResumeStartAndQuit() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        let model = fixture.model, engine = fixture.engine
        await engine.start()
        await model.toggleBridgeRunning()
        #expect(engine.state == .paused && StatusText.pauseResumeTitle(engine.state) == "Resume Bridge")
        await model.toggleBridgeRunning()
        #expect(engine.state == .running)
        await model.prepareToTerminate()
        #expect(engine.state == .stopped)
        await model.toggleBridgeRunning()   // "Start Bridge"
        #expect(engine.state == .running)
        await fixture.tearDown()
    }

    @Test func wakeReachesTheEngine() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        await fixture.engine.start()
        await fixture.model.systemDidWake()
        #expect(await fixture.waitForLog("The Mac woke up; reconnecting cameras"))
        await fixture.tearDown()
    }

    @Test func keepMacAwakeIsSavedByTheEngine() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        await fixture.model.setKeepMacAwake(true)
        #expect(fixture.model.keepMacAwake && fixture.model.message == nil)
        #expect(BridgeEngine(environment: .testing(directory: fixture.directory)).settings.keepMacAwake, "persisted in config.json")
        await fixture.model.setKeepMacAwake(false)
        #expect(!fixture.model.keepMacAwake)
        await fixture.tearDown()
    }

    /// A configuration from a newer version stops the bridge from starting: the manager shows why, with Try Again.
    @Test func aBridgeThatCannotStartIsSurfaced() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true, configuration: #"{"schemaVersion": 99, "settings": {}, "cameras": []}"#)
        let model = fixture.model, engine = fixture.engine
        model.didFinishLaunching()
        await eventually { model.bridgeIssue != nil }
        guard case .startFailed(let reason)? = model.bridgeIssue else {
            Issue.record("expected a start failure, got \(String(describing: model.bridgeIssue)) in state \(engine.state)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(model.bridgeIssue?.title == "The Bridge Couldn’t Start" && model.bridgeIssue?.actionTitle == "Try Again")
        #expect(StatusText.menuHeader(engine.state).hasPrefix("Camera Bridge — Error — "))
        // Review finding (W4 round 2): the banner, menu header and VoiceOver label read "unsupportedSchemaVersion(99)".
        let shown = [reason, StatusText.menuHeader(engine.state),
                     StatusText.menuBarAccessibilityLabel(state: engine.state, issue: model.bridgeIssue)]
        for text in shown {
            #expect(!Self.looksLikeACaseName(text) && text.contains("newer version of Camera Bridge"), "\(text)")
        }
        await model.resolve(.startFailed(reason))   // Try Again: the file is still from a newer version
        if case .failed = engine.state {} else { Issue.record("expected .failed, got \(engine.state)") }
        await fixture.tearDown()
    }

    /// Review finding (W4 round 4): a damaged configuration set aside showed only as the manager's banner, which a normal
    /// or login item launch never opens: the status item, its VoiceOver label and the menu looked healthy. And the notice
    /// was in memory only, while the configuration saved since loads normally, so after a relaunch nothing said why every
    /// camera was gone. It shows in the menu bar, opens the manager, and stays until dismissed, across relaunches.
    @Test func aDamagedConfigurationShowsInTheMenuBarAndAfterARelaunch() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true, configuration: #"{"schemaVersion": 1, "settings": {"#)
        let model = fixture.model, engine = fixture.engine
        #expect(!model.opensManagerAtLaunch, "a normal launch stays in the menu bar")
        model.didFinishLaunching()
        await eventually { model.bridgeIssue != nil && fixture.windowRequests > 0 }
        guard case .configurationRecovered(let backup)? = model.bridgeIssue else {
            Issue.record("expected the configuration notice, got \(String(describing: model.bridgeIssue)) in state \(engine.state)")
            return
        }
        #expect(engine.state == .running && fixture.windowRequests == 1, "the manager opens with the banner")
        #expect(StatusText.menuBarSymbol(state: engine.state, issue: model.bridgeIssue) == "exclamationmark.triangle")
        #expect(StatusText.menuBarAccessibilityLabel(state: engine.state, issue: model.bridgeIssue) == "Camera Bridge, Your Cameras Couldn’t Be Loaded")
        #expect(model.bridgeIssue?.menuItemTitle == "Your Cameras Couldn’t Be Loaded — Show…")
        model.show(.configurationRecovered(backup))   // the menu item
        #expect(fixture.windowRequests == 2)
        await model.prepareToTerminate()
        await engine.stop()

        // Relaunch: config.json (saved after the recovery) loads normally; the notice is still there.
        let relaunched = try LiveEngineFixture(onboardingCompleted: true, existingDirectory: fixture.directory)
        guard case .configurationRecovered(let kept)? = relaunched.model.bridgeIssue else {
            Issue.record("the notice was lost at the relaunch: \(String(describing: relaunched.model.bridgeIssue))")
            await relaunched.tearDown()
            return
        }
        #expect(kept.lastPathComponent == backup.lastPathComponent)
        relaunched.model.didFinishLaunching()
        await eventually { relaunched.engine.state == .running && relaunched.windowRequests > 0 }
        #expect(relaunched.windowRequests == 1, "opened again until dismissed")
        await relaunched.engine.acknowledgeConfigurationRecovery()   // what Show in Finder does after revealing the file
        #expect(relaunched.model.bridgeIssue == nil)
        await relaunched.tearDown()
    }

    /// Review finding (W4 round 4): a webhook that isn't listening (another app took its port at login) showed only in
    /// Settings › Webhook, while every ring of a doorbell without a button of its own and every webhook motion event
    /// was lost. It is a bridge issue: the banner with Try Again, the menu bar, and a notice on camera pages.
    @Test func aWebhookThatIsNotListeningIsABridgeIssue() async throws {
        let port = UInt16.random(in: 22_000...28_000)
        let real = BridgeEnvironment.testing(directory: FileManager.default.temporaryDirectory).platform.transport
        let fixture = try LiveEngineFixture(onboardingCompleted: true,
                                            configuration: #"{"schemaVersion": 1, "settings": {"webhookEnabled": true, "webhookPort": \#(port), "sensorsBridgePort": 0}, "cameras": []}"#,
                                            transport: PortTakenTransport(inner: real, taken: port))
        let model = fixture.model, engine = fixture.engine
        model.didFinishLaunching()
        await eventually { model.bridgeIssue != nil }
        guard case .webhookNotListening(let problem)? = model.bridgeIssue else {
            Issue.record("expected the webhook issue, got \(String(describing: model.bridgeIssue)) in state \(engine.state)")
            return
        }
        #expect(problem == "The webhook cannot listen on port \(port) (another app uses the port).")
        #expect(StatusText.menuBarSymbol(state: engine.state, issue: model.bridgeIssue) == "exclamationmark.triangle")
        #expect(StatusText.menuBarAccessibilityLabel(state: engine.state, issue: model.bridgeIssue) == "Camera Bridge, The Webhook Isn’t Listening")
        model.show(.webhookNotListening(problem))   // the menu item: Settings, next to the webhook
        #expect(fixture.settingsRequests == 1 && fixture.windowRequests == 0)

        let camera = LiveEngineFixture.disabledCamera("Porch")
        try await engine.addCamera(camera, password: nil)
        #expect(model.webhookNotice(for: camera.id) == "\(problem) Events sent to these URLs are lost until it listens.")

        await model.resolve(.webhookNotListening(problem))   // Try Again: the port is still taken
        #expect(engine.webhookProblem != nil && model.bridgeIssue == .webhookNotListening(problem))
        await fixture.tearDown()
    }

    /// A Swift case name on screen ("unsupportedSchemaVersion(99)", "noFreePort(startingAt: 21100)") or an NSError dump.
    static func looksLikeACaseName(_ text: String) -> Bool {
        text.contains(/[A-Za-z]\(/) || text.contains("Error Domain=") || text.contains("UserInfo=")
    }

    /// Review finding (W4 round 2): Remove Camera on a camera whose removal couldn't be saved left it in the sidebar,
    /// jumped to "Select a Camera" and showed no alert.
    @Test func aCameraThatCannotBeRemovedSaysSo() async throws {
        let camera = LiveEngineFixture.disabledCamera("Porch")
        let fixture = try await LiveEngineFixture.withCameras([camera], onboardingCompleted: true)
        let model = fixture.model
        model.managerWindowDidAppear()
        model.showManager(selecting: .camera(camera.id))
        let path = fixture.directory.path(percentEncoded: false)
        // The data directory becomes read-only: config.json cannot be written.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        await model.removeCamera(id: camera.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        #expect(model.configuration(for: camera.id) != nil, "the engine keeps the camera")
        #expect(model.message?.title == "Couldn’t Remove “Porch”")
        #expect(model.message.map { !Self.looksLikeACaseName($0.detail) } == true)
        #expect(model.selection == .camera(camera.id), "the page stays on the camera")

        model.message = nil
        await model.removeCamera(id: camera.id)   // writable again
        #expect(model.configuration(for: camera.id) == nil && model.message == nil && model.selection == .overview)
        await fixture.tearDown()
    }

    /// Review finding (W4 App): the Connection sheet's save failed with "The change couldn’t be saved." while the reason
    /// went to the window's alert behind the sheet. The sheet's update throws the reason and shows no alert; the form's
    /// own updates still alert.
    @Test func aConnectionChangeTheEngineRefusesIsReportedToTheSheet() async throws {
        let camera = LiveEngineFixture.disabledCamera("Porch")
        let fixture = try await LiveEngineFixture.withCameras([camera], onboardingCompleted: true)
        let model = fixture.model
        model.managerWindowDidAppear()
        var changed = try #require(model.configuration(for: camera.id))
        changed.endpoint.host = "192.0.2.41"
        let path = fixture.directory.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)   // config.json can't be written
        await #expect(throws: (any Error).self) {
            try await model.applyCameraUpdate(changed, password: nil, showsFailure: false)
        }
        #expect(model.message == nil, "no alert queued behind the sheet")
        #expect(await model.updateCamera(changed) == false)
        #expect(model.message?.title == "Couldn’t Update “Porch”")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        model.message = nil
        try await model.applyCameraUpdate(changed, password: nil, showsFailure: false)
        #expect(model.configuration(for: camera.id)?.endpoint.host == "192.0.2.41")
        await fixture.tearDown()
    }

    /// Review finding (W4 round 2): two settings changes made while the engine was busy started from the same settings,
    /// and the second write undid the first (a toggle flipped back, no alert).
    @Test func overlappingSettingsChangesBothStick() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        let model = fixture.model
        let token = WebhookSettings.generateToken()
        let first = Task { await model.setKeepMacAwake(true) }
        let second = Task { await model.updateSettings { $0.webhookToken = token } }
        await first.value
        #expect(await second.value)
        #expect(fixture.engine.settings.keepMacAwake && fixture.engine.settings.webhookToken == token)
        let saved = BridgeEngine(environment: .testing(directory: fixture.directory)).settings
        #expect(saved.keepMacAwake && saved.webhookToken == token, "both are in config.json")
        #expect(model.message == nil)
        await fixture.tearDown()
    }

    /// The Local Network check connects to the enabled cameras on the network, each address once, then the router.
    @Test func localNetworkCheckTargetsTheCamerasThenTheGateway() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true, gateway: "192.0.2.1")
        let model = fixture.model
        #expect(model.localNetworkCheckCameraHosts.isEmpty, "first run: the router only")
        try await fixture.engine.addCamera(CameraConfiguration(name: "Demo", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"),
                                                               username: ""), password: nil)
        #expect(model.localNetworkCheckCameraHosts.isEmpty, "the demo camera is not on the network")
        var gate = CameraConfiguration(name: "Gate", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.40"), username: "")
        gate.isEnabled = false
        try await fixture.engine.addCamera(gate, password: nil)
        #expect(model.localNetworkCheckCameraHosts.isEmpty, "nor is a disabled camera")
        for (name, host) in [("Porch", "192.0.2.41"), ("Yard", "192.0.2.42"), ("Porch 2", "192.0.2.41")] {
            try await fixture.engine.addCamera(CameraConfiguration(name: name, kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: host),
                                                                   username: ""), password: nil)
        }
        #expect(model.localNetworkCheckCameraHosts == ["192.0.2.41", "192.0.2.42"])
        #expect(fixture.gatewayLookups == 0, "the router is looked up only when no camera answers")
        await fixture.tearDown()
    }

    /// Review finding (W4 round 4): the checks went to the first enabled camera only. With that camera offline (it only
    /// times out, which says nothing about Local Network access) the banner, the menu bar's warning and the Fix sheet
    /// stayed "denied" after the person allowed access, and camera searches were skipped. The checks go on to the other
    /// cameras and the router until one answers.
    @Test func theDeniedBannerClearsWhileTheFirstCameraIsOffline() async throws {
        let gate = LocalNetworkGate(unreachableHosts: ["192.0.2.41"])
        let porch = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.41"), username: "")
        let fixture = try await LiveEngineFixture.withCameras([porch], onboardingCompleted: true, gateway: "192.0.2.1", transport: gate,
                                                              localNetworkAnswerWait: .milliseconds(100),
                                                              localNetworkRecheckInterval: .milliseconds(50))
        let model = fixture.model, engine = fixture.engine
        #expect(await model.checkLocalNetworkAccess() == .checked(.denied))
        #expect(model.bridgeIssue == .localNetworkDenied && fixture.gatewayLookups == 0, "the camera's denial is an answer")

        gate.allow()   // in System Settings; the camera is unplugged meanwhile
        await eventually { model.bridgeIssue == nil }
        #expect(model.bridgeIssue == nil && engine.localNetworkAccess == .granted, "\(gate.hosts)")
        #expect(gate.hosts.suffix(2) == ["192.0.2.41", "192.0.2.1"], "the camera timed out, the router answered: \(gate.hosts)")
        // Check Again in the Fix sheet goes the same way.
        #expect(await model.checkLocalNetworkAccess() == .checked(.granted))
        await fixture.tearDown()
    }

    /// Check Access before the first camera goes to the router, through the engine, to port 80. On loopback nothing
    /// listens there (refused) or something answers: either way the packets got through, so access is granted.
    @Test func checkAccessBeforeTheFirstCameraConnectsToTheRouter() async throws {
        let fixture = try LiveEngineFixture(gateway: "127.0.0.1")
        let model = fixture.model
        #expect(await model.checkLocalNetworkAccess() == .checked(.granted))
        #expect(fixture.engine.localNetworkAccess == .granted && model.bridgeIssue == nil)
        #expect(fixture.gatewayLookups == 1)
        #expect(!model.isRecheckingLocalNetworkAccess)
        await fixture.tearDown()
    }

    /// Without a camera or a router nothing is checked, and the guide says so instead of "nothing answered".
    @Test func checkAccessWithoutANetworkSaysSo() async throws {
        let gate = LocalNetworkGate()
        let fixture = try LiveEngineFixture(gateway: nil, transport: gate)
        #expect(await fixture.model.checkLocalNetworkAccess() == .noNetwork)
        #expect(gate.attempts == 0 && fixture.engine.localNetworkAccess == .unknown)
        let text = OnboardingContent.localNetworkStatus(fixture.engine.localNetworkAccess, lastCheck: .noNetwork)
        #expect(text.contains("couldn’t find your network") && !text.contains("answered"))
        await fixture.tearDown()
    }

    /// First run: the check raises the system's alert, and connections are blocked until the person answers. Clicking
    /// Allow while Check Access waits is reported as allowed; no banner appears meanwhile.
    @Test func allowingTheSystemPromptDuringCheckAccessIsNotADenial() async throws {
        let gate = LocalNetworkGate(allowAfter: 3)
        let fixture = try LiveEngineFixture(gateway: "192.0.2.1", transport: gate)
        let model = fixture.model, engine = fixture.engine
        let checking = Task { await model.checkLocalNetworkAccess() }
        await eventually { gate.attempts >= 2 }
        #expect(gate.attempts >= 2)
        #expect(engine.localNetworkAccess == .unknown && model.bridgeIssue == nil, "no denial while the alert is up")
        #expect(await checking.value == .checked(.granted))
        #expect(engine.localNetworkAccess == .granted && model.bridgeIssue == nil && gate.attempts == 4)
        #expect(!model.isRecheckingLocalNetworkAccess)
        await fixture.tearDown()
    }

    /// A denial shows the banner; once the person allows access in System Settings a background check clears it
    /// (with no camera, nothing else would) and the checks stop.
    @Test func theDeniedBannerClearsOnceAccessIsAllowed() async throws {
        let gate = LocalNetworkGate()
        let fixture = try LiveEngineFixture(gateway: "192.0.2.1", transport: gate, localNetworkAnswerWait: .milliseconds(200),
                                            localNetworkRecheckInterval: .milliseconds(50))
        let model = fixture.model, engine = fixture.engine
        #expect(await model.checkLocalNetworkAccess() == .checked(.denied))
        #expect(model.bridgeIssue == .localNetworkDenied && engine.localNetworkAccess == .denied)
        #expect(model.isRecheckingLocalNetworkAccess)
        let afterCheck = gate.attempts
        await eventually { gate.attempts >= afterCheck + 2 }
        #expect(gate.attempts >= afterCheck + 2, "checked again while denied")
        #expect(model.bridgeIssue == .localNetworkDenied)

        gate.allow()
        await eventually { model.bridgeIssue == nil }
        #expect(model.bridgeIssue == nil && engine.localNetworkAccess == .granted)
        await eventually { !model.isRecheckingLocalNetworkAccess }
        #expect(!model.isRecheckingLocalNetworkAccess)
        let settled = gate.attempts
        try await Task.sleep(for: .milliseconds(200))
        #expect(gate.attempts == settled, "no more checks once access is allowed")
        await fixture.tearDown()
    }

    /// Coming back to the app (from System Settings) checks a denial again at once.
    @Test func becomingActiveChecksADenialAgainAtOnce() async throws {
        let gate = LocalNetworkGate()
        let fixture = try LiveEngineFixture(gateway: "192.0.2.1", transport: gate, localNetworkAnswerWait: .zero,
                                            localNetworkRecheckInterval: .seconds(3600))
        let model = fixture.model
        model.applicationDidBecomeActive()
        #expect(gate.attempts == 0 && !model.isRecheckingLocalNetworkAccess, "nothing to check before a denial")
        #expect(await model.checkLocalNetworkAccess() == .checked(.denied))
        #expect(gate.attempts == 1)
        gate.allow()
        model.applicationDidBecomeActive()
        await eventually { model.bridgeIssue == nil }
        #expect(model.bridgeIssue == nil && gate.attempts == 2)
        await fixture.tearDown()
    }

    @Test func quittingStopsTheLocalNetworkChecks() async throws {
        let gate = LocalNetworkGate()
        let fixture = try LiveEngineFixture(gateway: "192.0.2.1", transport: gate, localNetworkAnswerWait: .zero,
                                            localNetworkRecheckInterval: .milliseconds(30))
        let model = fixture.model
        #expect(await model.checkLocalNetworkAccess() == .checked(.denied))
        await eventually { gate.attempts >= 3 }
        await model.prepareToTerminate()
        #expect(!model.isRecheckingLocalNetworkAccess)
        let stopped = gate.attempts
        try await Task.sleep(for: .milliseconds(200))
        #expect(gate.attempts <= stopped + 1, "at most the check already under way finishes")
        await fixture.tearDown()
    }

    /// Onboarding pending while cameras are already configured (`-showOnboarding YES`, reset app defaults): the engine
    /// waits for Get Started, so the guide never runs alongside live cameras.
    @Test func pendingOnboardingWithCamerasHoldsTheEngine() async throws {
        let fixture = try await LiveEngineFixture.withCameras([LiveEngineFixture.disabledCamera()], onboardingCompleted: false)
        let model = fixture.model, engine = fixture.engine
        #expect(engine.configurations.count == 1 && !model.startsEngineAtLaunch)
        model.didFinishLaunching()
        #expect(model.presentedSheet == .onboarding)
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state == .stopped)
        await model.completeOnboarding()
        #expect(engine.state == .running && model.presentedSheet == nil)
        await fixture.tearDown()
    }

    /// First run: Get Started leads to the Overview, which shows "No Cameras Yet — Add Camera…" (not Settings).
    @Test func theFirstRunShowsTheNoCamerasPage() async throws {
        let fixture = try LiveEngineFixture()
        let model = fixture.model
        model.didFinishLaunching()
        #expect(model.selection == .overview && model.defaultSelection == .overview)
        model.showManager()   // reopening the window (menu, Dock)
        #expect(model.selection == .overview)
        await fixture.tearDown()
    }

    /// With cameras configured, the manager opens on the Overview (every camera at a glance), also before the engine has
    /// published any status (`-openManager YES` at launch).
    @Test func theManagerOpensOnTheOverview() async throws {
        let camera = LiveEngineFixture.disabledCamera()
        let fixture = try await LiveEngineFixture.withCameras([camera], onboardingCompleted: true)
        let model = fixture.model
        #expect(fixture.engine.cameras.isEmpty && fixture.engine.configurations.count == 1)
        model.showManager()
        #expect(model.selection == .overview)
        await fixture.tearDown()
    }

    /// The Discover page's search is often the first local network traffic (Check Access is optional in onboarding):
    /// it waits for the answer to the system's alert first, so a prompt still on screen doesn't cost the search.
    @Test func discoveryWaitsForTheLocalNetworkAnswer() async throws {
        let gate = LocalNetworkGate(allowAfter: 2)
        let fixture = try LiveEngineFixture(gateway: "192.0.2.1", transport: gate)
        let found = await fixture.model.discoverCameras()
        #expect(found.isEmpty, "loopback-only engines never multicast")
        #expect(gate.attempts == 3 && fixture.engine.localNetworkAccess == .granted)
        _ = await fixture.model.discoverCameras()
        #expect(gate.attempts == 3, "checked once: the answer is known now")
        await fixture.tearDown()
    }

    /// A denial found before the search shows as the bridge issue, and is checked again in the background.
    @Test func discoveryWithLocalNetworkDeniedSurfacesIt() async throws {
        let gate = LocalNetworkGate()
        let fixture = try LiveEngineFixture(gateway: "192.0.2.1", transport: gate, localNetworkAnswerWait: .milliseconds(100),
                                            localNetworkRecheckInterval: .seconds(3600))
        let model = fixture.model
        #expect(await model.discoverCameras().isEmpty)
        #expect(fixture.engine.localNetworkAccess == .denied && model.localNetworkAccess == .denied)
        #expect(model.bridgeIssue == .localNetworkDenied && model.isRecheckingLocalNetworkAccess)
        await fixture.tearDown()
    }

    /// A probe that can't reach the camera because of Local Network privacy says so (the engine's probe tests cover the
    /// first-run wait for the alert's answer; here the denial is already known, so nothing waits).
    @Test func aProbeBlockedByLocalNetworkSaysSo() async throws {
        let gate = LocalNetworkGate()
        let fixture = try LiveEngineFixture(gateway: "192.0.2.1", transport: gate, localNetworkAnswerWait: .milliseconds(100),
                                            localNetworkRecheckInterval: .seconds(3600))
        let model = fixture.model
        #expect(await model.checkLocalNetworkAccess() == .checked(.denied))
        await #expect(throws: TransportError.localNetworkDenied) {
            // Plain RTSP over the (denying) transport: nothing leaves the Mac.
            try await model.probeCamera(vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.24", rtspPort: 8554), username: "", password: "",
                                        mainStreamURL: URL(string: "rtsp://192.0.2.24:8554/live"), subStreamURL: nil)
        }
        #expect(model.bridgeIssue == .localNetworkDenied && model.isRecheckingLocalNetworkAccess)
        #expect(ErrorText.describe(TransportError.localNetworkDenied).contains("Local Network"))
        await fixture.tearDown()
    }

    /// The camera page's Recent Events come from the engine, so they stay at log level Error.
    @Test func recentEventsSurviveAQuietLogLevel() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        let model = fixture.model, engine = fixture.engine
        #expect(await model.updateSettings { $0.logLevel = .error })
        // Never started: the camera is registered with the event router but nothing connects to it.
        var camera = LiveEngineFixture.disabledCamera("Porch")
        camera.isEnabled = true
        try await engine.addCamera(camera, password: nil)
        await engine.triggerTestMotion(cameraID: camera.id)
        await engine.stop()   // publishes the status
        #expect(RecentEvents.newestFirst(in: model.status(for: camera.id)).map(\.name) == ["Motion"])
        #expect(await model.updateSettings { $0.logLevel = .info })
        await fixture.tearDown()
    }

    /// Review finding (W4 round 4): Trigger Motion (a real motion event in the Home app) stayed enabled and did nothing,
    /// silently, while the camera's accessory wasn't published. It is off then, with the reason, and sends nothing.
    @Test func triggerMotionWaitsUntilTheAccessoryIsPublished() async throws {
        let fixture = try LiveEngineFixture(onboardingCompleted: true)
        let model = fixture.model, engine = fixture.engine
        var camera = LiveEngineFixture.disabledCamera("Porch")
        camera.isEnabled = true
        try await engine.addCamera(camera, password: nil)   // never started: registered with the event router only
        #expect(model.testMotionBlocker(for: camera.id) == .bridgeNotRunning)
        await model.triggerTestMotion(cameraID: camera.id)
        await engine.stop()   // publishes the status
        #expect(model.status(for: camera.id) != nil)
        #expect(RecentEvents.newestFirst(in: model.status(for: camera.id)).isEmpty, "nothing was sent")
        #expect(AppModel.preview().testMotionBlocker(for: PreviewSample.firstCameraID(in: BridgeEngine.preview())) == nil,
                "a published accessory can be sent motion")
        await fixture.tearDown()
    }

    /// The QR code is offered only while the camera's accessory is published.
    @Test func pairingWaitsUntilTheAccessoryIsPublished() async throws {
        let disabled = LiveEngineFixture.disabledCamera()
        var enabled = LiveEngineFixture.disabledCamera("Porch")
        enabled.isEnabled = true
        let fixture = try await LiveEngineFixture.withCameras([disabled], onboardingCompleted: true)
        let model = fixture.model, engine = fixture.engine
        await engine.start()
        await model.toggleBridgeRunning()
        #expect(engine.state == .paused)
        // Added while paused: the wizard's last page must not offer a code nothing advertises.
        try await engine.addCamera(enabled, password: nil)
        await eventually { model.status(for: enabled.id) != nil }
        #expect(model.pairingCode(for: enabled.id) != nil, "the code exists…")
        #expect(model.pairingBlocker(for: enabled.id) == .bridgePaused, "…but isn't offered while paused")
        #expect(model.pairingBlocker(for: disabled.id) == .cameraDisabled)
        await model.prepareToTerminate()
        #expect(model.pairingBlocker(for: enabled.id) == .bridgeNotRunning)
        #expect(model.pairingBlocker(for: UUID()) == nil)
        await fixture.tearDown()
    }

    /// Pause and stop close the sensors bridge, but the engine keeps its last status: the page must not keep offering
    /// the QR code then.
    @Test func thePausedSensorsBridgePageSaysSo() async throws {
        let fixture = try await LiveEngineFixture.withCameras([LiveEngineFixture.disabledCamera()], onboardingCompleted: true)
        let model = fixture.model, engine = fixture.engine
        func placeholder() -> String? {
            StatusText.sensorsBridgeUnavailable(state: engine.state, bridge: engine.sensorsBridge, hasCameras: !engine.configurations.isEmpty)
        }
        #expect(model.startsEngineAtLaunch)
        model.didFinishLaunching()
        await eventually { engine.state == .running && engine.sensorsBridge != nil }
        #expect(engine.sensorsBridge != nil && placeholder() == nil, "a running bridge shows its code")
        await model.toggleBridgeRunning()
        #expect(engine.state == .paused)
        #expect(placeholder() == "The bridge is paused. Resume it to use the sensors bridge.")
        await model.prepareToTerminate()
        #expect(placeholder() == "The bridge isn’t running. Start it to use the sensors bridge.")
        await model.toggleBridgeRunning()
        await eventually { placeholder() == nil }
        #expect(engine.state == .running && placeholder() == nil)
        await fixture.tearDown()
    }
}

@Suite(.timeLimit(.minutes(1))) struct BridgeIssueTests {
    @Test func issuesComeFromTheEngineState() {
        #expect(BridgeIssue.current(state: .running, localNetworkAccess: .granted) == nil)
        #expect(BridgeIssue.current(state: .paused, localNetworkAccess: .unknown) == nil)
        #expect(BridgeIssue.current(state: .running, localNetworkAccess: .denied) == .localNetworkDenied)
        #expect(BridgeIssue.current(state: .failed("Port in use"), localNetworkAccess: .denied) == .startFailed("Port in use"),
                "a failed start comes first")
        #expect(BridgeIssue.localNetworkDenied.title == "Local Network Access Denied")
        #expect(BridgeIssue.localNetworkDenied.actionTitle == "Fix…")
        #expect(BridgeIssue.startFailed("x").detail == "x")
    }

    /// Review finding (W4 round 3): a damaged configuration was replaced with the defaults and only the log said so (the
    /// window showed "No Cameras Yet"). The engine's backup file becomes a banner until it is dismissed.
    @Test func aConfigurationSetAsideIsAnIssue() {
        let backup = URL(fileURLWithPath: "/tmp/CameraBridge/config.corrupt-20261001T101058Z.json")
        #expect(BridgeIssue.current(state: .running, localNetworkAccess: .denied, configurationBackup: backup) == .configurationRecovered(backup),
                "before Local Network: the cameras are gone")
        #expect(BridgeIssue.current(state: .failed("x"), localNetworkAccess: .granted, configurationBackup: backup) == .startFailed("x"))
        let issue = BridgeIssue.configurationRecovered(backup)
        #expect(issue.detail.contains("config.corrupt-20261001T101058Z.json"))
        #expect(issue.actionTitle == "Show in Finder")
    }

    /// The reason goes on screen (banner, menu header), so it is redacted like the log.
    @Test func startFailuresAreRedacted() {
        let reason = "could not read rtsp://admin:hunter2@192.0.2.21:554/live"
        guard case .startFailed(let shown)? = BridgeIssue.current(state: .failed(reason), localNetworkAccess: .unknown) else {
            Issue.record("expected a start failure")
            return
        }
        #expect(!shown.contains("hunter2") && shown.contains("192.0.2.21"))
        #expect(!StatusText.engineState(.failed(reason)).contains("hunter2"))
        #expect(!StatusText.menuHeader(.failed(reason)).contains("hunter2"))
    }

    /// Fix… opens the manager with the Local Network check and its fix steps (not the whole welcome guide).
    @Test func fixingLocalNetworkAccessOpensTheGuide() async {
        let scratch = ScratchDefaults()
        let model = AppModel(options: LaunchOptions(usesPreviewEngine: true), engine: BridgeEngine.preview(), loginItems: InMemoryLoginItemService(),
                             defaults: scratch.defaults, previewLatency: .zero)
        var opened = 0
        model.windowOpener = { opened += 1 }
        await model.resolve(.localNetworkDenied)
        #expect(model.presentedSheet == .localNetworkAccess && opened == 1)
    }

    @Test func sensorsBridgePlaceholderSaysWhyItIsNotRunning() {
        let bridge = SensorsBridgeStatus(isPaired: false, setupCode: "111-22-333", setupURI: "X-HM://0", accessoryCount: 1)
        let noCameras = "It starts when you add a camera. Until then, Camera Bridge publishes nothing on your network."
        #expect(StatusText.sensorsBridgeUnavailable(state: .running, bridge: nil, hasCameras: false) == noCameras)
        #expect(StatusText.sensorsBridgeUnavailable(state: .paused, bridge: nil, hasCameras: false) == noCameras)
        #expect(StatusText.sensorsBridgeUnavailable(state: .running, bridge: bridge, hasCameras: true) == nil, "only then is the code shown")
        // The engine keeps the last status after pause/stop: a stale code is never offered.
        for stale in [bridge, nil] as [SensorsBridgeStatus?] {
            #expect(StatusText.sensorsBridgeUnavailable(state: .paused, bridge: stale, hasCameras: true) == "The bridge is paused. Resume it to use the sensors bridge.")
            #expect(StatusText.sensorsBridgeUnavailable(state: .stopped, bridge: stale, hasCameras: true) == "The bridge isn’t running. Start it to use the sensors bridge.")
            #expect(StatusText.sensorsBridgeUnavailable(state: .failed("x"), bridge: stale, hasCameras: true) == "The bridge isn’t running. Start it to use the sensors bridge.")
            #expect(StatusText.sensorsBridgeUnavailable(state: .starting, bridge: stale, hasCameras: true) == "The bridge is starting.")
        }
        #expect(StatusText.sensorsBridgeUnavailable(state: .running, bridge: nil, hasCameras: true) == "It isn’t running. The log in Settings shows why.")
    }
}

@Suite(.timeLimit(.minutes(1))) struct DefaultGatewayTests {
    @Test func theFirstIPv4RouterIsTheTarget() throws {
        let v6 = NWEndpoint.hostPort(host: .ipv6(try #require(IPv6Address("fe80::1"))), port: 0)
        let v4 = NWEndpoint.hostPort(host: .ipv4(try #require(IPv4Address("192.0.2.1"))), port: 0)
        let other = NWEndpoint.hostPort(host: .ipv4(try #require(IPv4Address("198.51.100.7"))), port: 0)
        #expect(DefaultGateway.ipv4Address(in: [v6, v4, other]) == "192.0.2.1")
        #expect(DefaultGateway.ipv4Address(in: [v6]) == nil)
        #expect(DefaultGateway.ipv4Address(in: []) == nil)
    }

    /// Reads the current path (no packets are sent) and answers within the time limit.
    @Test func theLookupAnswersInTime() async {
        let start = ContinuousClock.now
        _ = await DefaultGateway.ipv4Address(timeout: .milliseconds(500))
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func checkedButUnconfirmedAccessIsExplained() {
        #expect(OnboardingContent.localNetworkStatus(.unknown, lastCheck: .checked(.unknown)).contains("couldn’t be confirmed"))
        #expect(OnboardingContent.localNetworkStatus(.unknown) == OnboardingContent.localNetworkStatus(.unknown, lastCheck: nil))
        #expect(OnboardingContent.localNetworkStatus(.unknown).contains("Click Check Access"))
        #expect(OnboardingContent.localNetworkStatus(.granted, lastCheck: .checked(.granted)) == "Local Network access is allowed.")
        // The engine's live answer wins over the sheet's last check (a background check found access allowed).
        #expect(OnboardingContent.localNetworkStatus(.granted, lastCheck: .checked(.denied)) == "Local Network access is allowed.")
        #expect(OnboardingContent.localNetworkStatus(.denied, lastCheck: .noNetwork).contains("was denied"))
        let noNetwork = OnboardingContent.localNetworkStatus(.unknown, lastCheck: .noNetwork)
        #expect(noNetwork.contains("nothing was checked") && !noNetwork.contains("answered"))
        #expect(OnboardingContent.localNetworkChecking.contains("click Allow"))
    }
}
