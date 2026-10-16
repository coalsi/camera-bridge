import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `eufy-bridge` helper program: one process for the Eufy account (Eufy keeps about one session per sign-in), started while the Eufy
/// plugin is on. It holds the Eufy session in its own state folder, answers a small HTTP API on the loopback interface (every request
/// carries a random token made at each start), serves each camera's live video at `/stream/<token>/<serial>` only while something reads
/// it (go2rtc reads it while a viewer or recording wants the picture: the camera wakes for that and sleeps again), and reports on stderr:
/// `cb-eufy event=listening port=…`, `event=state state=…`, `event=camera serial=… kind=motion|person|ring|online|offline`, and its
/// other status lines (never a secret). Exit codes: 0 stopped, 2 bad configuration, 5 the port is taken (the next one is tried).
///
/// Configuration through the environment only: `CB_EUFY_LISTEN` (`127.0.0.1:<port>`), `CB_EUFY_TOKEN`, `CB_EUFY_STATE_DIR`, `CB_EUFY_FFMPEG`.
public actor EufyBridge {
    public static let shared = EufyBridge()
    public static let program = "eufy-bridge"
    /// The loopback ports tried in turn (the firewall never opens them: they are on 127.0.0.1 only).
    static let ports: ClosedRange<UInt16> = 18470...18479

    /// Where the helper listens, for the go2rtc source of each camera (`Go2RTCSource.eufyBridge`).
    public struct Endpoint: Sendable, Equatable {
        public let port: UInt16
        /// Secret.
        public let token: String
    }

    /// A camera event the helper reported.
    public struct Event: Sendable, Equatable {
        public var serial: String
        /// `motion`, `person`, `ring`, `online`, `offline`.
        public var kind: String
    }

    private var launcher: (any HelperLaunching)?
    private var stateDirectory: URL?
    private let token: String
    private var port: UInt16 = EufyBridge.ports.lowerBound
    private var wanted = false
    private var task: Task<Void, Never>?
    private var listening = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var subscribers: [UUID: (serial: String, continuation: AsyncStream<Event>.Continuation)] = [:]
    /// Why the helper isn't running, worded for the person (nil: fine, or not wanted).
    public private(set) var problem: String?
    private let log = Log(category: "eufy")

    public init() {
        var generator = SystemRandomNumberGenerator()
        token = (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }

    /// The engine hands over its helper launcher and a folder for the helper's session (the data directory's `plugins/eufy`).
    public func configure(launcher: (any HelperLaunching)?, stateDirectory: URL) {
        self.launcher = launcher
        self.stateDirectory = stateDirectory
        if wanted, task == nil { launch() }
    }

    /// Whether this copy of Camera Bridge includes the helper.
    public func isInstalled() -> Bool { launcher?.locate(Self.program) != nil }

    public var endpoint: Endpoint { Endpoint(port: port, token: token) }

    /// Starts the helper (and keeps it running) or stops it. The Eufy plugin calls this when it is switched on or off.
    public func setWanted(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        if on {
            launch()
        } else {
            task?.cancel()
            task = nil
            setListening(false)
        }
    }

    private func launch() {
        guard task == nil, launcher != nil, stateDirectory != nil else { return }
        task = Task { await self.run() }
    }

    /// An HTTP request to the helper (`path` like `/status`), waiting up to `wait` for it to listen. Throws a sentence for the person.
    public func call(_ method: String, _ path: String, body: Data? = nil, timeout: Duration = .seconds(60),
                     wait: Duration = .seconds(20)) async throws -> (status: Int, body: Data) {
        guard wanted else { throw IntegrationError("The Eufy plugin is off. Turn it on in Plugins.") }
        guard isInstalled() else { throw IntegrationError("This copy of Camera Bridge OS doesn’t include the Eufy helper.") }
        guard await waitUntilListening(wait) else {
            throw IntegrationError(problem ?? "The Eufy helper didn’t start. Camera Bridge keeps trying.")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw IntegrationError("Camera Bridge made a bad request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let client = client(timeout: timeout)
        do {
            let (data, response) = try await client.data(for: request)
            return (response.statusCode, data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IntegrationError("The Eufy helper didn’t answer.")
        }
    }

    /// The camera's latest picture as the helper has it (a cloud thumbnail or the last live picture), without waking the camera; nil when
    /// there is none.
    public func snapshot(serial: String) async throws -> Data? {
        let (status, body) = try await call("GET", "/snapshot/\(token)/\(Self.safe(serial))", timeout: .seconds(15), wait: .seconds(2))
        return status == 200 && !body.isEmpty ? body : nil
    }

    /// The events the helper reports for `serial`, until the stream's consumer stops reading.
    public func events(serial: String) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        subscribers[id] = (serial, continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// One client per timeout, kept for the bridge's life: a session made and invalidated for every request crashed the Linux daemon at start,
    /// when several requests overlapped (FoundationNetworking's `_MultiHandle` freed while still in use, 0.1.105).
    private var clients: [Duration: AuthenticatingHTTPClient] = [:]

    private func client(timeout: Duration) -> AuthenticatingHTTPClient {
        if let client = clients[timeout] { return client }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: timeout, allowSelfSignedTLS: false, maximumBodySize: 8 << 20)
        clients[timeout] = client
        return client
    }

    static func safe(_ serial: String) -> String { serial.filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    // MARK: - Listening

    private func waitUntilListening(_ limit: Duration) async -> Bool {
        if listening { return true }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.resume(id, false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    private func resume(_ id: UUID, _ value: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: value)
    }

    private func setListening(_ on: Bool) {
        listening = on
        guard on else { return }
        let pending = waiters
        waiters = [:]
        for waiter in pending.values { waiter.resume(returning: true) }
    }

    // MARK: - Process

    private func run() async {
        var failures = 0
        while !Task.isCancelled, wanted {
            let started = ContinuousClock.now
            let exit = await runOnce()
            setListening(false)
            if Task.isCancelled || !wanted { return }
            switch exit {
            case 2?:
                problem = "The Eufy helper refused its configuration."
                log.error("eufy-bridge refused its configuration; not restarted")
                return
            case 5?:
                port = port >= Self.ports.upperBound ? Self.ports.lowerBound : port + 1
                log.notice("eufy-bridge could not listen; trying port \(port)")
            default:
                break
            }
            failures = ContinuousClock.now - started > .seconds(120) ? 0 : failures + 1
            try? await Task.sleep(for: .seconds(Double(min(60, 2 * (1 << min(failures, 5))))))
        }
    }

    /// One run of the helper; its exit status (nil: it could not start, or was signalled).
    private func runOnce() async -> Int32? {
        guard let launcher, let stateDirectory, let executable = launcher.locate(Self.program) else {
            problem = "This copy of Camera Bridge OS doesn’t include the Eufy helper."
            return nil
        }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment = ["CB_EUFY_LISTEN": "127.0.0.1:\(port)", "CB_EUFY_TOKEN": token, "CB_EUFY_STATE_DIR": stateDirectory.path,
                           "HOME": stateDirectory.path]
        if let ffmpeg = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            environment["CB_EUFY_FFMPEG"] = ffmpeg
        }
        let pidFile = stateDirectory.appendingPathComponent("eufy-bridge.pid")
        launcher.endStaleProcess(pidFile: pidFile, executable: executable)
        let process: any HelperProcess
        do {
            process = try launcher.launch(HelperLaunchSpec(executable: executable, environment: environment, pidFile: pidFile))
        } catch {
            problem = "The Eufy helper could not be started."
            return nil
        }
        problem = nil
        log.info("eufy-bridge started on port \(port)")
        let reader = Task { [weak self] in
            for await line in process.output { await self?.handle(line) }
        }
        let exit = await withTaskCancellationHandler {
            await process.waitUntilExit()
        } onCancel: {
            process.terminate()
        }
        await reader.value
        log.info("eufy-bridge ended (\(exit))")
        return exit.reason == .exited ? exit.status : nil
    }

    /// A helper line. Only `cb-eufy` lines are read; they reach the log redacted (the helper scrubs secrets itself too).
    private func handle(_ raw: String) {
        guard let line = WyzeHelperSupervisor.statusLine(raw, prefix: "cb-eufy ") else { return }
        let fields = WyzeHelperSupervisor.fields(of: line)
        switch fields["event"] {
        case "listening":
            setListening(true)
            log.info("eufy-bridge is listening")
        case "camera":
            guard let serial = fields["serial"], let kind = fields["kind"] else { return }
            let event = Event(serial: serial, kind: kind)
            for subscriber in subscribers.values where subscriber.serial == serial { subscriber.continuation.yield(event) }
            log.debug("eufy event \(kind) for \(Redact.string(serial))")
        case "error":
            if let message = fields["message"] { problem = Redact.string(message) }
            log.warning(Redact.string(String(line.prefix(300))))
        default:
            log.info(Redact.string(String(line.prefix(300))))
        }
    }
}

/// What the eufy plugin needs from the helper (`EufyBridge`; tests use a fake).
public protocol EufyBridgeCalling: Sendable {
    func setWanted(_ on: Bool) async
    func isInstalled() async -> Bool
    /// An HTTP request to the helper's API; throws a sentence for the person when the helper isn't there.
    func request(_ method: String, _ path: String, body: Data?) async throws -> (status: Int, body: Data)
}

extension EufyBridge: EufyBridgeCalling {
    public func request(_ method: String, _ path: String, body: Data?) async throws -> (status: Int, body: Data) {
        try await call(method, path, body: body)
    }
}
