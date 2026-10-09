import AppKit
import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Observation

/// Where the manager window's sidebar points. App-wide preferences are not a page here: they live in the Settings scene.
enum ManagerSelection: Hashable {
    /// Every camera at a glance, optionally live: the page the manager opens on.
    case overview
    case camera(UUID)
    case sensorsBridge
    /// The central log and Export Diagnostics….
    case diagnostics
}

/// The manager window's sheet. One at a time: a second request waits (is ignored) until the first is dismissed.
/// `localNetworkAccess`: the Local Network check and its fix steps on their own (Fix… for a denial), not below the
/// welcome guide's prerequisites.
/// `vpnHelp`: Learn More for the VPN findings; `networkHelp`: Learn More for the other network findings (`NetworkHelpContent`).
enum ManagerSheet: Identifiable, Hashable {
    case onboarding, addCamera, localNetworkAccess, vpnHelp
    case networkHelp(NetworkNotice.Kind)
    var id: Self { self }
}

/// An alert: something the person asked for didn't work.
struct AppMessage: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
}

/// The engine kept a camera it was asked to remove: `removeCamera` logs why (the configuration couldn't be read or
/// saved) and doesn't throw.
enum CameraRemovalError: Error, LocalizedError {
    case notSaved

    var errorDescription: String? {
        String(localized: "Camera Bridge couldn’t update its configuration, so the camera is still set up. Try again later. The log in Settings has the details.")
    }
}

/// Show in Finder for a data folder that doesn't exist (CameraBridge hasn't saved anything yet).
enum DataFolderError: Error, LocalizedError {
    case missing

    var errorDescription: String? {
        String(localized: "Camera Bridge hasn’t saved anything yet, so its data folder doesn’t exist. Add a camera first.")
    }
}

/// What Check Access found.
enum LocalNetworkCheckOutcome: Equatable {
    /// A connection to a camera or the router was attempted; `.unknown` = nothing answered.
    case checked(LocalNetworkAccess)
    /// No camera is configured and no router was found, so there was nothing to connect to (no packet was sent).
    case noNetwork
}

/// Owns the bridge engine for the app's lifetime, plus the login item, onboarding state and window navigation.
///
/// Live (`BridgeEngine(environment: .live())`): the engine starts at launch, also on the first run — without cameras it
/// publishes nothing on the network, and adding the first camera waits until onboarding is done (one sheet at a time).
/// Only when onboarding is pending while cameras are already configured (`-showOnboarding YES`, or reset app defaults
/// with a surviving configuration) does the engine wait for Get Started, so the guide never runs alongside live cameras.
/// Pause/Resume/Start come from the menu or the toolbar, wake is forwarded from `NSWorkspace`, and quitting stops the
/// engine. A bridge that can't start or has no Local Network access shows as `bridgeIssue`; while access is denied it
/// is checked again every `localNetworkRecheckInterval` and when the app becomes active, so the banner clears soon
/// after the person allows access.
///
/// Launch with `-previewEngine YES` to run on `BridgeEngine.preview()`: sample data, no networking, no system changes
/// (login item simulated). In that mode every action that would change the bridge is skipped with a short notice,
/// and discovery/probing answer from `PreviewFixtures`. Keep Mac Awake is the engine's `keepMacAwake` setting (the
/// engine holds the `PreventUserIdleSystemSleep` assertion through `PlatformServices.power`).
///
/// Failed actions become an alert on the manager window, which is opened or brought forward (and the app activated) so
/// the alert is seen: an action from the menu bar doesn't activate this agent app, and an open window may be behind
/// other apps. The camera page's Connection sheet shows its own failures instead (`applyCameraUpdate(…, showsFailure:)`).
@MainActor @Observable
final class AppModel {
    static let onboardingCompletedKey = "onboardingCompleted"
    /// Which VPN banners were shown or dismissed, and when (`NetworkNoticeThrottle`).
    static let networkThrottleKey = "networkNoticeThrottle"
    /// The sidebar's Sensors section: which cameras' lists are open or closed against the default.
    static let sensorGroupsKey = "sidebarSensorGroups"
    /// Settings › Help improve camera support. Off unless the person turns it on.
    static let sharesSetupReportsKey = "sharesSetupReports"
    /// Quit waits at most this long for the engine to stop.
    static let terminationTimeLimit: Duration = .seconds(5)

    /// Applies a settings change and persists it: the engine's `updateSettings(_ change:)`, which applies the change to
    /// the settings as they are when its turn comes (tests inject a fake).
    typealias SettingsWriter = @MainActor (_ change: (inout BridgeSettings) -> Void) async throws -> Void
    /// The router's address: the Local Network check's target before any camera is configured (tests inject one).
    typealias GatewayLookup = @MainActor () async -> String?

    let engine: BridgeEngine
    let options: LaunchOptions
    var isPreview: Bool { options.usesPreviewEngine }

    /// The login item's status, read live: people change it in System Settings › General › Login Items (or never approve
    /// a registration), which tells the app nothing, and the menu bar menu opens without activating this agent app.
    /// `refreshLoginItemStatus()` redraws what shows it.
    var loginItemStatus: LoginItemStatus {
        _ = loginItemStatusShown   // observed: a refresh that found a change redraws the menu and Settings
        return loginItems.status
    }
    /// The status last shown (`refreshLoginItemStatus`).
    private var loginItemStatusShown: LoginItemStatus
    /// Whether camera setup reports are sent without asking each time (Settings › Help improve camera support). Off
    /// by default; nothing is ever sent while it is off unless the person approves that one report.
    var sharesSetupReports: Bool {
        didSet { defaults.set(sharesSetupReports, forKey: Self.sharesSetupReportsKey) }
    }
    /// The feed in use and when the server last answered (Settings › Privacy); nil without a profile service (tests,
    /// `#Preview`s). `refreshCameraProfileStatus()` re-reads it.
    private(set) var cameraProfileStatus: CameraProfileService.Status?
    /// A Check Now is under way.
    private(set) var isCheckingCameraProfiles = false
    /// What the last Check Now found, shown next to the button; nil before one ran.
    private(set) var cameraProfileCheckResult: CameraProfileService.RefreshOutcome?
    /// Export and Import Configuration (Settings › Backup).
    let backup = BackupModel()
    /// Where the configuration and the logs live (Settings › Diagnostics › Show in Finder); the live app's folder in
    /// tests and previews too, where nothing is created there.
    @ObservationIgnored let dataDirectory: URL
    var selection: ManagerSelection?
    /// The manager window's sheet (onboarding or Add Camera), if any.
    var presentedSheet: ManagerSheet?
    /// Which VPN banners were shown or dismissed (`NetworkNoticeThrottle`); remembered across launches.
    private var networkThrottle = NetworkNoticeThrottle()
    /// The camera whose sensors the Sensors page is showing (a sensor or camera in the sidebar's Sensors section); nil: all.
    var sensorsFocus: UUID?
    /// Cameras whose sensor list the sidebar shows open or closed against its default (`SensorsSidebar.isExpanded`); remembered.
    private(set) var sensorGroupOverrides: [UUID: Bool] = [:]
    /// Alert for a failed action.
    var message: AppMessage?
    /// Transient banner text (preview mode).
    private(set) var notice: String?
    /// Whether CameraBridge shows in the Dock and the menu bar (Settings › General); at least one is on. Stored in
    /// `defaults`, which the App scene's `@AppStorage` for the status item reads too.
    private(set) var presence: AppPresence
    /// Applies a changed presence to the app (the activation policy); installed by the app delegate, which owns AppKit.
    @ObservationIgnored var presenceHandler: (@MainActor (AppPresence) -> Void)?

    /// Opens (or brings forward) the manager window; set by the SwiftUI layer, which owns `openWindow`. A request made
    /// before it is installed (at launch) is carried out on installation.
    @ObservationIgnored var windowOpener: (@MainActor () -> Void)? {
        didSet {
            guard pendingManagerOpen, let windowOpener else { return }
            pendingManagerOpen = false
            windowOpener()
        }
    }
    @ObservationIgnored private var pendingManagerOpen = false
    /// Opens the Settings scene (⌘,); installed by the status item like `windowOpener`. Requests made before it exists
    /// open Settings once it is installed.
    @ObservationIgnored var settingsOpener: (@MainActor () -> Void)? {
        didSet {
            guard pendingSettingsOpen, let settingsOpener else { return }
            pendingSettingsOpen = false
            settingsOpener()
        }
    }
    @ObservationIgnored private var pendingSettingsOpen = false
    /// Whether the manager window is on screen (its view reports appearing and disappearing).
    @ObservationIgnored private(set) var isManagerWindowOpen = false

    /// The Diagnostics page's log and export (`DiagnosticsCenter`: every subsystem's log at debug level).
    @ObservationIgnored let diagnostics: DiagnosticsModel
    /// When the app launched (the report's app uptime).
    @ObservationIgnored let launchDate = Date()
    @ObservationIgnored private let loginItems: any LoginItemService
    @ObservationIgnored private let writeSettings: SettingsWriter
    @ObservationIgnored private let gatewayAddress: GatewayLookup
    @ObservationIgnored private let defaults: UserDefaults
    /// Fetches and caches the camera profiles feed; nil in tests and previews (no network).
    @ObservationIgnored let profileService: CameraProfileService?
    @ObservationIgnored private let reportSender: any SetupReportSending
    @ObservationIgnored private let previewLatency: Duration
    @ObservationIgnored private let localNetworkAnswerWait: Duration
    @ObservationIgnored private let localNetworkRecheckInterval: Duration
    /// Checks Local Network access again while it is denied (`keepCheckingLocalNetworkAccess`).
    @ObservationIgnored private var localNetworkRecheck: Task<Void, Never>?
    @ObservationIgnored private var localNetworkRecheckRun: UUID?
    /// Whether denied Local Network access is being checked again in the background.
    @ObservationIgnored private(set) var isRecheckingLocalNetworkAccess = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private let log = Log(category: "App")
    /// Preview mode: cameras "added" through the wizard (never reach the sample engine).
    @ObservationIgnored private var previewAddedKinds: [UUID: CameraKind] = [:]

    /// `localNetworkAnswerWait`: how long Check Access waits for the answer to the system's Local Network alert (see
    /// `BridgeEngine.checkLocalNetworkAccess(host:answerWait:)`); `localNetworkRecheckInterval`: how often a denial is
    /// checked again.
    init(options: LaunchOptions, engine: BridgeEngine, loginItems: any LoginItemService, defaults: UserDefaults,
         previewLatency: Duration = .milliseconds(700), writeSettings: SettingsWriter? = nil, gatewayAddress: GatewayLookup? = nil,
         localNetworkAnswerWait: Duration = BridgeEngine.localNetworkAnswerWait, localNetworkRecheckInterval: Duration = .seconds(10),
         profileService: CameraProfileService? = nil, reportSender: any SetupReportSending = LiveSetupReportSender(),
         dataDirectory: URL = AppModel.defaultDataDirectory) {
        self.dataDirectory = dataDirectory
        self.options = options
        self.profileService = profileService
        self.reportSender = reportSender
        sharesSetupReports = defaults.bool(forKey: Self.sharesSetupReportsKey)
        presence = AppPresence.loadRepairing(from: defaults)
        sensorGroupOverrides = Dictionary(uniqueKeysWithValues: (defaults.dictionary(forKey: Self.sensorGroupsKey) as? [String: Bool] ?? [:])
            .compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        // Preview mode's sample notices are dated from each launch: nothing of the throttle is kept for them.
        networkThrottle = options.usesPreviewEngine ? NetworkNoticeThrottle()
            : defaults.data(forKey: Self.networkThrottleKey).flatMap { try? JSONDecoder().decode(NetworkNoticeThrottle.self, from: $0) } ?? NetworkNoticeThrottle()
        self.engine = engine
        diagnostics = DiagnosticsModel(fallbackEntries: { [engine] in engine.recentLogs })
        self.loginItems = loginItems
        self.writeSettings = writeSettings ?? { [engine] change in try await engine.updateSettings(change) }
        self.gatewayAddress = gatewayAddress ?? { await DefaultGateway.ipv4Address() }
        self.defaults = defaults
        self.previewLatency = previewLatency
        self.localNetworkAnswerWait = localNetworkAnswerWait
        self.localNetworkRecheckInterval = localNetworkRecheckInterval
        loginItemStatusShown = loginItems.status
    }

    /// The app's model: preview engine + simulated login item for `-previewEngine YES`, else the live engine. Preview
    /// mode keeps its own defaults (`previewDefaults`): it is the same app, so `defaults` is the live app's domain, and
    /// Get Started in preview mode must not mark the live app's onboarding complete.
    static func launching(defaults: UserDefaults = .standard, previewDefaults: @autoclosure () -> UserDefaults = AppModel.previewDefaults) -> AppModel {
        // Launch arguments (sample-data engine, screenshots, forced onboarding) exist in Debug builds only: a release
        // build always runs the live engine.
        #if DEBUG
        let options = LaunchOptions(defaults: defaults)
        #else
        let options = LaunchOptions()
        #endif
        if options.usesPreviewEngine {
            // The profile service only reads in preview mode (it never asks the server: `loadCameraProfiles` is skipped).
            let previewDefaults = previewDefaults()
            return AppModel(options: options, engine: BridgeEngine.preview(scenario: options.previewScenario), loginItems: InMemoryLoginItemService(), defaults: previewDefaults,
                            profileService: CameraProfileService())
        }
        let environment = BridgeEnvironment.live()
        // The Developer ID build is not sandboxed: take over the configuration and settings of the sandboxed build once.
        LegacySandboxMigration.migrate(bundleID: Bundle.main.bundleIdentifier ?? "com.coreysilvia.CameraBridge", home: FileManager.default.homeDirectoryForCurrentUser,
                                       dataDirectory: environment.dataDirectory, defaults: defaults)
        // Every subsystem's log at debug level, redacted, in memory and in rotating files (5 × 2 MB) next to the configuration.
        DiagnosticsCenter.shared.install(directory: environment.dataDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory))
        return AppModel(options: options, engine: BridgeEngine(environment: environment), loginItems: MainAppLoginItemService(), defaults: defaults,
                        profileService: CameraProfileService(), dataDirectory: environment.dataDirectory)
    }

    /// Preview mode's and `#Preview`s' defaults, apart from the live app's.
    static var previewDefaults: UserDefaults { UserDefaults(suiteName: "CameraBridgePreviews") ?? UserDefaults() }

    /// The defaults `launching()` gives the model (preview mode's own, else the app's). The App scene's `@AppStorage`
    /// for the status item reads the same store the model writes.
    static var launchDefaults: UserDefaults {
        #if DEBUG
        if LaunchOptions(defaults: .standard).usesPreviewEngine { return previewDefaults }
        #endif
        return .standard
    }

    /// For `#Preview`s.
    static func preview(showsOnboarding: Bool = false) -> AppModel {
        AppModel(options: LaunchOptions(usesPreviewEngine: true, showsOnboarding: showsOnboarding), engine: BridgeEngine.preview(),
                 loginItems: InMemoryLoginItemService(), defaults: previewDefaults, previewLatency: .milliseconds(300))
    }

    var loginItemsAreSimulated: Bool { loginItems is InMemoryLoginItemService }

    static func describe(_ error: any Error) -> String { ErrorText.describe(error) }

    // MARK: Lifecycle

    var hasCompletedOnboarding: Bool { defaults.bool(forKey: Self.onboardingCompletedKey) }

    /// First live launch, or `-showOnboarding YES`.
    var needsOnboarding: Bool { options.showsOnboarding || (!isPreview && !hasCompletedOnboarding) }

    /// The manager window opens at launch for onboarding or `-openManager YES`; otherwise CameraBridge starts in the
    /// menu bar only.
    var opensManagerAtLaunch: Bool { options.opensManagerAtLaunch || needsOnboarding }

    /// Called from `applicationDidFinishLaunching`: requests the manager window (onboarding or `-openManager YES`),
    /// presents onboarding on first run and starts the live engine. Starting before onboarding is safe without cameras:
    /// such a bridge opens no connection and advertises nothing, and Add Camera waits behind the onboarding sheet. With
    /// cameras configured, a pending onboarding holds the engine until Get Started (`completeOnboarding`).
    func didFinishLaunching() {
        if opensManagerAtLaunch { showManager() }
        if options.opensSettingsAtLaunch { showSettings() }
        if needsOnboarding { presentedSheet = .onboarding }
        if !isPreview {
            log.notice("Camera Bridge \(Self.appVersion) launched")
            loadCameraProfiles()
            Task(priority: .userInitiated) {
                guard startsEngineAtLaunch else {
                    log.notice("The bridge starts after onboarding")
                    return
                }
                await engine.start()
                showManagerForRecoveredConfiguration()
            }
        }
    }

    /// Gives the engine the cached (or bundled) camera profiles at once, then asks the server for a newer feed when the
    /// last check was 24 hours ago or more. A failed refresh changes nothing.
    private func loadCameraProfiles() {
        guard let profileService else { return }
        engine.setCameraProfiles(profileService.currentFeed())
        Task(priority: .utility) { [engine] in
            if let feed = await profileService.refreshIfDue() { engine.setCameraProfiles(feed) }
        }
    }

    /// A damaged configuration was set aside (at this start or an earlier one, not dismissed yet): every camera is gone
    /// from the Home app, so the manager opens with its banner rather than leaving a login item launch in the menu bar.
    private func showManagerForRecoveredConfiguration() {
        guard case .configurationRecovered? = bridgeIssue else { return }
        showManager()
    }

    /// False only while onboarding is pending and cameras are configured: those cameras would connect and appear in
    /// the Home app while the guide is still explaining the prerequisites.
    var startsEngineAtLaunch: Bool { !(needsOnboarding && !engine.configurations.isEmpty) }

    func completeOnboarding() async {
        defaults.set(true, forKey: Self.onboardingCompletedKey)
        if presentedSheet == .onboarding { presentedSheet = nil }
        if !isPreview, engine.state == .stopped {
            await engine.start()
        }
    }

    /// "0.1.0 (1)" from the bundle.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }

    func presentOnboarding() {
        showManager()
        if presentedSheet == nil { presentedSheet = .onboarding }
    }

    /// Fix… for denied Local Network access (the banner, the menu bar): the check, its fix steps, Open Settings and Check
    /// Again in a sheet of their own. The welcome guide put them below five prerequisites, out of sight, with Get
    /// Started (which fixes nothing) as the only button in view.
    func presentLocalNetworkFix() {
        showManager()
        if presentedSheet == nil { presentedSheet = .localNetworkAccess }
    }

    /// Forwarded from `applicationDidBecomeActive` (e.g. back from System Settings): refreshes the login item status and
    /// checks a denied Local Network access again at once.
    func applicationDidBecomeActive() {
        refreshLoginItemStatus()
        guard !isPreview, engine.localNetworkAccess == .denied else { return }
        keepCheckingLocalNetworkAccess(immediately: true)
    }

    /// Forwarded from `NSWorkspace.didWakeNotification`: the engine closes what the sleep left behind and reconnects the cameras.
    func systemDidWake() async {
        guard !isPreview else { return }
        await engine.systemDidWake()
    }

    /// Forwarded from `NSWorkspace.willSleepNotification`: the engine logs it and times the sleep.
    func systemWillSleep() {
        guard !isPreview else { return }
        engine.systemWillSleep()
    }

    /// Stops the engine before quitting, giving up after `terminationTimeLimit` even if the stop ignores cancellation.
    func prepareToTerminate() async {
        localNetworkRecheck?.cancel()
        localNetworkRecheck = nil
        localNetworkRecheckRun = nil
        isRecheckingLocalNetworkAccess = false
        guard !isPreview else { return }
        let engine = engine
        let stopped = await TimeLimit.run(Self.terminationTimeLimit) { await engine.stop() }
        if !stopped { log.warning("The bridge didn’t stop within 5 seconds; quitting anyway") }
    }

    // MARK: Navigation

    /// Opens the manager window at `selection` (default: keep the current page, else the first camera, else none: the
    /// "No Cameras Yet — Add Camera…" page).
    func showManager(selecting destination: ManagerSelection? = nil) {
        if let destination {
            selection = destination
        } else if selection == nil {
            selection = defaultSelection
        }
        if let windowOpener {
            windowOpener()
        } else {
            pendingManagerOpen = true
        }
    }

    /// Opens the Settings window (app-wide preferences: login item, keep awake, webhook, logging, about).
    /// The Diagnostics page's bundle: this engine's state, cameras, sessions and log (`DiagnosticsReport`).
    func diagnosticsReport() -> String {
        engine.diagnosticsReport(context: DiagnosticsModel.context(launched: launchDate))
    }

    /// Export Diagnostics…: asks where to save the text bundle.
    func exportDiagnostics() {
        diagnostics.refresh()
        diagnostics.export { [self] in diagnosticsReport() }
    }

    func showSettings() {
        if let settingsOpener {
            settingsOpener()
        } else {
            pendingSettingsOpen = true
        }
    }

    /// The Overview (without cameras it shows the empty state with Add Camera…).
    var defaultSelection: ManagerSelection? { .overview }

    /// The camera shown in the full-window viewer (double-click or expand on the Overview, the camera page's full-screen
    /// button), nil when none is.
    var expandedCameraID: UUID?

    func expandCamera(_ id: UUID) {
        expandedCameraID = id
    }

    func closeExpandedCamera() {
        expandedCameraID = nil
    }

    /// Opens the camera's page (from a tile's info area or the viewer's "Open camera settings").
    func openCameraPage(_ id: UUID) {
        expandedCameraID = nil
        selection = .camera(id)
    }

    /// The app's own live viewer: the engine's encoded live video for a camera (`BridgeEngine.liveVideo`).
    var liveVideoOpener: LiveVideoOpener {
        { [engine] id, stream, audio, width in try await engine.liveVideo(cameraID: id, stream: stream, audio: audio, displayWidth: width) }
    }

    /// Where view preferences (Play All) are remembered: the live app's defaults, or the preview mode's own.
    var preferences: UserDefaults { defaults }

    /// Opens the manager with the Add Camera sheet, unless another sheet (onboarding) is up.
    func showAddCamera() {
        showManager()
        if presentedSheet == nil { presentedSheet = .addCamera }
    }

    var isAddCameraPresented: Bool {
        get { presentedSheet == .addCamera }
        set { setSheet(.addCamera, presented: newValue) }
    }

    var isOnboardingPresented: Bool {
        get { presentedSheet == .onboarding }
        set { setSheet(.onboarding, presented: newValue) }
    }

    private func setSheet(_ sheet: ManagerSheet, presented: Bool) {
        if presented {
            presentedSheet = sheet
        } else if presentedSheet == sheet {
            presentedSheet = nil
        }
    }

    func managerWindowDidAppear() {
        isManagerWindowOpen = true
    }

    /// Drops an alert the window can no longer show, so it doesn't pop up the next time the window opens.
    func managerWindowDidDisappear() {
        isManagerWindowOpen = false
        message = nil
    }

    // MARK: Bridge

    /// What's wrong with the bridge as a whole (start failure, a damaged configuration set aside, Local Network denied, a
    /// webhook that isn't listening), if anything: the manager's banner, and the menu bar's symbol, VoiceOver label and
    /// menu item.
    var bridgeIssue: BridgeIssue? {
        BridgeIssue.current(state: engine.state, localNetworkAccess: engine.localNetworkAccess, configurationBackup: engine.configurationRecoveredFrom,
                            webhookProblem: engine.webhookProblem)
    }

    // MARK: Sensors in the sidebar

    /// Opens the Sensors page, on `cameraID`'s sensors (a sensor or camera row in the sidebar), or on all of it (nil).
    func showSensors(for cameraID: UUID?) {
        sensorsFocus = cameraID
        selection = .sensorsBridge
    }

    /// The sidebar's sensor groups for what the engine publishes now.
    func sensorGroups(now: Date = Date()) -> [SidebarSensorGroup] {
        SensorsSidebar.groups(configurations: engine.configurations, published: engine.sensorsBridge?.publishedSensors, statuses: engine.cameras, now: now)
    }

    func isSensorGroupExpanded(_ group: SidebarSensorGroup) -> Bool {
        SensorsSidebar.isExpanded(group, overrides: sensorGroupOverrides)
    }

    func setSensorGroup(_ group: SidebarSensorGroup, expanded: Bool) {
        sensorGroupOverrides[group.id] = expanded
        defaults.set(Dictionary(uniqueKeysWithValues: sensorGroupOverrides.map { ($0.key.uuidString, $0.value) }), forKey: Self.sensorGroupsKey)
    }

    // MARK: VPN notices

    /// The VPN findings the engine reports (a device that watches live view on a VPN, this Mac on a VPN), worst first: the
    /// menu bar lines and Settings › Network.
    var networkMessages: [NetworkNoticeMessage] {
        NetworkNoticeMessage.messages(for: engine.recentNetworkNotices)
    }

    /// The first of them the banner may show now (once per device and day, not dismissed).
    var networkBanner: NetworkNoticeMessage? {
        let now = Date()
        return networkMessages.first { networkThrottle.allows($0, now: now) }
    }

    /// The banner went on screen: its day's one showing is used up.
    func networkBannerAppeared(_ message: NetworkNoticeMessage) {
        networkThrottle.noteShown(message, now: Date())
        saveNetworkThrottle()
    }

    func dismissNetworkBanner(_ message: NetworkNoticeMessage) {
        networkThrottle.dismiss(message, now: Date())
        saveNetworkThrottle()
    }

    private func saveNetworkThrottle() {
        guard !isPreview else { return }
        defaults.set(try? JSONEncoder().encode(networkThrottle), forKey: Self.networkThrottleKey)
    }

    /// Learn More (the banner, the menu bar, Settings) for a VPN finding.
    func presentVPNHelp() {
        showManager()
        if presentedSheet == nil { presentedSheet = .vpnHelp }
    }

    /// Learn More for the notice of `kind`: each kind opens its own help (the two VPN kinds the VPN steps).
    func presentNetworkHelp(for kind: NetworkNotice.Kind) {
        switch kind {
        case .controllerOnVPN, .macOnVPN:
            presentVPNHelp()
        case .liveViewNotReceived, .localNetworkDenied, .dualHomedSubnet:
            showManager()
            if presentedSheet == nil { presentedSheet = .networkHelp(kind) }
        }
    }

    /// The banner's action: Try Again starts the engine (or the webhook); Fix… opens the Local Network sheet; Show in
    /// Finder shows the damaged configuration file that was set aside (and dismisses the banner).
    func resolve(_ issue: BridgeIssue) async {
        switch issue {
        case .startFailed:
            guard !skipInPreview(issue.actionTitle) else { return }
            await engine.start()
        case .localNetworkDenied:
            presentLocalNetworkFix()
        case .configurationRecovered(let backup):
            guard !skipInPreview(issue.actionTitle) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([backup])
            await engine.acknowledgeConfigurationRecovery()
        case .webhookNotListening:
            await retryWebhook()
        }
    }

    /// Try Again for a webhook that isn't listening (the banner, Settings, a camera page).
    func retryWebhook() async {
        guard !skipInPreview(String(localized: "Try Again")) else { return }
        await engine.retryWebhook()
    }

    /// The menu bar's item for `issue`: opens the manager, whose banner explains it and has its action (Fix… opens the
    /// Local Network sheet directly; a webhook problem opens Settings, next to the webhook's settings).
    func show(_ issue: BridgeIssue) {
        switch issue {
        case .localNetworkDenied: presentLocalNetworkFix()
        case .webhookNotListening: showSettings()
        case .startFailed, .configurationRecovered: showManager()
        }
    }

    /// Pause when running, resume when paused, start when stopped or failed.
    func toggleBridgeRunning() async {
        let title = StatusText.pauseResumeTitle(engine.state)
        guard !skipInPreview(title) else { return }
        switch engine.state {
        case .running, .starting: await engine.pause()
        case .paused: await engine.resume()
        case .stopped, .failed: await engine.start()
        }
    }

    var keepMacAwake: Bool { engine.settings.keepMacAwake }

    func setKeepMacAwake(_ on: Bool) async {
        await updateSettings(String(localized: "Keep Mac Awake")) { $0.keepMacAwake = on }
    }

    /// Settings › Diagnostics › "Compare built-in motion detection with camera events (test)": the engine's `motionShadowTest`
    /// setting, which it saves in config.json. Off by default.
    var motionShadowTest: Bool { engine.settings.motionShadowTest }

    func setMotionShadowTest(_ on: Bool) async {
        await updateSettings(String(localized: "Motion Detection Comparison")) { $0.motionShadowTest = on }
    }

    /// Applies a settings change through the engine (which persists it). Returns whether it was applied.
    ///
    /// The engine applies `change` to its settings when the change's turn comes, not to a copy taken now: two changes
    /// made while the engine is busy (starting, adding a camera, saving the previous change) both stick instead of the
    /// second undoing the first.
    @discardableResult
    func updateSettings(_ action: String = String(localized: "Settings change"), _ change: (inout BridgeSettings) -> Void) async -> Bool {
        guard !skipInPreview(action) else { return false }
        var preview = engine.settings
        change(&preview)
        guard preview != engine.settings else { return true }   // nothing to change now
        do {
            try await writeSettings(change)
            return true
        } catch {
            fail(String(localized: "Couldn’t Change Settings"), error)
            return false
        }
    }

    // MARK: Dock and Menu Bar

    /// Shows or hides CameraBridge in the Dock or the menu bar. Turning off the last one is refused (Settings disables
    /// that switch), so the app always stays reachable.
    func setPresence(_ place: AppPresence.Place, to on: Bool) {
        let new = presence.setting(place, to: on)
        guard new != presence else { return }
        presence = new
        new.save(to: defaults)
        presenceHandler?(new)
    }

    // MARK: Launch at Login

    /// On while registered, also while it waits for approval in System Settings (Settings and the menu say so).
    var launchAtLogin: Bool {
        let status = loginItemStatus
        return status == .enabled || status == .requiresApproval
    }

    /// Redraws what shows the login item's status when it changed (the menu opening, Settings appearing, the app
    /// becoming active, a toggle).
    func refreshLoginItemStatus() {
        let status = loginItems.status
        if loginItemStatusShown != status { loginItemStatusShown = status }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try loginItems.register() } else { try loginItems.unregister() }
        } catch {
            fail(String(localized: "Couldn’t Change Launch at Login"), error)
        }
        refreshLoginItemStatus()
        if on, loginItemStatus == .requiresApproval {
            loginItems.openSystemSettings()
        }
    }

    func openLoginItemsSettings() {
        loginItems.openSystemSettings()
    }

    // MARK: Cameras

    func configuration(for id: UUID) -> CameraConfiguration? {
        engine.configurations.first { $0.id == id }
    }

    func status(for id: UUID) -> CameraStatus? {
        engine.cameras.first { $0.id == id }
    }

    /// `password` nil = unchanged. Returns whether the engine applied the change (false in preview mode or on error,
    /// which is shown).
    @discardableResult
    func updateCamera(_ configuration: CameraConfiguration, password: String? = nil) async -> Bool {
        do {
            try await applyCameraUpdate(configuration, password: password, showsFailure: true)
            return true
        } catch {
            return false
        }
    }

    /// Sends a camera change to the engine; throws why it wasn't applied (in preview mode: `PreviewModeSkip`, after the
    /// usual notice). `showsFailure`: the engine's error is also shown as the window's alert; false when the caller shows
    /// it itself (the Connection sheet: an alert would wait behind the sheet until it closes).
    func applyCameraUpdate(_ configuration: CameraConfiguration, password: String?, showsFailure: Bool) async throws {
        let action = String(localized: "Camera changes")
        guard !skipInPreview(action) else { throw PreviewModeSkip(action: action) }
        let title = String(localized: "Couldn’t Update “\(configuration.name)”")
        do {
            try await engine.updateCamera(configuration, password: password)
        } catch {
            if showsFailure {
                fail(title, error)
            } else {
                log.warning("\(Redact.string(title)): \(ErrorText.logDescription(error))")
            }
            throw error
        }
    }

    /// Removes the camera. The engine keeps a camera whose removal it couldn't save (with its password and HomeKit
    /// identity): that shows as an alert, and the page goes back to the camera.
    func removeCamera(id: UUID) async {
        guard !skipInPreview(String(localized: "Remove Camera")) else { return }
        let wasSelected = selection == .camera(id)
        if expandedCameraID == id { expandedCameraID = nil }
        if wasSelected { selection = .overview }
        await engine.removeCamera(id: id)
        guard let kept = configuration(for: id) else { return }
        if wasSelected, selection == .overview { selection = .camera(id) }   // unless the person went elsewhere meanwhile
        fail(String(localized: "Couldn’t Remove “\(kept.name)”"), CameraRemovalError.notSaved)
    }

    func resetPairing(cameraID: UUID) async {
        guard !skipInPreview(String(localized: "Reset Pairing")) else { return }
        do {
            try await engine.resetPairing(cameraID: cameraID)
        } catch {
            fail(String(localized: "Couldn’t Reset Pairing"), error)
        }
    }

    func resetSensorsBridgePairing() async {
        guard !skipInPreview(String(localized: "Reset Pairing")) else { return }
        do {
            try await engine.resetSensorsBridgePairing()
        } catch {
            fail(String(localized: "Couldn’t Reset Pairing"), error)
        }
    }

    /// The camera page's Trigger Motion: a real motion event in the Home app (a recording, notifications), sent only
    /// while the camera's accessory is published — otherwise the button is off and says why (`testMotionBlocker`).
    func triggerTestMotion(cameraID: UUID) async {
        guard !skipInPreview(String(localized: "Trigger Motion")) else { return }
        guard testMotionBlocker(for: cameraID) == nil else { return }
        await engine.triggerTestMotion(cameraID: cameraID)
    }

    /// Why Trigger Motion can't reach the Home app now, or nil: the same reasons the camera's code isn't offered
    /// (`PairingBlocker`: the bridge paused or stopped, the camera off, its accessory not running).
    func testMotionBlocker(for cameraID: UUID) -> PairingBlocker? {
        guard configuration(for: cameraID) != nil else { return nil }
        return pairingBlocker(for: cameraID)
    }

    /// The camera page's webhook notice: why the webhook can't take this camera's events, while it isn't listening
    /// (`BridgeEngine.webhookProblem`), stronger for a camera that depends on it (`WebhookSettings.dependsOnWebhook`).
    func webhookNotice(for cameraID: UUID) -> String? {
        guard let problem = engine.webhookProblem, let configuration = configuration(for: cameraID) else { return nil }
        return WebhookSettings.cameraNotice(problem: Redact.string(problem), for: configuration)
    }

    /// Check Access: triggers the Local Network prompt if needed and reports the result. Before any answer is known the
    /// engine waits up to `localNetworkAnswerWait` for the person to answer the system's alert (connections are blocked
    /// until then), so a prompt still on screen isn't reported as a denial. A denial is then checked again in the
    /// background until access is allowed. Preview mode reports the sample state.
    func checkLocalNetworkAccess() async -> LocalNetworkCheckOutcome {
        if isPreview {
            try? await Task.sleep(for: previewLatency)
            return .checked(engine.localNetworkAccess)
        }
        let outcome = await checkLocalNetworkTargets(answerWait: localNetworkAnswerWait)
        if outcome == .noNetwork { log.notice("Local Network check: no camera is configured and no router was found") }
        if outcome == .checked(.denied) { keepCheckingLocalNetworkAccess(immediately: false) }
        return outcome
    }

    /// Connects to each target in turn (`localNetworkCheckCameraHosts`, then the router) until one gives an answer: a
    /// camera that is unplugged or offline only times out (`.unknown`), which says nothing about Local Network access, so
    /// the next one is tried — after a denial, the router answering is what clears it. `.noNetwork` when there was no
    /// target at all (nothing was sent).
    private func checkLocalNetworkTargets(answerWait: Duration) async -> LocalNetworkCheckOutcome {
        let cameras = localNetworkCheckCameraHosts
        for host in cameras {
            let access = await engine.checkLocalNetworkAccess(host: host, answerWait: answerWait)
            if access != .unknown || Task.isCancelled { return .checked(access) }
        }
        guard let router = await gatewayAddress(), !cameras.contains(router) else { return cameras.isEmpty ? .noNetwork : .checked(.unknown) }
        return .checked(await engine.checkLocalNetworkAccess(host: router, answerWait: answerWait))
    }

    /// While the engine reports Local Network access as denied, checks again every `localNetworkRecheckInterval`
    /// (first at once when `immediately`), one attempt per target until one answers (`checkLocalNetworkTargets`: an
    /// unplugged camera doesn't keep the denial): once the person allows access, the banner and the menu bar warning clear
    /// by themselves — also without cameras, whose connections would otherwise notice it. Stops when access is no longer
    /// denied or at quit.
    func keepCheckingLocalNetworkAccess(immediately: Bool) {
        guard !isPreview else { return }
        localNetworkRecheck?.cancel()
        let interval = localNetworkRecheckInterval
        let run = UUID()
        localNetworkRecheckRun = run
        isRecheckingLocalNetworkAccess = true
        localNetworkRecheck = Task { [weak self] in
            defer { self?.localNetworkRecheckEnded(run) }
            var waits = !immediately
            while !Task.isCancelled {
                if waits {
                    do { try await Task.sleep(for: interval) } catch { return }
                }
                waits = true
                guard let model = self, model.engine.localNetworkAccess == .denied else { return }
                _ = await model.checkLocalNetworkTargets(answerWait: .zero)
            }
        }
    }

    private func localNetworkRecheckEnded(_ run: UUID) {
        guard localNetworkRecheckRun == run else { return }
        localNetworkRecheck = nil
        isRecheckingLocalNetworkAccess = false
    }

    /// The Local Network check's first targets: every enabled camera on the network, each address once, in order. The
    /// router (`gatewayAddress`) comes after them, looked up only when none of them answered (or none exists: first
    /// run); with neither, Check Access reports `.noNetwork` without connecting anywhere.
    var localNetworkCheckCameraHosts: [String] {
        var seen = Set<String>()
        return engine.configurations.filter { $0.isEnabled && $0.vendor != .demo && $0.vendor != .go2rtc }.map(\.endpoint.host)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Camera profiles (Settings › Privacy)

    /// Re-reads the feed in use and its last check (Settings appearing, a check finishing).
    func refreshCameraProfileStatus() {
        let status = profileService?.status()
        if status != cameraProfileStatus { cameraProfileStatus = status }
    }

    /// Check Now: asks the server for a newer feed whatever the last check was, gives the engine a new one at once and
    /// keeps what it found for the Settings page. Preview mode skips it with the usual notice.
    func checkCameraProfilesNow() async {
        guard let profileService, !isCheckingCameraProfiles, !skipInPreview(String(localized: "Check Now")) else { return }
        isCheckingCameraProfiles = true
        cameraProfileCheckResult = nil
        defer { isCheckingCameraProfiles = false }
        let outcome = await profileService.refresh(force: true)
        if case .updated(let feed) = outcome { engine.setCameraProfiles(feed) }
        cameraProfileCheckResult = outcome
        refreshCameraProfileStatus()
    }

    // MARK: Data folder (Settings › Diagnostics)

    /// Where the live app keeps its configuration and logs: ~/Library/Application Support/CameraBridge.
    static var defaultDataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appending(path: "CameraBridge", directoryHint: .isDirectory)
    }

    /// Show in Finder: the data folder itself. Nothing is created: a folder that isn't there yet (before the first start)
    /// is reported as an alert.
    func revealDataFolder() {
        guard !skipInPreview(String(localized: "Show Data Folder")) else { return }
        guard FileManager.default.fileExists(atPath: dataDirectory.path) else {
            fail(String(localized: "Couldn’t Show the Data Folder"), DataFolderError.missing)
            return
        }
        NSWorkspace.shared.open(dataDirectory)
    }

    // MARK: Messages

    /// Shows `error` in an alert on the manager window, and opens or brings forward the window: a menu bar action leaves
    /// this agent app inactive, so an alert on a window that is open but behind other apps (or on another Space) would go
    /// unseen. `showManager` activates the app; the manager is a single window, so this never opens a second one.
    func fail(_ title: String, _ error: any Error) {
        let detail = ErrorText.describe(error)   // redacted
        log.warning("\(Redact.string(title)): \(ErrorText.logDescription(error))")
        message = AppMessage(title: title, detail: detail)
        showManager()
    }

    /// In preview mode, skips `action` with a short notice and returns true (`PreviewModeSkip` has the same text).
    func skipInPreview(_ action: String) -> Bool {
        guard isPreview else { return false }
        showNotice(Self.previewSkipText(action))
        return true
    }

    /// What `skipInPreview` says, as an error for a caller that shows failures itself.
    nonisolated struct PreviewModeSkip: LocalizedError {
        var action: String
        var errorDescription: String? { AppModel.previewSkipText(action) }
    }

    nonisolated static func previewSkipText(_ action: String) -> String {
        String(localized: "Preview mode: “\(action)” isn’t applied to sample data.")
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

// MARK: - Add Camera wizard

extension AppModel: CameraSetupService {
    var localNetworkAccess: LocalNetworkAccess { engine.localNetworkAccess }

    var configuredCameras: [CameraConfiguration] { engine.configurations }

    /// WS-Discovery. Often the first local network traffic (Check Access in onboarding is optional), and packets are
    /// dropped while the system's Local Network alert waits for an answer: before the first search, Check Access runs
    /// (it waits for the answer), so the search isn't lost to a prompt still on screen and a denial shows as the bridge
    /// issue (checked again in the background). With access denied there is nothing to search.
    func discoverCameras() async -> [DiscoveredCamera] {
        if isPreview {
            try? await Task.sleep(for: previewLatency)
            return PreviewFixtures.discovered
        }
        if engine.localNetworkAccess == .unknown { _ = await checkLocalNetworkAccess() }
        guard engine.localNetworkAccess != .denied else {
            log.notice("Camera search skipped: Local Network access is denied")
            return []
        }
        return await engine.discoverCameras()
    }

    /// The engine's probe; a camera unreachable because of Local Network privacy throws `.localNetworkDenied`, and the
    /// denial is then checked again in the background (the banner clears once the person allows access).
    func probeCamera(vendor: CameraVendor?, endpoint: CameraEndpoint, username: String, password: String,
                     mainStreamURL: URL?, subStreamURL: URL?) async throws -> CameraProbeResult {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            return PreviewFixtures.probeResult(vendor: vendor, endpoint: endpoint, mainStreamURL: mainStreamURL, subStreamURL: subStreamURL)
        }
        do {
            return try await engine.probeCamera(vendor: vendor, endpoint: endpoint, username: username, password: password,
                                                mainStreamURL: mainStreamURL, subStreamURL: subStreamURL)
        } catch TransportError.localNetworkDenied {
            if !isRecheckingLocalNetworkAccess { keepCheckingLocalNetworkAccess(immediately: false) }
            throw TransportError.localNetworkDenied
        }
    }

    /// A camera behind a service: the engine's check through the go2rtc helper. Preview mode answers from the fixtures.
    func probeIntegration(vendor: CameraVendor, integration: IntegrationSettings, endpoint: CameraEndpoint, username: String,
                          secret: String) async throws -> CameraProbeResult {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            return PreviewFixtures.integrationProbeResult(vendor: vendor, integration: integration, endpoint: endpoint)
        }
        return try await engine.probeIntegration(vendor: vendor, integration: integration, endpoint: endpoint, username: username, secret: secret)
    }

    func unifiProtectCameras(endpoint: CameraEndpoint, apiKey: String) async throws -> [UnifiProtectCamera] {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            return PreviewFixtures.protectCameras
        }
        return try await CameraDrivers.unifiProtectCameras(endpoint: endpoint, apiKey: apiKey)
    }

    var isStreamingHelperInstalled: Bool { isPreview ? true : engine.isStreamingHelperInstalled }

    func beginIntegrationSignIn() async throws -> URL {
        if isPreview { throw EngineError.cameraNotRunning }
        return try await engine.beginIntegrationSetup()
    }

    func endIntegrationSignIn() async {
        if !isPreview { await engine.endIntegrationSetup() }
    }

    /// The camera detail's Connection sheet: checks `configuration` (a changed address, ports or stream URLs) with the
    /// camera's stored password before it is saved. Preview mode answers from the fixtures.
    func probeConfiguredCamera(_ configuration: CameraConfiguration) async throws -> CameraProbeResult {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            return PreviewFixtures.probeResult(vendor: configuration.vendor, endpoint: configuration.endpoint,
                                               mainStreamURL: configuration.mainStreamURL, subStreamURL: configuration.subStreamURL)
        }
        do {
            return try await engine.probeCamera(configuration, password: nil)
        } catch TransportError.localNetworkDenied {
            if !isRecheckingLocalNetworkAccess { keepCheckingLocalNetworkAccess(immediately: false) }
            throw TransportError.localNetworkDenied
        }
    }

    /// The Camera Settings sheet's Load: the camera's own ONVIF video/imaging settings (or just its web page address
    /// when it has no ONVIF service). Preview mode answers from fixtures.
    func cameraSettings(cameraID: UUID) async throws -> CameraSettingsSnapshot {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            let configuration = configuration(for: cameraID)
            return PreviewFixtures.cameraSettingsSnapshot(endpoint: configuration?.endpoint ?? CameraEndpoint(host: "192.0.2.31"),
                                                           vendor: configuration?.vendor, cameraName: configuration?.name)
        }
        return try await engine.cameraSettings(cameraID: cameraID)
    }

    /// The Camera Settings sheet's Save. Preview mode just waits, as if it saved.
    func applyCameraSettings(cameraID: UUID, _ change: CameraSettingsChange) async throws {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            return
        }
        try await engine.applyCameraSettings(cameraID: cameraID, change)
    }

    /// The Camera Settings sheet's Restart (behind a confirmation). Preview mode just waits.
    func rebootCamera(cameraID: UUID) async throws {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            return
        }
        try await engine.rebootCamera(cameraID: cameraID)
    }

    /// The camera page's "Hide the Camera's Own Clock" toggle: turns the camera's own on-screen date and time off or back on
    /// (the engine remembers how, to put it back). Returns what happened (a camera that cannot do it is a result, not an
    /// error), or nil when the request was skipped (preview mode) or failed with an alert.
    func setCameraClockHidden(cameraID: UUID, hidden: Bool) async -> CameraClockChange? {
        if skipInPreview(String(localized: "Changing the camera’s own clock")) { return nil }
        do {
            return try await engine.setCameraClockHidden(cameraID: cameraID, hidden: hidden)
        } catch is CancellationError {
            return nil
        } catch {
            fail(String(localized: "Couldn’t change the camera’s own clock"), error)
            return nil
        }
    }

    /// The Add Camera wizard's HomeKit Readiness summary, right after a successful probe (the camera isn't
    /// configured yet). Preview mode grades a fixture snapshot.
    func homeKitReadiness(vendor: CameraVendor, endpoint: CameraEndpoint, username: String, password: String) async throws -> HomeKitReadinessReport {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            let snapshot = PreviewFixtures.cameraSettingsSnapshot(endpoint: endpoint, vendor: vendor)
            return HomeKitReadinessAdvisor.evaluate(vendor: vendor, deviceInfo: snapshot.deviceInfo, snapshot: snapshot)
        }
        let credentials = username.isEmpty && password.isEmpty ? nil : HTTPCredentials(username: username, password: password)
        return try await engine.homeKitReadiness(vendor: vendor, endpoint: endpoint, credentials: credentials)
    }

    /// The HomeKit Readiness card's grading of this camera. Preview mode grades the fixture snapshot (no engine call).
    func homeKitReadiness(cameraID: UUID, recheck: Bool = false) async throws -> HomeKitReadinessReport {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            let configuration = configuration(for: cameraID)
            let snapshot = PreviewFixtures.cameraSettingsSnapshot(endpoint: configuration?.endpoint ?? CameraEndpoint(host: "192.0.2.31"),
                                                                   vendor: configuration?.vendor, cameraName: configuration?.name)
            return HomeKitReadinessAdvisor.evaluate(vendor: configuration?.vendor ?? .onvif, deviceInfo: snapshot.deviceInfo, snapshot: snapshot)
        }
        return try await engine.homeKitReadiness(cameraID: cameraID, recheck: recheck)
    }

    /// "Optimize for HomeKit…"'s confirmation sheet applies its changes through this. Preview mode fakes a clean
    /// before/after without touching anything.
    func optimizeForHomeKit(cameraID: UUID) async throws -> HomeKitOptimizationResult {
        if isPreview {
            try await Task.sleep(for: previewLatency * 3)
            let before = try await homeKitReadiness(cameraID: cameraID)
            let fixedUp = HomeKitReadinessReport(checks: before.checks.map { check in
                var fixed = check
                if case .automatic = check.fixMethod { fixed.status = .ok }
                return fixed
            })
            var applied = before.checks.filter { if case .automatic = $0.fixMethod { true } else { false } }.map(\.id)
            #if DEBUG
            // `-demoOptimizeFailures YES`: a run where the camera refused one change (UI review of the failure list).
            if UserDefaults.standard.bool(forKey: "demoOptimizeFailures"),
               let failed = applied.first(where: { $0 == "frameRate" || $0 == "bitrate" }) ?? applied.last {
                applied.removeAll { $0 == failed }
                let after = HomeKitReadinessReport(checks: before.checks.map { check in
                    var fixed = check
                    if case .automatic = check.fixMethod, check.id != failed { fixed.status = .ok }
                    return fixed
                })
                let failure = HomeKitOptimizationFailure(checkID: failed, reason: "ONVIF minimal: InvalidArgVal (the camera refused the value); ONVIF full: not supported by this camera")
                return HomeKitOptimizationResult(before: before, after: after, appliedFixes: applied, failedFixes: [failure],
                                                 fixMethods: Dictionary(uniqueKeysWithValues: applied.map { ($0, CameraConfigMethod.onvifMinimal) }),
                                                 canUndo: !applied.isEmpty, mayNeedRecordingReEnabled: true)
            }
            #endif
            return HomeKitOptimizationResult(before: before, after: fixedUp, appliedFixes: applied, canUndo: !applied.isEmpty)
        }
        return try await engine.optimizeForHomeKit(cameraID: cameraID)
    }

    /// Undoes the last `optimizeForHomeKit(cameraID:)` on this camera. Preview mode just waits.
    func undoHomeKitOptimization(cameraID: UUID) async throws {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            return
        }
        try await engine.undoHomeKitOptimization(cameraID: cameraID)
    }

    /// What to do about a setup report after an Optimize run.
    enum SetupReportOffer: Equatable {
        /// Nothing worth reporting (everything fixed, or sample data).
        case none
        /// "Help improve camera support" is on: the report was sent without asking.
        case sentAutomatically
        /// Ask first, showing exactly this report.
        case ask(SetupReport)
    }

    /// The setup report for an Optimize run: the camera's brand, model and firmware as the configuration remembers them,
    /// the readiness results and which ways of changing its settings worked or failed. Nothing that identifies the person
    /// or the camera (see `SetupReport`).
    func setupReport(for result: HomeKitOptimizationResult, cameraID: UUID) -> SetupReport {
        let configuration = configuration(for: cameraID)
        let manufacturer = configuration?.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let vendor = manufacturer.isEmpty ? (configuration?.vendor.rawValue ?? "unknown") : manufacturer
        return SetupReport(result: result, vendor: vendor, model: configuration?.model, firmware: configuration?.firmware,
                           appVersion: "\(AppInfo.shortVersion) (\(AppInfo.build))", osVersion: AppInfo.osVersion)
    }

    /// Decides what happens after Optimize: with the Settings switch on, a report about failed or manual-only fixes is
    /// sent at once; otherwise the sheet asks once, showing the exact JSON. Never sends in preview mode.
    func offerSetupReport(for result: HomeKitOptimizationResult, cameraID: UUID) -> SetupReportOffer {
        guard !isPreview else { return .none }
        let report = setupReport(for: result, cameraID: cameraID)
        guard report.hasUnresolvedFixes else { return .none }
        if sharesSetupReports {
            Task { _ = await sendSetupReport(report) }
            return .sentAutomatically
        }
        return .ask(report)
    }

    /// Sends a report the person approved (or the Settings switch covers). Fails silently: a log line, no alert.
    @discardableResult
    func sendSetupReport(_ report: SetupReport) async -> Bool {
        guard !isPreview, let body = try? report.encoded() else { return false }
        return await reportSender.send(body)
    }

    /// Why the camera's code isn't offered (`PairingBlocker`), or nil when its accessory is published or the camera is
    /// unknown. Preview mode: cameras "added" through the wizard are offered.
    func pairingBlocker(for cameraID: UUID) -> PairingBlocker? {
        if isPreview, previewAddedKinds[cameraID] != nil { return nil }
        guard let configuration = configuration(for: cameraID) else { return nil }
        return PairingBlocker.current(state: engine.state, isEnabled: configuration.isEnabled, hapPort: status(for: cameraID)?.hapPort)
    }

    /// The blocker's action (Resume Bridge, Start Bridge). Never pauses: the bridge may have started meanwhile.
    func resolve(_ action: PairingBlocker.Action) async {
        guard !skipInPreview(action.title) else { return }
        switch action {
        case .resumeBridge: await engine.resume()
        case .startBridge: await engine.start()
        }
    }

    func addCamera(_ configuration: CameraConfiguration, password: String?) async throws {
        if isPreview {
            try await Task.sleep(for: previewLatency)
            previewAddedKinds[configuration.id] = configuration.kind
            showNotice(String(localized: "Preview mode: “\(configuration.name)” isn’t added to the sample data."))
            return
        }
        try await engine.addCamera(configuration, password: password)
        selection = .camera(configuration.id)
    }

    func pairingCode(for cameraID: UUID) -> PairingCode? {
        if isPreview, let kind = previewAddedKinds[cameraID] {
            // Show a sample code of the same accessory kind.
            let sample = engine.cameras.first { $0.kind == kind && !$0.isPaired } ?? engine.cameras.first
            return sample.map { PairingCode(setupCode: $0.setupCode, setupURI: $0.setupURI) }
        }
        guard let status = status(for: cameraID), !status.setupURI.isEmpty else { return nil }
        return PairingCode(setupCode: status.setupCode, setupURI: status.setupURI)
    }
}
