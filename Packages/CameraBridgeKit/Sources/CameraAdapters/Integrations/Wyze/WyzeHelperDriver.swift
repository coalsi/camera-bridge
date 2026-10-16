import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MediaCore
import RTSP
import Synchronization

/// The helper programs that bring in Wyze cameras go2rtc cannot read: `wyze-lake` (the Pan v4's cloud video, Agora) and `wyze-gwell` (Gwell
/// models). Each runs for one camera, takes its configuration from its environment (secrets included, never its command line), pushes the
/// camera's video as RTSP into a go2rtc stream with no source (`Go2RTCSource.published`), and reports on stderr as
/// `cb-<name> event=start|first_video|session_end|stall|stopped|…`. Exit codes: 0 stopped, 1 session error, 2 bad configuration, 3 the
/// credentials were refused, 4 stall, 5 output failed, 6 the camera is not listed or offline.
///
/// The credentials come fresh for every start from the Wyze plugin (`WyzeHelpers.setProvider`): the account's session lives there.
public enum WyzeHelpers {
    /// Which helper a camera needs.
    public enum Kind: String, Sendable {
        case cloud, gwell

        /// The program's name in the helpers folder.
        var program: String { self == .cloud ? "wyze-lake" : "wyze-gwell" }
        /// The prefix of its environment variables.
        var prefix: String { self == .cloud ? "CB_LAKE_" : "CB_GWELL_" }
    }

    /// What the provider is asked for: the camera, and which helper.
    public struct Request: Sendable, Equatable {
        public var kind: Kind
        public var mac: String
        public var model: String

        public init(kind: Kind, mac: String, model: String) {
            self.kind = kind
            self.mac = mac
            self.model = model
        }
    }

    /// Gives the helper's environment for `request` (its `CB_LAKE_…` / `CB_GWELL_…` variables, the output excepted), fetching fresh
    /// credentials. Throws a sentence for the person when it can't (signed out, camera gone).
    public typealias Provider = @Sendable (Request) async throws -> [String: String]

    private static let provider = Mutex<Provider?>(nil)
    private static let launcher = Mutex<(any HelperLaunching)?>(nil)

    /// The engine hands over its helper launcher at every start (which helpers this copy includes).
    public static func configure(launcher next: (any HelperLaunching)?) {
        launcher.withLock { $0 = next }
    }

    /// Whether this copy of Camera Bridge includes the helper for `kind`.
    public static func isInstalled(_ kind: Kind) -> Bool {
        launcher.withLock { $0 }?.locate(kind.program) != nil
    }

    /// Set by the Wyze plugin when it starts.
    public static func setProvider(_ next: Provider?) {
        provider.withLock { $0 = next }
    }

    static func environment(for request: Request) async throws -> [String: String] {
        guard let current = provider.withLock({ $0 }) else {
            throw IntegrationError("The Wyze plugin isn’t signed in. Open Plugins, Wyze, and sign in.")
        }
        return try await current(request)
    }

    /// The kind a camera's saved details ask for (`IntegrationSettings.Key.wyzeWay` `cloud` or `gwell`); nil for others.
    public static func kind(of settings: IntegrationSettings?) -> Kind? {
        guard settings?.service == .wyze, let way = settings?.details[IntegrationSettings.Key.wyzeWay] else { return nil }
        return Kind(rawValue: way)
    }
}

/// A Wyze camera brought in by a helper program (`WyzeHelpers`): the helper pushes into go2rtc, the ordinary RTSP ingest reads go2rtc.
final class WyzeHelperDriver: StreamHoldingDriver, Sendable {
    let vendor: CameraVendor = .go2rtc

    /// The first picture can take a while: the cloud handshake, the camera waking up.
    static let firstVideoTimeout: Duration = .seconds(90)

    private let cameraID: UUID?
    private let streamID: String
    private let settings: IntegrationSettings?
    private let kind: WyzeHelpers.Kind
    private let provider: (any Go2RTCStreamProviding)?
    private let launcher: (any HelperLaunching)?
    private let rtspFactory: RTSPSessionFactory
    private let supervisor: WyzeHelperSupervisor

    init(cameraID: UUID?, settings: IntegrationSettings?, kind: WyzeHelpers.Kind, provider: (any Go2RTCStreamProviding)?, launcher: (any HelperLaunching)?,
         rtspFactory: @escaping RTSPSessionFactory) {
        self.cameraID = cameraID
        self.streamID = Go2RTCManager.streamName(for: cameraID ?? UUID())
        self.settings = settings
        self.kind = kind
        self.provider = provider
        self.launcher = launcher
        self.rtspFactory = rtspFactory
        let request = WyzeHelpers.Request(kind: kind, mac: settings?.details[IntegrationSettings.Key.wyzeMAC] ?? "",
                                          model: settings?.details[IntegrationSettings.Key.wyzeModel] ?? "")
        supervisor = WyzeHelperSupervisor(request: request, launcher: launcher, log: Log(category: "wyze-helper", cameraID: cameraID))
    }

    private func attach() async throws -> URL {
        guard let provider else { throw IntegrationError("The streaming helper isn’t available in this copy of Camera Bridge.") }
        guard launcher?.locate(kind.program) != nil else {
            throw IntegrationError("This copy of Camera Bridge OS doesn’t include the \(kind == .cloud ? "Wyze cloud" : "Wyze Gwell") helper.")
        }
        let url = try await provider.attach(streamID: streamID, source: .published)
        await supervisor.start(output: url)
        try await supervisor.waitForVideo(timeout: Self.firstVideoTimeout)
        return url
    }

    func probe() async throws -> CameraProbeResult {
        let url = try await attach()
        // The helper reports its first picture as it receives it; its push into go2rtc starts a moment later, so go2rtc may not
        // know the stream yet.
        var info: RTSPSessionInfo?
        let deadline = ContinuousClock.now + .seconds(20)
        while info == nil {
            do {
                info = try await RTSPProbing.describe(url: url, credentials: nil, cameraID: cameraID, timeout: .seconds(30), factory: rtspFactory)
            } catch RTSPError.notFound where ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        guard let info else { throw IntegrationError("The camera’s video didn’t reach the streaming helper.") }
        let name = settings?.details[IntegrationSettings.Key.wyzeModel].map(WyzeModels.name(for:)) ?? "Wyze camera"
        return CameraProbeResult(vendor: .go2rtc, manufacturer: "Wyze", model: name,
                                 serialNumber: "wyze-" + (settings?.details[IntegrationSettings.Key.wyzeMAC] ?? ""), firmware: "",
                                 mainStream: RTSPProbing.streamInfo(url: url, info: info), subStream: nil, capabilities: CameraCapabilities())
    }

    func makeEventSource() -> (any CameraEventSource)? { nil }
    func snapshot() async throws -> Data? { nil }
    func makeTalkbackSink() -> (any TalkbackSink)? { nil }

    /// The Pan v4 turns through its cloud session: the helper passes nudges to the camera (`WyzeLakePanTilt`).
    func makePanTilt() -> (any PanTiltControl)? {
        guard kind == .cloud, WyzeModels.pansAndTilts(settings?.details[IntegrationSettings.Key.wyzeModel] ?? "") else { return nil }
        return WyzeLakePanTilt(supervisor: supervisor)
    }

    func attachStreams() async throws -> URL {
        try await attach()
    }

    func releaseStreams() async {
        await supervisor.stop()
        await provider?.detach(streamID: streamID)
    }

    func close() async {
        await releaseStreams()
    }
}

/// Pan and tilt of a Wyze camera behind `wyze-lake`: the helper's loopback control server (`CB_LAKE_CONTROL`, `POST /move` with its token) passes
/// `camera-position::move-position` to the camera on the cloud session's data stream. The camera moves in steps, not continuously: every
/// `move` (the bridge repeats it while a button is held) is one nudge in the stronger direction, larger the faster asked; `stop` has nothing
/// to stop.
struct WyzeLakePanTilt: PanTiltControl {
    let supervisor: WyzeHelperSupervisor

    /// The camera's direction and step (1–60) for a move of `pan`, `tilt` (-1…1).
    static func nudge(pan: Double, tilt: Double) -> (direction: String, step: Int)? {
        guard pan != 0 || tilt != 0 else { return nil }
        let horizontal = abs(pan) >= abs(tilt)
        let amount = horizontal ? pan : tilt
        let direction = horizontal ? (amount > 0 ? "right" : "left") : (amount > 0 ? "up" : "down")
        return (direction, max(1, min(60, Int((abs(amount) * 20).rounded()))))
    }

    /// Kept for the bridge's life (a session per request can crash FoundationNetworking on Linux when requests overlap).
    private static let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(5), allowSelfSignedTLS: false, maximumBodySize: 64 << 10)

    func move(pan: Double, tilt: Double) async throws {
        guard let nudge = Self.nudge(pan: pan, tilt: tilt) else { return }
        guard let control = await supervisor.control() else { throw IntegrationError("The camera’s cloud session isn’t up yet. Try again in a moment.") }
        guard let url = URL(string: "http://127.0.0.1:\(control.port)/move") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(control.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"direction":"\#(nudge.direction)","step":\#(nudge.step),"speed":5}"#.utf8)
        let client = Self.client
        let status: Int
        do {
            status = try await client.data(for: request).1.statusCode
        } catch {
            throw IntegrationError("The Wyze helper didn’t take the move.")
        }
        switch status {
        case 200..<300: return
        case 409: throw IntegrationError("The camera’s cloud session isn’t up yet. Try again in a moment.")
        default: throw IntegrationError("The Wyze helper refused the move (HTTP \(status)).")
        }
    }

    func stop() async throws {}
}

/// Runs one camera's helper: starts it with fresh credentials, restarts it with backoff as its exit code says, and tells when video flows.
actor WyzeHelperSupervisor {
    private let request: WyzeHelpers.Request
    private let launcher: (any HelperLaunching)?
    private let log: Log
    private var task: Task<Void, Never>?
    private var output: URL?
    private var flowing = false
    private var lastProblem: String?
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    /// The helper's control server (pan and tilt): a loopback port of its own and a token made for this supervisor.
    private var controlPort: UInt16 = WyzeHelperSupervisor.nextControlPort()
    private let controlToken = (0..<4).map { _ in String(format: "%016llx", UInt64.random(in: .min ... .max)) }.joined()
    private var controlListening = false
    private static let controlPorts = Mutex<UInt16>(18480)

    /// A loopback port for the next helper's control server (18480–18519 in turn; a taken one makes the helper exit 5 and take the next).
    static func nextControlPort() -> UInt16 {
        controlPorts.withLock { port in
            defer { port = port >= 18519 ? 18480 : port + 1 }
            return port
        }
    }

    /// Where the running helper takes pan/tilt moves, nil while it doesn't.
    func control() -> (port: UInt16, token: String)? {
        controlListening && flowing ? (controlPort, controlToken) : nil
    }

    init(request: WyzeHelpers.Request, launcher: (any HelperLaunching)?, log: Log) {
        self.request = request
        self.launcher = launcher
        self.log = log
    }

    func start(output: URL) {
        if task != nil, self.output == output { return }
        task?.cancel()
        self.output = output
        flowing = false
        task = Task { await self.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        flowing = false
        fail(IntegrationError("The camera’s stream was stopped."))
    }

    /// Returns once the helper reported its first picture; throws the helper's last problem after `timeout`.
    func waitForVideo(timeout: Duration) async throws {
        if flowing { return }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timedOut()
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    private func timedOut() {
        guard !flowing else { return }
        fail(IntegrationError(lastProblem ?? "The camera sent no picture. Check that it is online in the Wyze app."))
    }

    private func fail(_ error: any Error) {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(throwing: error) }
    }

    private func videoStarted() {
        flowing = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    /// The loop: one helper run at a time; the pause before the next grows with failures and depends on how the run ended.
    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            let outcome = await runOnce()
            if Task.isCancelled { return }
            let pause: Duration
            switch outcome {
            case .stopped:
                pause = .seconds(5)
            case .badConfiguration(let words):
                lastProblem = words
                log.warning("the \(request.kind.program) helper refused its configuration; not restarted")
                fail(IntegrationError(words))
                return
            case .offline:
                pause = .seconds(120)
            case .credentialsRefused, .failed:
                failures += 1
                pause = .seconds(Double(min(60, 10 * failures)))
            }
            if flowing { failures = 0 }
            flowing = false
            try? await Task.sleep(for: pause)
        }
    }

    enum Outcome { case stopped, badConfiguration(String), credentialsRefused, offline, failed }

    private func runOnce() async -> Outcome {
        guard let launcher, let executable = launcher.locate(request.kind.program), let output else {
            return .badConfiguration("This copy of Camera Bridge OS doesn’t include the \(request.kind.program) helper.")
        }
        var environment: [String: String]
        do {
            environment = try await WyzeHelpers.environment(for: request)
        } catch {
            lastProblem = (error as? CustomStringConvertible)?.description ?? "The Wyze account didn’t answer."
            log.warning("the Wyze credentials for the helper could not be fetched: \(Redact.string(lastProblem ?? ""))")
            return .failed
        }
        environment[request.kind.prefix + "OUTPUT"] = output.absoluteString
        if request.kind == .cloud, WyzeModels.pansAndTilts(request.model) {
            environment["CB_LAKE_CONTROL"] = "127.0.0.1:\(controlPort)"
            environment["CB_LAKE_CONTROL_TOKEN"] = controlToken
        }
        if let ffmpeg = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            environment[request.kind.prefix + "FFMPEG"] = ffmpeg
        }
        let process: any HelperProcess
        do {
            process = try launcher.launch(HelperLaunchSpec(executable: executable, environment: environment))
        } catch {
            lastProblem = "The \(request.kind.program) helper could not be started."
            return .failed
        }
        log.info("\(request.kind.program) started")
        let reader = Task { [weak self] in
            for await line in process.output {
                await self?.handle(line)
            }
        }
        let exit = await withTaskCancellationHandler {
            await process.waitUntilExit()
        } onCancel: {
            process.terminate()
        }
        await reader.value
        controlListening = false
        log.info("\(request.kind.program) ended (\(exit))")
        guard exit.reason == .exited else { return Task.isCancelled ? .stopped : .failed }
        switch exit.status {
        case 0: return .stopped
        case 5 where lastProblem?.contains("control") == true || !controlListening:
            controlPort = Self.nextControlPort()   // the control port was taken (or the output failed: a new port costs nothing)
            return .failed
        case 2: return .badConfiguration(lastProblem ?? "The \(request.kind.program) helper was given a configuration it can’t use.")
        case 3:
            lastProblem = "Wyze refused the camera’s credentials. Camera Bridge asks for new ones and tries again."
            return .credentialsRefused
        case 6:
            lastProblem = "Wyze says this camera is offline or not on the account."
            return .offline
        default: return .failed
        }
    }

    /// A helper line: `cb-<name> event=… key=value`. Only these lines reach the log (the helper redacts secrets; the line is redacted again).
    private func handle(_ raw: String) {
        guard let line = WyzeHelperSupervisor.statusLine(raw, prefix: "cb-") else { return }
        let fields = WyzeHelperSupervisor.fields(of: line)
        switch fields["event"] {
        case "control_listening":
            controlListening = true
            log.debug("the helper takes pan and tilt")
        case "ptz_problem":
            log.info(Redact.string(String(line.prefix(300))))
        case "first_video":
            log.notice("the camera’s video is flowing through the \(request.kind.program) helper")
            videoStarted()
        case "stall":
            log.warning("the camera stopped sending video; the helper starts again")
        case "error", "session_end":
            if let message = fields["message"] ?? fields["reason"] { lastProblem = Redact.string(message) }
            log.info(Redact.string(String(line.prefix(300))))
        case "stats":
            log.debug(Redact.string(String(line.prefix(300))))
        default:
            // The steps of a session (provisioned, gateways, joined, …): what a failure needs to be understood.
            log.info(Redact.string(String(line.prefix(300))))
        }
    }

    /// The status line in `raw` from `prefix` on (a helper's logger may put a date and time in front), nil when it has none.
    static func statusLine(_ raw: String, prefix: String) -> String? {
        raw.range(of: prefix).map { String(raw[$0.lowerBound...]) }
    }

    /// `key=value` pairs of a status line (values may be quoted with double quotes).
    static func fields(of line: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(line)
        while let equals = rest.firstIndex(of: "=") {
            let keyStart = rest[..<equals].lastIndex(of: " ").map { rest.index(after: $0) } ?? rest.startIndex
            let key = String(rest[keyStart..<equals])
            var valueStart = rest.index(after: equals)
            var value: Substring
            if valueStart < rest.endIndex, rest[valueStart] == "\"" {
                valueStart = rest.index(after: valueStart)
                let end = rest[valueStart...].firstIndex(of: "\"") ?? rest.endIndex
                value = rest[valueStart..<end]
                rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
            } else {
                let end = rest[valueStart...].firstIndex(of: " ") ?? rest.endIndex
                value = rest[valueStart..<end]
                rest = rest[end...]
            }
            result[key] = String(value)
        }
        return result
    }
}
