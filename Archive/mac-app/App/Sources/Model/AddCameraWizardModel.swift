import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import Observation
import RTSP

/// Wizard pages, in order. `pairing` follows a successful add and is not numbered. `discover` is skipped for cameras that are not
/// searched for on the network (cloud cameras, consoles, an RTSP URL).
enum WizardStep: Int, CaseIterable, Comparable {
    case cameraType, discover, connect, probe, kind, motion, features, summary, pairing

    static func < (lhs: WizardStep, rhs: WizardStep) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .cameraType: String(localized: "Camera Type")
        case .discover: String(localized: "Find Your Camera")
        case .connect: String(localized: "Connect")
        case .probe: String(localized: "Check the Camera")
        case .kind: String(localized: "Camera or Doorbell")
        case .motion: String(localized: "Motion")
        case .features: String(localized: "Sensors and Audio")
        case .summary: String(localized: "Review")
        case .pairing: String(localized: "Add to Apple Home")
        }
    }
}

/// The engine route a camera type takes. `automatic` tries Hikvision ISAPI, Reolink API, then ONVIF.
enum VendorChoice: String, CaseIterable, Identifiable {
    case automatic, hikvision, reolink, onvif, rtspURL, demo
    case amcrest, doorbird, unifi, go2rtc

    var id: Self { self }

    var vendor: CameraVendor? {
        switch self {
        case .automatic: nil
        case .hikvision: .hikvision
        case .reolink: .reolink
        case .onvif: .onvif
        case .rtspURL: .rtsp
        case .demo: .demo
        case .amcrest: .amcrest
        case .doorbird: .doorbird
        case .unifi: .unifi
        case .go2rtc: .go2rtc
        }
    }

    /// Reached by an address on the network (as opposed to a stream URL, a cloud source or nothing).
    var usesAddress: Bool {
        switch self {
        case .automatic, .hikvision, .reolink, .onvif, .amcrest, .doorbird, .unifi: true
        case .rtspURL, .demo, .go2rtc: false
        }
    }

    var title: String {
        switch self {
        case .automatic: String(localized: "Detect Automatically")
        case .hikvision: "Hikvision"
        case .reolink: "Reolink"
        case .onvif: "ONVIF"
        case .rtspURL: String(localized: "RTSP URL")
        case .demo: String(localized: "Demo Camera")
        case .amcrest: String(localized: "Amcrest / Dahua")
        case .doorbird: "DoorBird"
        case .unifi: "UniFi Protect"
        case .go2rtc: String(localized: "Cloud Camera")
        }
    }
}

/// State and rules of the Add Camera wizard: discover → connect → probe → camera/doorbell → motion → sensors and
/// audio → review → `addCamera` → QR code. The view only renders it.
///
/// Work started from the sheet's buttons runs in tasks the model keeps (`startForward`, `startProbe`,
/// `startDiscovery`), so `cancel()` (Cancel, or the sheet going away) stops discovery and probing — the camera isn't
/// contacted with the entered credentials after the person has left. An add already under way is left to finish.
@MainActor @Observable
final class AddCameraWizardModel {
    enum ProbeState: Equatable {
        case idle, probing
        case succeeded(CameraProbeResult)
        case failed(String)
    }

    enum AddState: Equatable {
        case idle, adding, added
        case failed(String)
    }

    static let kindChangeWarning = String(localized: "Choose carefully: changing between Camera and Video Doorbell later means removing the accessory from the Home app and re-adding it.")
    static let stepCount = WizardStep.summary.rawValue + 1

    let cameraID = UUID()
    @ObservationIgnored private let service: any CameraSetupService
    @ObservationIgnored private let log = Log(category: "App")

    private(set) var step: WizardStep = .cameraType

    // MARK: Discover
    /// Unique by host.
    private(set) var discovered: [DiscoveredCamera] = []
    private(set) var isDiscovering = false
    /// A search ran to the end (one stopped by `cancel()` doesn't count).
    private(set) var hasDiscovered = false
    private(set) var selectedDiscoveredHost: String?
    @ObservationIgnored private var discoveredName: String?
    /// The ONVIF port the selected discovered camera announced (its device service XAddr), while `onvifPort` holds it.
    @ObservationIgnored private var discoveredONVIFPort: Int?
    /// The search in progress, which every `discover()` caller shares.
    @ObservationIgnored private var search: Task<Void, Never>?

    var host = "" {
        didSet {
            guard host != oldValue else { return }
            if host.trimmingCharacters(in: .whitespaces) != selectedDiscoveredHost {
                selectedDiscoveredHost = nil
                discoveredName = nil
                if let port = discoveredONVIFPort, onvifPort == port { onvifPort = nil }   // the port belonged to that camera
                discoveredONVIFPort = nil
            }
            invalidateProbe()
        }
    }
    var vendorChoice: VendorChoice = .automatic {
        didSet {
            guard vendorChoice != oldValue else { return }
            if cameraType.vendorChoice != vendorChoice {   // chosen in code, not in the list
                isSyncingType = true
                cameraType = CameraType.standard(for: vendorChoice)
                isSyncingType = false
            }
            invalidateProbe()
        }
    }
    /// What the person chose on the Camera Type page; `vendorChoice` follows it.
    var cameraType: CameraType = .automatic {
        didSet {
            guard cameraType != oldValue else { return }
            if !isSyncingType, vendorChoice != cameraType.vendorChoice { vendorChoice = cameraType.vendorChoice }
            // A console is reached over HTTPS; everything else starts at plain HTTP (a port the person typed stays).
            let secure = cameraType == .unifiProtect
            if useHTTPS != secure { useHTTPS = secure }
            if cameraType == .unifiProtect { rtspPort = 7441 } else if oldValue == .unifiProtect { rtspPort = 554 }
            integrationState = .idle
            invalidateProbe()
        }
    }

    // MARK: Connect
    var httpPort = 80 { didSet { if httpPort != oldValue { invalidateProbe() } } }
    var rtspPort = 554 { didSet { if rtspPort != oldValue { invalidateProbe() } } }
    /// Where the ONVIF device service listens when it isn't the HTTP port (nil: the HTTP port, or found by the probe).
    var onvifPort: Int? { didSet { if onvifPort != oldValue { invalidateProbe() } } }
    /// Moves a default port with it (80 ↔ 443): the camera's API is reached at `https://host:httpPort`.
    var useHTTPS = false {
        didSet {
            guard useHTTPS != oldValue else { return }
            httpPort = Self.httpPort(httpPort, afterSwitchingHTTPS: useHTTPS)
            invalidateProbe()
        }
    }
    var username = "" { didSet { if username != oldValue { invalidateProbe() } } }
    var password = "" { didSet { if password != oldValue { invalidateProbe() } } }
    var mainStreamURLText = "" { didSet { if mainStreamURLText != oldValue { invalidateProbe() } } }
    var subStreamURLText = "" { didSet { if subStreamURLText != oldValue { invalidateProbe() } } }

    @ObservationIgnored private var isSyncingType = false

    // MARK: Integrations (cloud cameras and consoles)

    enum IntegrationState: Equatable {
        case idle, working
        case failed(String)
    }

    /// The go2rtc source the person pasted (Ring, Wyze, Tuya, other): a secret. Never logged, never saved but in the Keychain.
    var sourceText = "" { didSet { if sourceText != oldValue { invalidateProbe() } } }
    /// Google Nest: the Device Access project and OAuth client, the code Google showed, and what they led to.
    var nestProjectID = "" { didSet { if nestProjectID != oldValue { resetNest() } } }
    var nestClientID = "" { didSet { if nestClientID != oldValue { resetNest() } } }
    var nestClientSecret = "" { didSet { if nestClientSecret != oldValue { resetNest() } } }
    var nestCodeText = ""
    private(set) var nestCameras: [NestDeviceAccess.Camera] = []
    var nestDeviceID: String? { didSet { if nestDeviceID != oldValue { invalidateProbe() } } }
    @ObservationIgnored private var nestRefreshToken: String?
    /// UniFi Protect: the console's cameras (listed with the API key, which is the Password field) and the chosen one.
    private(set) var unifiCameras: [UnifiProtectCamera] = []
    var unifiCameraID: String? { didSet { if unifiCameraID != oldValue { invalidateProbe() } } }
    /// The state of the page's own action (Find Cameras, Connect to Google, Open Sign-In Page).
    private(set) var integrationState: IntegrationState = .idle
    /// Where go2rtc's sign-in page runs while it is open.
    private(set) var signInPageURL: URL?
    /// Wyze's official RTSP: which path of `CameraType.wyzePaths` worked.
    @ObservationIgnored private var wyzePathIndex = 0

    // MARK: Probe
    private(set) var probeState: ProbeState = .idle
    @ObservationIgnored private var probeGeneration = 0

    // MARK: Choices
    var name = ""
    /// The name the wizard last suggested; while `name` still equals it, the next probe may replace it.
    @ObservationIgnored private var suggestedName: String?
    var kind: CameraKind = .camera
    var motionSource: MotionSource = .cameraEvents
    var motionSensitivity = 0.5
    var motionHoldSeconds = 20
    var sensors = SensorOptions()
    var audioEnabled = true
    var twoWayAudio = false

    // MARK: Add
    private(set) var addState: AddState = .idle
    private(set) var pairingCode: PairingCode?

    // MARK: Lifetime
    /// Set by `cancel()`: no new discovery or probe starts.
    private(set) var isClosed = false
    @ObservationIgnored private var cancellableTasks: [Task<Void, Never>] = []

    /// `initialStep`: tests start on a later page.
    init(service: any CameraSetupService, initialStep: WizardStep = .cameraType) {
        self.service = service
        step = initialStep
    }

    // MARK: Navigation

    /// A camera that is not searched for skips the Find Your Camera page, and the count and numbers leave it out.
    private var skipsDiscovery: Bool { !cameraType.usesDiscovery }
    var stepNumber: Int {
        let number = min(step.rawValue, WizardStep.summary.rawValue) + 1
        return skipsDiscovery && step > .discover ? number - 1 : number
    }
    var stepCount: Int { Self.stepCount - (skipsDiscovery ? 1 : 0) }

    var canGoBack: Bool {
        step != .cameraType && step != .pairing && addState != .adding && probeState != .probing
    }

    var canContinue: Bool {
        switch step {
        case .cameraType: true
        case .discover: vendorChoice == .demo || vendorChoice == .rtspURL || HostInput(host) != nil
        case .connect: connectionProblem == nil
        case .probe: probeResult != nil
        case .kind: !trimmedName.isEmpty
        case .motion, .features: true
        case .summary: addState != .adding && makeConfiguration() != nil
        case .pairing: true
        }
    }

    var continueTitle: String {
        switch step {
        case .summary: String(localized: "Add Camera")
        case .pairing: String(localized: "Done")
        default: String(localized: "Continue")
        }
    }

    /// Moves to the next page, probing on the way into `.probe` and adding the camera from `.summary`.
    func goForward() async {
        guard canContinue else { return }
        switch step {
        case .cameraType:
            if vendorChoice == .demo {
                step = .probe
                if probeResult == nil { await probe() }
            } else {
                step = cameraType.usesDiscovery ? .discover : .connect
            }
        case .discover:
            if vendorChoice == .demo {
                step = .probe
                if probeResult == nil { await probe() }
            } else {
                if vendorChoice.usesAddress { normalizeHost() }
                step = .connect
            }
        case .connect:
            moveCredentialsOutOfStreamURLs()
            if vendorChoice.usesAddress { normalizeHost() }
            step = .probe
            if probeResult == nil { await probe() }
        case .probe: step = .kind
        case .kind: step = .motion
        case .motion: step = .features
        case .features: step = .summary
        case .summary: await add()
        case .pairing: break
        }
    }

    func goBack() {
        guard canGoBack else { return }
        switch step {
        case .cameraType, .pairing: break
        case .discover: step = .cameraType
        case .connect: step = cameraType.usesDiscovery ? .discover : .cameraType
        case .probe: step = vendorChoice == .demo ? .cameraType : .connect
        case .kind: step = .probe
        case .motion: step = .kind
        case .features: step = .motion
        case .summary:
            if case .failed = addState { addState = .idle }
            step = .features
        }
    }

    // MARK: Tasks

    /// Continue, as a task `cancel()` can stop (except the add from the Review page, which always finishes).
    @discardableResult
    func startForward() -> Task<Void, Never> {
        let task = Task { await goForward() }
        if step != .summary { cancellableTasks.append(task) }
        return task
    }

    /// Try Again on a failed probe.
    @discardableResult
    func startProbe() -> Task<Void, Never> {
        track(Task { await probe() })
    }

    /// Search Again.
    @discardableResult
    func startDiscovery() -> Task<Void, Never> {
        track(Task { await discover() })
    }

    /// The sheet is going away: stop discovery and probing, and ignore their late results.
    func cancel() {
        isClosed = true
        if signInPageURL != nil {
            signInPageURL = nil
            let service = service
            Task { await service.endIntegrationSignIn() }
        }
        for task in cancellableTasks { task.cancel() }
        cancellableTasks = []
        search?.cancel()
        isDiscovering = false
        probeGeneration += 1
        if probeState == .probing { probeState = .idle }
    }

    private func track(_ task: Task<Void, Never>) -> Task<Void, Never> {
        cancellableTasks.append(task)
        return task
    }

    // MARK: Discover

    /// Searches the network, or waits for the search already under way (the Discover page's `.task`, Search Again).
    /// The search belongs to the model: the page going away (cancelling its `.task`) doesn't cut it short, so the
    /// complete list lands; `cancel()` stops it, and then nothing is recorded.
    func discover() async {
        if let search {
            await search.value
            return
        }
        guard !isClosed else { return }
        isDiscovering = true
        let running = Task {
            let found = await service.discoverCameras()
            guard !Task.isCancelled, !isClosed else { return }
            discovered = Self.uniqueByHost(found)
            hasDiscovered = true
        }
        search = running
        await running.value
        search = nil
        isDiscovering = false
    }

    /// Local Network access is denied: the search (and every camera) is blocked, so the Discover page says that instead
    /// of "No cameras answered".
    var isLocalNetworkDenied: Bool { localNetworkAccess == .denied }

    /// The engine's answer (observed through it: the Discover page follows changes).
    var localNetworkAccess: LocalNetworkAccess { service.localNetworkAccess }

    /// The engine's Local Network answer changed (the Discover page follows it): once access is allowed, a finished
    /// search that found nothing (blocked, or run while the system's alert was up) runs again. Returns that search.
    @discardableResult
    func localNetworkAccessDidChange(_ access: LocalNetworkAccess) -> Task<Void, Never>? {
        guard access == .granted, !isClosed, hasDiscovered, discovered.isEmpty, search == nil else { return nil }
        return startDiscovery()
    }

    /// One row per host (WS-Discovery can answer once per service or channel): names and hardware fill in from later
    /// answers, device service addresses are combined.
    static func uniqueByHost(_ cameras: [DiscoveredCamera]) -> [DiscoveredCamera] {
        var unique: [DiscoveredCamera] = []
        var indexByHost: [String: Int] = [:]
        for camera in cameras {
            guard let index = indexByHost[camera.host] else {
                indexByHost[camera.host] = unique.count
                unique.append(camera)
                continue
            }
            if unique[index].name == nil { unique[index].name = camera.name }
            if unique[index].hardware == nil { unique[index].hardware = camera.hardware }
            unique[index].xAddrs += camera.xAddrs.filter { !unique[index].xAddrs.contains($0) }
        }
        return unique
    }

    /// Fills the address from a discovered camera, and the ONVIF port from its device service address when that isn't
    /// the HTTP port (`http://host:8000/onvif/device_service`: many NVRs and doorbells use 8000, Tapo 2020).
    func select(_ camera: DiscoveredCamera) {
        host = camera.host
        selectedDiscoveredHost = camera.host
        discoveredName = camera.name
        if let port = Self.onvifPort(announcedIn: camera.xAddrs), port != httpPort {
            onvifPort = port
            discoveredONVIFPort = port
        } else if let port = discoveredONVIFPort, onvifPort == port {
            onvifPort = nil
            discoveredONVIFPort = nil
        }
    }

    /// The explicit port of the first plain-HTTP device service address (HTTPS addresses are left to the person).
    static func onvifPort(announcedIn xAddrs: [URL]) -> Int? {
        guard let address = xAddrs.first(where: { $0.scheme?.lowercased() == "http" }) else { return nil }
        return address.port
    }

    // MARK: Connect

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the typed address can't be used, or nil (also nil while nothing is typed).
    var hostProblem: String? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, HostInput(host) == nil else { return nil }
        return String(localized: "Enter an IP address or host name, like 192.168.1.20 or camera.local.")
    }

    /// Splits a pasted URL or `host:port` into the address, port, HTTPS switch and (empty) credential fields. An
    /// `rtsps://` address gives the camera's address only: its port is the TLS one, not the plain RTSP port.
    func normalizeHost() {
        guard let input = HostInput(host) else { return }
        host = input.host
        // The scheme first: switching HTTPS moves a default port (80 ↔ 443), and a port the address names wins over it.
        if input.scheme == "https" {
            useHTTPS = true
        } else if input.scheme == "http" {
            useHTTPS = false
        }
        if let port = input.port {
            switch input.scheme {
            case "rtsp": rtspPort = port
            case "rtsps": break
            default: httpPort = port
            }
        }
        if trimmedUsername.isEmpty, let user = input.user { username = user }
        if password.isEmpty, let secret = input.password { password = secret }
    }

    /// The HTTP port field's label: which protocol the port is for.
    var httpPortTitle: String { Self.httpPortTitle(useHTTPS: useHTTPS) }

    static func httpPortTitle(useHTTPS: Bool) -> String {
        useHTTPS ? String(localized: "HTTPS Port") : String(localized: "HTTP Port")
    }

    /// The port after Use HTTPS was switched to `useHTTPS`: the other protocol's default (80 ↔ 443) follows it; a port
    /// the person chose stays.
    static func httpPort(_ port: Int, afterSwitchingHTTPS useHTTPS: Bool) -> Int {
        switch (useHTTPS, port) {
        case (true, 80): 443
        case (false, 443): 80
        default: port
        }
    }

    /// Why the Connect page can't continue, or nil.
    var connectionProblem: String? {
        switch vendorChoice {
        case .demo:
            return nil
        case .rtspURL where cameraType == .wyzeRTSP:
            if HostInput(host) == nil { return String(localized: "Enter the camera’s IP address, like 192.168.1.20.") }
            if trimmedUsername.isEmpty { return String(localized: "Enter the RTSP user name you created in the Wyze app.") }
            if password.isEmpty { return String(localized: "Enter the RTSP password you created in the Wyze app.") }
            return nil
        case .rtspURL:
            guard Self.streamURL(mainStreamURLText) != nil else {
                return Self.isRTSPOverTLS(mainStreamURLText) ? Self.rtspOverTLSUnsupported
                    : String(localized: "Enter the main stream URL, starting with rtsp://.")
            }
            let sub = subStreamURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sub.isEmpty, Self.streamURL(sub) == nil {
                return Self.isRTSPOverTLS(sub) ? Self.rtspOverTLSUnsupported : String(localized: "The sub stream URL must start with rtsp://.")
            }
            return nil
        case .automatic, .hikvision, .reolink, .onvif, .amcrest, .doorbird:
            if HostInput(host) == nil { return String(localized: "Enter the camera’s address.") }
            if trimmedUsername.isEmpty { return String(localized: "Enter the camera’s user name.") }
            if !(1...65_535).contains(httpPort) || !(1...65_535).contains(rtspPort) || onvifPort.map({ !(1...65_535).contains($0) }) == true {
                return String(localized: "Ports must be between 1 and 65535.")
            }
            return nil
        case .unifi:
            if HostInput(host) == nil { return String(localized: "Enter the console’s address, like 192.168.1.1.") }
            if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "Paste the API key from UniFi Protect.") }
            if !(1...65_535).contains(httpPort) { return String(localized: "Ports must be between 1 and 65535.") }
            if unifiCameras.isEmpty { return String(localized: "Choose Find Cameras to list the console’s cameras.") }
            if unifiCameraID == nil { return String(localized: "Choose a camera.") }
            return helperProblem
        case .go2rtc:
            return cloudProblem
        }
    }

    /// Whether the go2rtc streaming helper is part of this copy of the app.
    var isStreamingHelperInstalled: Bool { service.isStreamingHelperInstalled }

    /// The streaming helper is part of the app; a copy without it can't reach cloud cameras or consoles' RTSPS.
    var helperProblem: String? {
        service.isStreamingHelperInstalled ? nil
            : String(localized: "This copy of Camera Bridge doesn’t include the streaming helper (go2rtc), which this camera type needs.")
    }

    /// Why the Connect page for a cloud camera can't continue, or nil.
    var cloudProblem: String? {
        if let helperProblem { return helperProblem }
        if cameraType == .googleNest {
            if nestProjectID.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter the Device Access project ID.") }
            if nestClientID.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter the OAuth client ID.") }
            if nestClientSecret.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter the OAuth client secret.") }
            if nestRefreshToken == nil { return String(localized: "Open Google’s sign-in link, then paste the code and choose Connect.") }
            if nestDeviceID == nil { return String(localized: "Choose a camera.") }
            return nil
        }
        do {
            _ = try Go2RTCSource(parsing: sourceText)
            return nil
        } catch let invalid as Go2RTCSource.Invalid {
            return invalid.reason
        } catch {
            return String(localized: "The source address can’t be used.")
        }
    }

    /// The go2rtc source a cloud camera is made from (Nest: built from the chosen camera), or nil while it is incomplete.
    var cloudSource: Go2RTCSource? {
        if cameraType == .googleNest {
            guard let token = nestRefreshToken, let id = nestDeviceID else { return nil }
            let protocolName = nestCameras.first { $0.deviceID == id }?.protocolName ?? "WEB_RTC"
            return try? Go2RTCSource.nest(clientID: nestClientID.trimmingCharacters(in: .whitespaces),
                                          clientSecret: nestClientSecret.trimmingCharacters(in: .whitespaces), refreshToken: token,
                                          projectID: nestProjectID.trimmingCharacters(in: .whitespaces), deviceID: id, protocols: protocolName)
        }
        return try? Go2RTCSource(parsing: sourceText)
    }

    /// What is saved about the service (nothing secret).
    var integrationSettings: IntegrationSettings? {
        switch vendorChoice {
        case .go2rtc:
            guard let source = cloudSource else { return nil }
            var details: [String: String] = [:]
            if cameraType == .googleNest, let id = nestDeviceID, let camera = nestCameras.first(where: { $0.deviceID == id }) {
                details[IntegrationSettings.Key.deviceName] = camera.name
            }
            let service = cameraType.service ?? source.service
            return IntegrationSettings(service: service == .other ? source.service : service, details: details)
        case .unifi:
            guard let id = unifiCameraID else { return nil }
            var details = [IntegrationSettings.Key.protectCameraID: id]
            if let name = unifiCameras.first(where: { $0.id == id })?.name { details[IntegrationSettings.Key.deviceName] = name }
            return IntegrationSettings(service: .unifiProtect, details: details)
        default:
            return nil
        }
    }

    /// What goes to the Keychain as the camera's password: the cloud source, the console's API key, or the camera's password.
    var storedSecret: String? {
        switch vendorChoice {
        case .demo: nil
        case .go2rtc: cloudSource?.url
        case .unifi: password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : password.trimmingCharacters(in: .whitespacesAndNewlines)
        default: password.isEmpty ? nil : password
        }
    }

    /// Where the engine reaches the camera.
    var endpoint: CameraEndpoint? {
        switch vendorChoice {
        case .demo:
            return CameraEndpoint(host: "localhost")
        case .rtspURL:
            guard let url = Self.streamURL(effectiveMainStreamText), let host = url.host(percentEncoded: false) else { return nil }
            return CameraEndpoint(host: host, rtspPort: url.port ?? Self.defaultRTSPPort(scheme: url.scheme))
        case .go2rtc:
            return CameraEndpoint(host: "127.0.0.1")   // the helper runs on this Mac
        case .automatic, .hikvision, .reolink, .onvif, .amcrest, .doorbird, .unifi:
            guard let input = HostInput(host) else { return nil }
            return CameraEndpoint(host: input.host, httpPort: httpPort, rtspPort: rtspPort, onvifPort: onvifPort, useHTTPS: useHTTPS)
        }
    }

    /// Stream URLs never carry credentials: user info pasted into a URL moves to the (empty) credential fields.
    func moveCredentialsOutOfStreamURLs() {
        for keyPath in [\AddCameraWizardModel.mainStreamURLText, \AddCameraWizardModel.subStreamURLText] {
            let text = self[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            guard var components = URLComponents(string: text), components.user != nil || components.password != nil else { continue }
            if trimmedUsername.isEmpty, let user = components.user, !user.isEmpty { username = user }
            if password.isEmpty, let secret = components.password { password = secret }
            components.user = nil
            components.password = nil
            if let clean = components.string { self[keyPath: keyPath] = clean }
        }
    }

    /// 554 for RTSP, 322 for RTSP over TLS (RFC 2326 / RFC 7826).
    static func defaultRTSPPort(scheme: String?) -> Int {
        scheme?.lowercased() == "rtsps" ? 322 : 554
    }

    /// The engine's RTSP client speaks plain RTSP only (`RTSPClient` refuses other schemes), so an `rtsps://` camera
    /// could never be added or never stream: such URLs are refused with this.
    static let rtspOverTLSUnsupported = String(localized: "Camera Bridge can’t use RTSP over TLS (rtsps://) yet. Enter the camera’s plain rtsp:// URL; many cameras offer both.")

    /// Whether `text` is an `rtsps://` URL.
    static func isRTSPOverTLS(_ text: String) -> Bool {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() == "rtsps"
    }

    /// An `rtsp://` URL with a host, or nil (also for `rtsps://`: see `rtspOverTLSUnsupported`).
    static func streamURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "rtsp",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return url
    }

    /// The main stream text: what was typed, or for Wyze's official RTSP the address built from the camera's IP address
    /// (`rtsp://<ip>:554/stream0`; `/live` is tried when that path does not exist).
    var effectiveMainStreamText: String {
        guard cameraType == .wyzeRTSP, let input = HostInput(host) else { return mainStreamURLText }
        return "rtsp://\(input.host.contains(":") ? "[\(input.host)]" : input.host):554\(CameraType.wyzePaths[min(wyzePathIndex, CameraType.wyzePaths.count - 1)])"
    }

    private var enteredStreamURLs: (main: URL?, sub: URL?) {
        guard vendorChoice == .rtspURL else { return (nil, nil) }
        return (Self.streamURL(effectiveMainStreamText)?.removingUserInfo, Self.streamURL(subStreamURLText)?.removingUserInfo)
    }

    // MARK: Probe

    var probeResult: CameraProbeResult? {
        if case .succeeded(let result) = probeState { result } else { nil }
    }

    func probe() async {
        guard !isClosed else { return }
        guard let endpoint else {
            probeState = .failed(String(localized: "Enter the camera’s address first."))
            return
        }
        probeGeneration += 1
        let generation = probeGeneration
        probeState = .probing
        do {
            let result = try await runProbe(endpoint: endpoint)
            guard generation == probeGeneration else { return }
            probeState = .succeeded(result)
            applyDefaults(from: result)
        } catch {
            guard generation == probeGeneration else { return }
            if !Task.isCancelled { log.notice("Checking \(endpoint.host) failed: \(ErrorText.logDescription(error))") }
            probeState = Task.isCancelled ? .idle : .failed(ErrorText.describe(error))
        }
    }

    /// The service's check for the chosen type: the helper path for cloud cameras and consoles, Wyze's candidate paths, the plain probe.
    private func runProbe(endpoint: CameraEndpoint) async throws -> CameraProbeResult {
        if vendorChoice == .go2rtc || vendorChoice == .unifi {
            guard let vendor = vendorChoice.vendor, let integration = integrationSettings, let secret = storedSecret else {
                throw IntegrationError(connectionProblem ?? String(localized: "The camera’s details are incomplete."))
            }
            return try await service.probeIntegration(vendor: vendor, integration: integration, endpoint: endpoint,
                                                      username: "", secret: secret)
        }
        if cameraType == .wyzeRTSP {
            var lastError: (any Error)?
            for index in CameraType.wyzePaths.indices {
                wyzePathIndex = index
                guard let url = Self.streamURL(effectiveMainStreamText)?.removingUserInfo else { break }
                do {
                    return try await service.probeCamera(vendor: .rtsp, endpoint: endpoint, username: trimmedUsername, password: password,
                                                         mainStreamURL: url, subStreamURL: nil)
                } catch {
                    lastError = error
                    if Task.isCancelled || Self.isCredentialFailure(error) { break }   // another path would only fail the login again
                }
            }
            wyzePathIndex = 0
            throw lastError ?? CameraAdapterError.unsupported("no stream address")
        }
        let streams = enteredStreamURLs
        return try await service.probeCamera(vendor: vendorChoice.vendor, endpoint: endpoint,
                                             username: vendorChoice == .demo ? "" : trimmedUsername,
                                             password: vendorChoice == .demo ? "" : password,
                                             mainStreamURL: streams.main, subStreamURL: streams.sub)
    }

    /// A rejected login: the next path would be another failed attempt.
    static func isCredentialFailure(_ error: any Error) -> Bool {
        if case RTSPError.unauthorized = error { return true }
        if case CameraAdapterError.unauthorized = error { return true }
        return false
    }

    private func invalidateProbe() {
        probeGeneration += 1
        if probeState != .idle { probeState = .idle }
    }

    private func applyDefaults(from result: CameraProbeResult) {
        if trimmedName.isEmpty || name == suggestedName {
            let suggestion = discoveredName ?? (result.model.isEmpty ? String(localized: "Camera") : result.model)
            name = suggestion
            suggestedName = suggestion
        }
        kind = result.capabilities.isDoorbell ? .doorbell : .camera
        motionSource = availableMotionSources.first ?? .softMotion
        sensors = SensorKind.filtered(sensors, by: result.capabilities, motionSource: motionSource)
        audioEnabled = result.mainStream.map { $0.audioCodec != nil } ?? true
        twoWayAudio = result.capabilities.twoWayAudio
    }

    // MARK: Choices

    var capabilities: CameraCapabilities? { probeResult?.capabilities }

    /// A doorbell whose camera reported no button of its own (every Hikvision doorbell, plain RTSP): its rings can only
    /// come from the webhook, so the Review and pairing pages show its doorbell URL.
    var ringsThroughWebhook: Bool { kind == .doorbell && probeResult != nil && capabilities?.isDoorbell != true }

    /// Camera events only when the camera reports motion; built-in detection and the webhook always.
    var availableMotionSources: [MotionSource] {
        let hasMotionEvents = capabilities?.events.contains(.motion) ?? false
        return MotionSource.allCases.filter { $0 != .cameraEvents || hasMotionEvents }
    }

    /// The camera's own detections, plus the webhook's when it is the motion source.
    var availableSensors: [SensorKind] { SensorKind.available(in: capabilities, motionSource: motionSource) }
    var canUseTwoWayAudio: Bool { capabilities?.twoWayAudio ?? false }
    var hasCameraAudio: Bool { probeResult?.mainStream.map { $0.audioCodec != nil } ?? true }

    /// The camera to add, or nil before a successful probe (or without a name).
    func makeConfiguration() -> CameraConfiguration? {
        guard let result = probeResult, var endpoint, !trimmedName.isEmpty else { return nil }
        if endpoint.onvifPort == nil, result.vendor == .onvif { endpoint.onvifPort = result.onvifPort }   // found by the probe
        let hasUserName = vendorChoice != .demo && vendorChoice != .go2rtc && vendorChoice != .unifi
        var config = CameraConfiguration(id: cameraID, name: trimmedName, kind: kind, vendor: result.vendor, endpoint: endpoint,
                                         username: hasUserName ? trimmedUsername : "")
        let entered = enteredStreamURLs
        // A cloud camera's address is the helper's, picked at run time: nothing about it is saved.
        let keepsStreamAddresses = vendorChoice != .go2rtc && vendorChoice != .unifi
        config.mainStreamURL = keepsStreamAddresses ? (result.mainStream?.url ?? entered.main)?.removingUserInfo : nil
        config.subStreamURL = keepsStreamAddresses ? (result.subStream?.url ?? entered.sub)?.removingUserInfo : nil
        config.integration = integrationSettings
        config.motionSource = availableMotionSources.contains(motionSource) ? motionSource : .softMotion
        config.motionSensitivity = min(max(motionSensitivity, 0), 1)
        config.motionHoldSeconds = motionHoldSeconds
        config.sensors = SensorKind.filtered(sensors, by: result.capabilities, motionSource: config.motionSource)
        config.audioEnabled = audioEnabled
        config.twoWayAudio = twoWayAudio && result.capabilities.twoWayAudio
        config.manufacturer = result.manufacturer
        config.model = result.model
        config.serialNumber = result.serialNumber
        config.firmware = result.firmware
        config.capabilities = result.capabilities
        return config
    }

    // MARK: Integration actions

    /// Starts go2rtc's sign-in page on this Mac and returns its address for the view to open in the browser. The person signs in there
    /// (Camera Bridge never sees the credentials) and pastes the source address it shows.
    @discardableResult
    func openSignInPage() async -> URL? {
        guard !isClosed, integrationState != .working else { return nil }
        integrationState = .working
        do {
            let url = try await service.beginIntegrationSignIn()
            signInPageURL = url
            integrationState = .idle
            return url
        } catch {
            log.notice("Opening the sign-in page failed: \(ErrorText.logDescription(error))")
            integrationState = .failed(ErrorText.describe(error))
            return nil
        }
    }

    func closeSignInPage() {
        guard signInPageURL != nil else { return }
        signInPageURL = nil
        let service = service
        Task { await service.endIntegrationSignIn() }
    }

    /// UniFi Protect: lists the console's cameras with the API key (the Password field).
    func findUnifiCameras() async {
        guard !isClosed, integrationState != .working, let endpoint else { return }
        let key = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            integrationState = .failed(String(localized: "Paste the API key from UniFi Protect."))
            return
        }
        integrationState = .working
        do {
            let cameras = try await service.unifiProtectCameras(endpoint: endpoint, apiKey: key)
            guard !isClosed else { return }
            unifiCameras = cameras
            if let id = unifiCameraID, !cameras.contains(where: { $0.id == id }) { unifiCameraID = nil }
            if unifiCameraID == nil, cameras.count == 1 { unifiCameraID = cameras[0].id }
            integrationState = cameras.isEmpty ? .failed(String(localized: "The console has no cameras.")) : .idle
        } catch {
            guard !isClosed else { return }
            log.notice("Listing the Protect cameras failed: \(ErrorText.logDescription(error))")
            unifiCameras = []
            integrationState = .failed(ErrorText.describe(error))
        }
    }

    /// Google's sign-in link for the entered project and OAuth client, or why there is none yet.
    var nestAuthorizationURL: URL? {
        try? NestDeviceAccess.authorizationURL(projectID: nestProjectID, clientID: nestClientID)
    }

    /// Google Nest: turns the pasted code into a refresh token and lists the cameras.
    func connectNest() async {
        guard !isClosed, integrationState != .working else { return }
        guard let code = NestDeviceAccess.code(from: nestCodeText) else {
            integrationState = .failed(String(localized: "Paste the code from the page Google showed (or that page’s address)."))
            return
        }
        integrationState = .working
        let access = service.nestAccess
        do {
            let tokens = try await access.exchange(code: code, clientID: nestClientID, clientSecret: nestClientSecret)
            let cameras = try await access.cameras(projectID: nestProjectID, accessToken: tokens.accessToken)
            guard !isClosed else { return }
            nestRefreshToken = tokens.refreshToken
            nestCameras = cameras
            nestCodeText = ""
            if nestDeviceID == nil || !cameras.contains(where: { $0.deviceID == nestDeviceID }) { nestDeviceID = cameras.count == 1 ? cameras[0].deviceID : nil }
            integrationState = cameras.isEmpty ? .failed(String(localized: "Google lists no cameras or doorbells for this project. Check that your home’s devices are linked to it.")) : .idle
        } catch {
            guard !isClosed else { return }
            log.notice("Connecting to Google failed: \(ErrorText.logDescription(error))")
            integrationState = .failed(ErrorText.describe(error))
        }
    }

    /// Changing the Nest project or client invalidates what was fetched with the old one.
    private func resetNest() {
        nestRefreshToken = nil
        nestCameras = []
        nestDeviceID = nil
        invalidateProbe()
    }

    // MARK: Already added

    /// The configured camera at `host` (a discovered camera's row says "Already added"), or nil. The demo camera has no
    /// address of its own.
    func existingCamera(at host: String) -> CameraConfiguration? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return service.configuredCameras.first { $0.vendor != .demo && $0.endpoint.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// The configured camera that already shows the camera about to be added, or nil (the Review page warns, and offers
    /// to open it: adding it again makes a second Home accessory with its own stream and event sessions to the camera).
    /// The same: a camera reporting the serial number of a configured one (also after an address change), or one reached
    /// through its API at the same address and ports, or plain RTSP with the same main stream (other streams on one
    /// address are often an NVR's other channels). Never the demo camera.
    var alreadyAdded: CameraConfiguration? {
        guard let candidate = makeConfiguration(), candidate.vendor != .demo else { return nil }
        return service.configuredCameras.first { existing in
            guard existing.vendor != .demo, existing.id != candidate.id else { return false }
            let serial = candidate.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if !serial.isEmpty, existing.serialNumber == serial { return true }
            if candidate.vendor == .rtsp || existing.vendor == .rtsp {
                return candidate.mainStreamURL != nil && candidate.mainStreamURL?.removingUserInfo == existing.mainStreamURL?.removingUserInfo
            }
            // Cameras behind a helper or a console share one address: only their own identity tells them apart.
            if [CameraVendor.go2rtc, .unifi].contains(candidate.vendor) || [CameraVendor.go2rtc, .unifi].contains(existing.vendor) { return false }
            return existing.endpoint.host.caseInsensitiveCompare(candidate.endpoint.host) == .orderedSame
                && existing.endpoint.httpPort == candidate.endpoint.httpPort && existing.endpoint.rtspPort == candidate.endpoint.rtspPort
        }
    }

    // MARK: Add

    func add() async {
        guard let configuration = makeConfiguration(), addState != .adding else { return }
        addState = .adding
        do {
            try await service.addCamera(configuration, password: storedSecret)
            addState = .added
            pairingCode = service.pairingCode(for: cameraID)
            step = .pairing
        } catch {
            log.warning("Adding \(configuration.name) failed: \(ErrorText.logDescription(error))")
            addState = .failed(ErrorText.describe(error))
        }
    }

    /// The engine publishes the new accessory's code shortly after `addCamera`; the pairing page polls this.
    func refreshPairingCode() {
        if pairingCode == nil { pairingCode = service.pairingCode(for: cameraID) }
    }
}
