import BridgeSupport
import Foundation

/// What a camera's driver needs from the go2rtc helper: a local RTSP address for its source, and what went wrong.
public protocol Go2RTCStreamProviding: Sendable {
    /// Registers (or updates) the stream `streamID` and returns once the helper serves it: `rtsp://127.0.0.1:<port>/<streamID>`.
    /// Nothing is dialled at the camera's service before a client asks for the stream.
    func attach(streamID: String, source: Go2RTCSource) async throws -> URL
    /// Forgets the stream; the helper ends when no stream is left.
    func detach(streamID: String) async
    /// The helper's latest warnings and errors about the stream (secrets masked), newest last.
    func problems(streamID: String) async -> [String]
}

public enum Go2RTCError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The go2rtc program is not part of this installation.
    case helperMissing
    case invalidStreamName
    /// The helper did not come up in time, or keeps failing; `reason` is its last problem.
    case notReady(String)
    case stopped

    public var description: String {
        switch self {
        case .helperMissing:
            "The streaming helper (go2rtc) is not installed with this copy of Camera Bridge."
        case .invalidStreamName:
            "The stream name is not valid."
        case .notReady(let reason):
            reason.isEmpty ? "The streaming helper (go2rtc) is not running." : "The streaming helper (go2rtc) is not running: \(reason)"
        case .stopped:
            "The streaming helper (go2rtc) was stopped."
        }
    }
}

/// The go2rtc helper (github.com/AlexxIT/go2rtc, MIT) as a managed child process.
///
/// It serves every camera that uses it (Ring, Google Nest, Wyze, Tuya, UniFi Protect's RTSPS, other go2rtc sources) as plain
/// RTSP on `127.0.0.1`, which Camera Bridge's own RTSP ingest reads like any camera: `rtsp://127.0.0.1:<port>/<stream-id>`.
///
/// - **Ports.** The API and RTSP ports are picked at random among the free ports of this Mac the first time the helper starts
///   and are kept for the life of the manager, so the addresses cameras hold stay valid across restarts. Both bind 127.0.0.1.
/// - **Secrets.** Sources are handed to the helper in its environment; the configuration file only names the variables, so no
///   secret reaches a file, a command line or a log (`Go2RTCConfig`). The file is 0600 in a 0700 folder, removed as soon as
///   the helper answers and when it stops.
/// - **Supervision.** The helper starts when the first stream is attached and ends when the last is detached. It restarts after
///   a crash with exponential backoff (reset after it ran steadily), and also when the set of streams changes (the
///   configuration is read once at start). A health check on its API decides when it is up. Its output goes to the log, with
///   secrets masked; warnings and errors are kept per stream for the camera's status.
public actor Go2RTCManager: Go2RTCStreamProviding {
    public struct Timing: Sendable {
        /// The first and the longest wait before a crashed helper starts again.
        public var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
        /// A run this long counts as healthy: the backoff starts over.
        public var stableAfter: Duration = .seconds(30)
        /// How often the health check asks, and how long a start may take before it counts as failed.
        public var healthInterval: Duration = .milliseconds(200)
        public var healthTimeout: Duration = .seconds(10)
        /// How long `attach` waits for the helper to serve the stream.
        public var attachTimeout: Duration = .seconds(30)
        /// A stop waits this long for SIGTERM to work before it uses SIGKILL.
        public var terminateGrace: Duration = .seconds(3)
        /// Changes this close together restart the helper once.
        public var settle: Duration = .milliseconds(300)
        /// How often a running helper is checked for exit and for changes to its streams.
        public var watchInterval: Duration = .milliseconds(100)
        /// The sign-in page's helper ends by itself after this long.
        public var setupLifetime: Duration = .seconds(20 * 60)

        public init() {}
    }

    /// `true`: the helper's API answers. `password`: the one for this run (nil: the API asks for none).
    public typealias HealthCheck = @Sendable (_ apiPort: UInt16, _ password: String?) async -> Bool
    /// A free port on 127.0.0.1, nil when none could be found.
    public typealias PortPicker = @Sendable () async -> UInt16?

    public static let helperName = "go2rtc"
    /// The prefix of the stream names Camera Bridge uses (`cb-<camera id>`).
    public static let streamPrefix = "cb-"

    private enum Phase: Equatable {
        case stopped, starting, running, backingOff
    }

    private struct Waiter {
        var version: Int
        var continuation: CheckedContinuation<Void, any Error>
        var timeout: Task<Void, Never>?
    }

    private enum Outcome {
        case stopRequested
        case superseded
        case failed(String)
    }

    private struct SetupSession {
        var run: Go2RTCRun
        var directory: URL
        var expiry: Task<Void, Never>
    }

    private let launcher: any HelperLaunching
    private let directory: URL
    private let pickPort: PortPicker
    private let healthCheck: HealthCheck
    private let timing: Timing
    private let log = Log(category: "go2rtc")

    private var streams: [String: Go2RTCSource] = [:]
    /// Bumped by every change to `streams`.
    private var version = 0
    /// The version the running helper's configuration was made from, once it answers.
    private var servedVersion = -1
    private var phase: Phase = .stopped
    private var ports: (api: UInt16, rtsp: UInt16)?
    private var supervisor: Task<Void, Never>?
    private var stopRequested = false
    private var waiters: [UUID: Waiter] = [:]
    private var recent: [String] = []
    private var recentByStream: [String: [String]] = [:]
    private var lastFailure = ""
    private var setup: SetupSession?
    private var runCount = 0
    private var lineContinuation: AsyncStream<String>.Continuation?
    private var logPump: Task<Void, Never>?

    /// `directory`: where the helper's private files go (`…/go2rtc`; created 0700).
    public init(launcher: any HelperLaunching, directory: URL, pickPort: @escaping PortPicker = Go2RTCManager.noPorts,
                healthCheck: @escaping HealthCheck = Go2RTCManager.noHealthCheck, timing: Timing = Timing()) {
        self.launcher = launcher
        self.directory = directory
        self.pickPort = pickPort
        self.healthCheck = healthCheck
        self.timing = timing
    }

    public static let noPorts: PortPicker = { nil }
    public static let noHealthCheck: HealthCheck = { _, _ in false }

    // MARK: State for the app and the tests

    /// Whether the go2rtc program is part of this installation.
    public nonisolated var isInstalled: Bool { launcher.locate(Self.helperName) != nil }

    /// Whether the helper runs and answers.
    public var isRunning: Bool { phase == .running }

    /// How many times the helper was started.
    public var startCount: Int { runCount }

    /// The ports of the running (or last) helper: API and RTSP, both on 127.0.0.1.
    public var currentPorts: (api: UInt16, rtsp: UInt16)? { ports }

    public var streamIDs: [String] { streams.keys.sorted() }

    /// Warnings and errors of the helper that are not about one stream, newest last.
    public var generalProblems: [String] { recent }

    public func problems(streamID: String) -> [String] {
        recentByStream[streamID] ?? []
    }

    /// `cb-<camera id>`: a camera's stream name.
    public nonisolated static func streamName(for cameraID: UUID) -> String {
        streamPrefix + cameraID.uuidString.lowercased()
    }

    // MARK: Streams

    public func attach(streamID: String, source: Go2RTCSource) async throws -> URL {
        guard launcher.locate(Self.helperName) != nil else { throw Go2RTCError.helperMissing }
        guard Go2RTCConfig.isValidStreamName(streamID) else { throw Go2RTCError.invalidStreamName }
        if streams[streamID] != source {
            streams[streamID] = source
            version += 1
        }
        recentByStream[streamID] = nil
        let needed = version
        ensureSupervisor()
        try await waitUntilServed(needed)
        guard let rtsp = ports?.rtsp, let url = URL(string: "rtsp://127.0.0.1:\(rtsp)/\(streamID)") else { throw Go2RTCError.notReady(lastFailure) }
        return url
    }

    public func detach(streamID: String) async {
        guard streams.removeValue(forKey: streamID) != nil else { return }
        recentByStream[streamID] = nil
        version += 1
    }

    /// Ends the helper and the sign-in page's helper, whatever is attached, and removes their files. The manager can be used again.
    public func stop() async {
        streams = [:]
        version += 1
        stopRequested = true
        let task = supervisor
        failWaiters(Go2RTCError.stopped)
        await endSetupSession()
        if let task {
            _ = try? await withDeadline(timing.terminateGrace + .seconds(3), followsCancellation: false) { await task.value }
            task.cancel()
        }
        supervisor = nil
        stopRequested = false
        phase = .stopped
        servedVersion = -1
        removeConfigurationFile()
    }

    // MARK: Waiting for the helper

    private func waitUntilServed(_ needed: Int) async throws {
        if phase == .running, servedVersion >= needed { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let timeout = Task { [timing] in
                    try? await Task.sleep(for: timing.attachTimeout)
                    guard !Task.isCancelled else { return }
                    self.expireWaiter(id)
                }
                waiters[id] = Waiter(version: needed, continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func resolveWaiters() {
        for (id, waiter) in waiters where waiter.version <= servedVersion {
            waiter.timeout?.cancel()
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    private func failWaiters(_ error: any Error) {
        let pending = waiters
        waiters = [:]
        for waiter in pending.values {
            waiter.timeout?.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    private func expireWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: Go2RTCError.notReady(lastFailure))
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    // MARK: Supervision

    private func ensureSupervisor() {
        startLogPump()
        guard supervisor == nil else { return }
        stopRequested = false
        phase = .starting
        supervisor = Task { await self.supervise() }
    }

    private func supervise() async {
        var backoff = timing.backoff
        loop: while !Task.isCancelled, !stopRequested, !streams.isEmpty {
            let snapshot = streams
            let configurationVersion = version
            let started = ContinuousClock.now
            phase = .starting
            let outcome = await runOnce(snapshot: snapshot, configurationVersion: configurationVersion)
            switch outcome {
            case .stopRequested:
                break loop
            case .superseded:
                try? await Task.sleep(for: timing.settle)   // changes close together restart once
            case .failed(let reason):
                lastFailure = reason
                if ContinuousClock.now - started >= timing.stableAfter { backoff.reset() }
                let delay = backoff.next()
                phase = .backingOff
                log.warning("go2rtc: \(reason); starting it again in \(Int(delay.timeInterval)) s")
                await pause(delay, whileVersionIs: configurationVersion)
            }
        }
        // No suspension from the loop's last check to here: a stream attached from now on starts a new supervisor.
        phase = .stopped
        servedVersion = -1
        removeConfigurationFile()
        supervisor = nil
    }

    /// Waits `delay`, or until the streams change (the new configuration may be the cure) or everything is stopped.
    private func pause(_ delay: Duration, whileVersionIs current: Int) async {
        let deadline = ContinuousClock.now + delay
        while ContinuousClock.now < deadline, !Task.isCancelled, !stopRequested, !streams.isEmpty, version == current {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func runOnce(snapshot: [String: Go2RTCSource], configurationVersion: Int) async -> Outcome {
        guard let executable = launcher.locate(Self.helperName) else { return .failed("the go2rtc program is not installed") }
        if ports == nil {
            guard let api = await pickPort(), let rtsp = await pickPort(), api != rtsp else { return .failed("no free port on this Mac") }
            ports = (api, rtsp)
        }
        guard let ports else { return .failed("no free port on this Mac") }
        let configURL = configurationURL
        let pidFile = directory.appending(path: "go2rtc.pid", directoryHint: .notDirectory)
        let password = Go2RTCConfig.randomPassword()
        var environment: [String: String] = [Go2RTCConfig.passwordVariable: password]
        var configured: [Go2RTCConfig.Stream] = []
        for (index, name) in snapshot.keys.sorted().enumerated() {
            guard let source = snapshot[name] else { continue }
            let variable = "CB_SRC_\(index)"
            environment[variable] = Go2RTCConfig.environmentValue(forSource: source.url)
            configured.append(Go2RTCConfig.Stream(name: name, variable: variable))
        }
        let config = Go2RTCConfig(apiPort: ports.api, rtspPort: ports.rtsp, streams: configured)
        do {
            try PrivateFiles.prepareDirectory(directory)
            try PrivateFiles.write(Data(config.yaml.utf8), to: configURL)
        } catch {
            return .failed("its configuration could not be written")
        }
        launcher.endStaleProcess(pidFile: pidFile, executable: executable)
        let run: Go2RTCRun
        do {
            run = try makeRun(executable: executable, configURL: configURL, environment: environment, pidFile: pidFile, workingDirectory: directory)
        } catch {
            removeConfigurationFile()
            return .failed("it could not be started (\(error))")
        }
        runCount += 1
        log.info("go2rtc started for \(snapshot.count) stream\(snapshot.count == 1 ? "" : "s") (API and RTSP on 127.0.0.1)")
        guard await waitHealthy(run, port: ports.api, password: password) else {
            let exit = run.exit
            await run.terminate(grace: timing.terminateGrace)
            removeConfigurationFile()
            try? FileManager.default.removeItem(at: pidFile)
            return .failed(exit.map { "it ended right after starting (\($0))" } ?? "it did not answer within \(Int(timing.healthTimeout.timeInterval)) s")
        }
        removeConfigurationFile()   // read once at start; it never held a secret, but nothing needs it now
        phase = .running
        servedVersion = configurationVersion
        lastFailure = ""
        resolveWaiters()
        let outcome = await watch(run, configurationVersion: configurationVersion)
        await run.terminate(grace: timing.terminateGrace)
        try? FileManager.default.removeItem(at: pidFile)
        phase = .starting
        servedVersion = -1
        return outcome
    }

    private func makeRun(executable: URL, configURL: URL, environment: [String: String], pidFile: URL?, workingDirectory: URL) throws -> Go2RTCRun {
        let lines = lineContinuation
        return try Go2RTCRun(launcher: launcher,
                             plan: Go2RTCRun.Plan(executable: executable, arguments: ["-c", configURL.path(percentEncoded: false)],
                                                  environment: environment, pidFile: pidFile, workingDirectory: workingDirectory),
                             onLine: { lines?.yield($0) })
    }

    /// Waits while the helper runs: ends when it exits (`failed`), when the streams changed since `configurationVersion`
    /// (`superseded`) or when everything was removed or stopped.
    private func watch(_ run: Go2RTCRun, configurationVersion: Int) async -> Outcome {
        while !Task.isCancelled {
            if stopRequested || streams.isEmpty { return .stopRequested }
            if version != configurationVersion { return .superseded }
            if let exit = run.exit { return .failed("it ended (\(exit))") }
            try? await Task.sleep(for: timing.watchInterval)
        }
        return .stopRequested
    }

    private func waitHealthy(_ run: Go2RTCRun, port: UInt16, password: String?) async -> Bool {
        let deadline = ContinuousClock.now + timing.healthTimeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if run.exit != nil { return false }
            if await healthCheck(port, password) { return true }
            try? await Task.sleep(for: timing.healthInterval)
        }
        return false
    }

    private func startLogPump() {
        guard logPump == nil else { return }
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(500))
        lineContinuation = continuation
        logPump = Task { [weak self] in
            for await line in stream { await self?.handle(line: line) }
        }
    }

    private var configurationURL: URL { directory.appending(path: "go2rtc.yaml", directoryHint: .notDirectory) }

    private func removeConfigurationFile() {
        try? FileManager.default.removeItem(at: configurationURL)
    }

    // MARK: Output

    private func handle(line: String) {
        let text = Self.sanitized(line)
        guard !text.isEmpty else { return }
        let (level, message) = Self.level(of: text)
        let stream = Self.streamName(in: message)
        let cameraLog = stream.flatMap { name -> Log? in
            guard name.hasPrefix(Self.streamPrefix), let id = UUID(uuidString: String(name.dropFirst(Self.streamPrefix.count))) else { return nil }
            return Log(category: "go2rtc", cameraID: id)
        } ?? log
        switch level {
        case .error: cameraLog.warning("go2rtc: \(message)")
        case .warning: cameraLog.info("go2rtc: \(message)")
        default: cameraLog.debug("go2rtc: \(message)")
        }
        guard level == .error || level == .warning else { return }
        if let stream {
            var list = recentByStream[stream] ?? []
            list.append(message)
            if list.count > 10 { list.removeFirst() }
            recentByStream[stream] = list
        } else {
            recent.append(message)
            if recent.count > 10 { recent.removeFirst() }
            if level == .error { lastFailure = message }
        }
    }

    /// Strips escape sequences and masks secrets in a line of the helper's output (`ring:?refresh_token=…`, a key in a
    /// stream address, `enr=…`).
    static func sanitized(_ line: String) -> String {
        var text = line
        if text.contains("\u{1B}") { text = text.replacing(/\u{1B}\[[0-9;]*m/, with: "") }
        text = Redact.string(text)
        text = text.replacing(/\b(enr|uid|mac)=[^&\s"']+/.ignoresCase()) { "\($0.1)=***" }
        // A stream address with a key in its path: rtspx://host:7441/<key>.
        text = text.replacing(/(rtsps?x?:\/\/[^\/\s"']+\/)[^\s"'?]+/) { "\($0.1)***" }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func level(of line: String) -> (LogLevel, String) {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return (.info, line) }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        switch first {
        case "ERR", "FTL", "PNC": return (.error, rest)
        case "WRN": return (.warning, rest)
        case "INF": return (.info, rest)
        case "DBG", "TRC": return (.debug, rest)
        default: return (.info, line)
        }
    }

    static func streamName(in message: String) -> String? {
        message.firstMatch(of: /\bstream=([A-Za-z0-9_\-]+)/).map { String($0.1) }
    }

    // MARK: Sign-in page

    /// Starts a second, short-lived helper that serves go2rtc's own pages for signing in to a service (Ring: email, password and
    /// the 2FA code; Wyze; Tuya; Nest) and returns the address of its start page on 127.0.0.1. Camera Bridge never sees those
    /// credentials: the person types them into go2rtc's page and copies the source address it shows. The helper ends after
    /// `Timing.setupLifetime`, on `endSetupSession()` and on `stop()`; its files are removed with it.
    public func beginSetupSession() async throws -> URL {
        guard let executable = launcher.locate(Self.helperName) else { throw Go2RTCError.helperMissing }
        await endSetupSession()
        guard let port = await pickPort() else { throw Go2RTCError.notReady("no free port on this Mac") }
        startLogPump()
        let folder = directory.appending(path: "setup-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let configURL = folder.appending(path: "go2rtc.yaml", directoryHint: .notDirectory)
        let config = Go2RTCConfig(apiPort: port, rtspPort: nil, modules: Go2RTCConfig.setupModules, apiPaths: Go2RTCConfig.setupAPIPaths,
                                  requiresAPIPassword: false)
        do {
            try PrivateFiles.prepareDirectory(folder)
            try PrivateFiles.write(Data(config.yaml.utf8), to: configURL)
        } catch {
            throw Go2RTCError.notReady("its configuration could not be written")
        }
        let run: Go2RTCRun
        do {
            run = try makeRun(executable: executable, configURL: configURL, environment: [:], pidFile: nil, workingDirectory: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw Go2RTCError.notReady("it could not be started")
        }
        guard await waitHealthy(run, port: port, password: nil) else {
            await run.terminate(grace: timing.terminateGrace)
            try? FileManager.default.removeItem(at: folder)
            throw Go2RTCError.notReady("it did not answer")
        }
        let expiry = Task { [timing] in
            try? await Task.sleep(for: timing.setupLifetime)
            guard !Task.isCancelled else { return }
            await self.endSetupSession()
        }
        setup = SetupSession(run: run, directory: folder, expiry: expiry)
        log.info("go2rtc sign-in page started on 127.0.0.1:\(port)")
        guard let url = URL(string: "http://127.0.0.1:\(port)/add.html") else { throw Go2RTCError.notReady("bad address") }
        return url
    }

    public func endSetupSession() async {
        guard let session = setup else { return }
        setup = nil
        session.expiry.cancel()
        await session.run.terminate(grace: timing.terminateGrace)
        try? FileManager.default.removeItem(at: session.directory)
        log.info("go2rtc sign-in page closed")
    }

    public var hasSetupSession: Bool { setup != nil }
}
