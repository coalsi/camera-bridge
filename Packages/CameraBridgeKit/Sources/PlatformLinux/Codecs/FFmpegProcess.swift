import BridgeSupport
import Foundation
import MediaCore
#if os(Linux)
import Glibc
#endif

// The process layer of the Linux codecs: everything above it (argument building, FLV framing, the codec objects) talks to
// `FFmpegProcess` / `FFmpegProcessLaunching`, so tests drive it with a fake and no ffmpeg at all.

/// What to run.
struct FFmpegProcessSpec: Sendable, Equatable {
    var executable: URL
    var arguments: [String]
    /// Names the process in logs and errors ("video transcoder", "snapshot").
    var label: String
    /// Run at this niceness (1…19, higher is lower priority): the real launcher starts the program under `nice -n <niceness>`, so every
    /// thread it makes has it. nil or 0: as the parent is. Without a `nice` program the child runs as it is, rather than not at all.
    var niceness: Int? = nil

    /// Where `nice` is, nil when this system has none.
    static let nicePath: String? = ["/usr/bin/nice", "/bin/nice"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// The program and arguments the real launcher starts: the program itself, or `nice -n <niceness> <program> <arguments>`.
    func launchCommand(nice: String? = FFmpegProcessSpec.nicePath) -> (executable: URL, arguments: [String]) {
        guard let niceness, niceness > 0, let nice else { return (executable, arguments) }
        return (URL(fileURLWithPath: nice), ["-n", String(min(niceness, 19)), executable.path] + arguments)
    }
}

/// How a child ended, with the last lines it wrote to stderr.
struct FFmpegExit: Sendable, Equatable {
    var status: Int32
    var signaled: Bool
    var stderrTail: [String]

    var summary: String {
        let how = signaled ? "was killed by signal \(status)" : "exited with status \(status)"
        return stderrTail.isEmpty ? how : how + ": " + stderrTail.joined(separator: " | ")
    }
}

/// One running child: stdin is a bounded queue drained by a writer thread, so no caller ever blocks on a full pipe.
protocol FFmpegProcess: AnyObject, Sendable {
    /// Queues bytes for the child's stdin. Throws `MediaCodecError` when the child is gone or the queue is over its limit.
    func write(_ data: Data) throws
    /// Closes stdin once everything queued is written (the child sees end of input and finishes).
    func closeInput()
    /// SIGTERM now, SIGKILL shortly after if it is still there. Idempotent; never waits.
    func terminate()
}

protocol FFmpegProcessLaunching: Sendable {
    /// Starts the child. `onOutput` gets its stdout in chunks on the reader thread (it may block to push back on the child);
    /// `onExit` is called once, after the output ended and the child was reaped.
    func launch(_ spec: FFmpegProcessSpec, onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (FFmpegExit) -> Void) throws -> any FFmpegProcess
}

// MARK: - Foundation.Process implementation

/// Spawns real children with `Foundation.Process`. Three threads per child (stdout, stderr, stdin writer); the stdout
/// thread reaps the child, so none is left as a zombie.
struct SystemFFmpegLauncher: FFmpegProcessLaunching {
    /// Bytes allowed to wait for the child's stdin (a camera GOP is far below this; raw pictures for one JPEG fit).
    var maxPendingInput = 32 << 20
    /// Lines of stderr kept for error messages.
    static let stderrLines = 20

    init(maxPendingInput: Int = 32 << 20) {
        self.maxPendingInput = maxPendingInput
    }

    func launch(_ spec: FFmpegProcessSpec, onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (FFmpegExit) -> Void) throws -> any FFmpegProcess {
        Self.ignoreSIGPIPE()
        let child = try SystemChild(spec: spec, maxPendingInput: maxPendingInput, onOutput: onOutput, onExit: onExit)
        return child
    }

    /// Writing to a pipe whose reader died must fail with EPIPE, not kill the daemon.
    private static let sigpipeIgnored: Bool = {
        _ = signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private static func ignoreSIGPIPE() { _ = sigpipeIgnored }
}

private final class SystemChild: FFmpegProcess, @unchecked Sendable {
    private let spec: FFmpegProcessSpec
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let maxPendingInput: Int
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (FFmpegExit) -> Void

    // Guarded by `condition`.
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var pendingBytes = 0
    private var inputClosing = false
    private var inputDead = false
    private var terminated = false
    private var exited = false
    private var stderrLines: [String] = []

    private let exitSemaphore = DispatchSemaphore(value: 0)
    private let stderrDone = DispatchSemaphore(value: 0)
    private let stdoutDone = DispatchSemaphore(value: 0)

    init(spec: FFmpegProcessSpec, maxPendingInput: Int, onOutput: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (FFmpegExit) -> Void) throws {
        self.spec = spec
        self.maxPendingInput = maxPendingInput
        self.onOutput = onOutput
        self.onExit = onExit
        let command = spec.launchCommand()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = Self.childEnvironment(ProcessInfo.processInfo.environment)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let semaphore = exitSemaphore
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try Self.withUnblockedSignals { try process.run() }
        } catch {
            for pipe in [stdinPipe, stdoutPipe, stderrPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw MediaCodecError.unsupported("could not start \(spec.executable.lastPathComponent) for the \(spec.label): \(error.localizedDescription)")
        }
        // The child owns its ends now; keeping ours would stop end-of-file from ever arriving.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe.fileHandleForReading.close()
        startThreads()
    }

    // MARK: Input

    /// The daemon's environment without what belongs to the daemon alone: systemd's notify and watchdog sockets, socket activation and
    /// Camera Bridge's own settings (a setup code can be one), plus ffmpeg's plain logging.
    static func childEnvironment(_ environment: [String: String]) -> [String: String] {
        var child = environment.filter { key, _ in
            !(key == "NOTIFY_SOCKET" || key.hasPrefix("WATCHDOG_") || key.hasPrefix("LISTEN_") || key.hasPrefix("CAMERABRIDGE_"))
        }
        child["AV_LOG_FORCE_NOCOLOR"] = "1"
        return child
    }

    /// Runs `start` with no signal blocked on this thread: a child inherits the signal mask of the thread that starts it, and libdispatch's
    /// worker threads block every signal, so an ffmpeg started from one never saw SIGTERM (`terminate()` then always ended in SIGKILL, and
    /// systemd's stop of the service could not stop it either). `ProcessHelperLauncher` does the same.
    static func withUnblockedSignals<T>(_ start: () throws -> T) rethrows -> T {
        #if os(Linux)
        var unblocked = sigset_t()
        var previous = sigset_t()
        sigemptyset(&unblocked)
        pthread_sigmask(SIG_SETMASK, &unblocked, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        #endif
        return try start()
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        if exited || inputDead || terminated || inputClosing {
            throw MediaCodecError.unsupported("ffmpeg (\(spec.label)) is not accepting input")
        }
        guard pendingBytes + data.count <= maxPendingInput else {
            throw MediaCodecError.unsupported("ffmpeg (\(spec.label)) is not keeping up: \(pendingBytes) bytes are waiting for it")
        }
        queue.append(data)
        pendingBytes += data.count
        condition.broadcast()
    }

    func closeInput() {
        condition.lock()
        inputClosing = true
        condition.broadcast()
        condition.unlock()
    }

    func terminate() {
        condition.lock()
        let first = !terminated
        terminated = true
        let alreadyExited = exited
        queue.removeAll()
        pendingBytes = 0
        condition.broadcast()
        condition.unlock()
        guard first, !alreadyExited else { return }
        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier
        // ffmpeg ends on SIGTERM within a frame or two; a wedged one gets SIGKILL.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(700)) { [weak self] in
            guard let self, self.isStillRunning(), pid > 0 else { return }
            kill(pid, SIGKILL)
        }
    }

    private func isStillRunning() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !exited && process.isRunning
    }

    // MARK: Threads

    private func startThreads() {
        let writer = Thread { [self] in writerLoop() }
        writer.name = "ffmpeg-stdin"
        writer.stackSize = 256 << 10
        let errors = Thread { [self] in stderrLoop() }
        errors.name = "ffmpeg-stderr"
        errors.stackSize = 256 << 10
        let reader = Thread { [self] in stdoutLoop() }
        reader.name = "ffmpeg-stdout"
        reader.stackSize = 256 << 10
        let reaper = Thread { [self] in reapLoop() }
        reaper.name = "ffmpeg-reaper"
        reaper.stackSize = 256 << 10
        writer.start()
        errors.start()
        reader.start()
        reaper.start()
    }

    private func writerLoop() {
        let descriptor = stdinPipe.fileHandleForWriting.fileDescriptor
        while true {
            condition.lock()
            while queue.isEmpty, !inputClosing, !terminated, !exited { condition.wait() }
            if terminated || exited || (queue.isEmpty && inputClosing) {
                condition.unlock()
                break
            }
            let chunk = queue.removeFirst()
            pendingBytes -= chunk.count
            condition.unlock()
            if !Self.writeAll(descriptor, chunk) {
                condition.lock()
                inputDead = true
                queue.removeAll()
                pendingBytes = 0
                condition.unlock()
                break
            }
        }
        try? stdinPipe.fileHandleForWriting.close()
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = posixWrite(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    private func stderrLoop() {
        let descriptor = stderrPipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8192)
        var line = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            for byte in buffer[0..<count] {
                if byte == 0x0A || byte == 0x0D {
                    if !line.isEmpty { record(line: line); line.removeAll(keepingCapacity: true) }
                } else if line.count < 400 {
                    line.append(byte)
                }
            }
        }
        if !line.isEmpty { record(line: line) }
        try? stderrPipe.fileHandleForReading.close()
        stderrDone.signal()
    }

    private func record(line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        condition.lock()
        stderrLines.append(text)
        if stderrLines.count > SystemFFmpegLauncher.stderrLines { stderrLines.removeFirst(stderrLines.count - SystemFFmpegLauncher.stderrLines) }
        condition.unlock()
    }

    private func stdoutLoop() {
        let descriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            onOutput(Data(buffer[0..<count]))
        }
        try? stdoutPipe.fileHandleForReading.close()
        stdoutDone.signal()
    }

    /// Waits for the child to end (Foundation reaps it and calls the termination handler), lets the output readers finish what is
    /// in the pipes, then reports the end once. It does not wait for end-of-file on stdout: a grandchild holding the pipe open
    /// must not hide the child's death.
    private func reapLoop() {
        exitSemaphore.wait()
        // A child that closed stdout but lingers is not our concern; one that died has its pipes closed within moments.
        _ = stdoutDone.wait(timeout: .now() + .milliseconds(1_000))
        _ = stderrDone.wait(timeout: .now() + .milliseconds(1_000))
        condition.lock()
        exited = true
        let tail = stderrLines
        queue.removeAll()
        pendingBytes = 0
        condition.broadcast()
        condition.unlock()
        let signaled = process.terminationReason == .uncaughtSignal
        onExit(FFmpegExit(status: process.terminationStatus, signaled: signaled, stderrTail: tail))
    }
}

/// `write(2)` (Foundation re-exports it on every platform), reachable from inside types that have their own `write`.
private func posixWrite(_ descriptor: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
    Foundation.write(descriptor, pointer, count)
}

// MARK: - Session

/// One launched child with its stdout collected in a bounded buffer and its end recorded: what every codec object holds.
/// Parsing happens on the caller's side (`drain()` hands over the bytes), so a codec's logic is deterministic and testable.
final class FFmpegSession: @unchecked Sendable {
    let label: String
    let startedAt = ContinuousClock.now
    private let condition = NSCondition()
    private var process: (any FFmpegProcess)?
    private var output = Data()
    private var exitInfo: FFmpegExit?
    private var terminated = false
    private var bytesIn = 0
    private let maxBufferedOutput: Int
    /// `waitForOutputAsync` calls waiting for output or the end (resumed by `received`, `ended`, `terminate` or their timeout).
    private var outputWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0

    /// `maxBufferedOutput`: past this the reader thread stops reading, so the child blocks on its stdout (back-pressure).
    init(launcher: any FFmpegProcessLaunching, spec: FFmpegProcessSpec, maxBufferedOutput: Int = 64 << 20) throws {
        label = spec.label
        self.maxBufferedOutput = maxBufferedOutput
        let started = try launcher.launch(spec, onOutput: { [weak self] data in self?.received(data) },
                                          onExit: { [weak self] exit in self?.ended(exit) })
        condition.lock()
        process = started
        let alreadyTerminated = terminated
        condition.unlock()
        if alreadyTerminated { started.terminate() }
    }

    deinit { terminate() }

    private func received(_ data: Data) {
        condition.lock()
        // Back-pressure: hold the reader (and so the child) while the consumer is behind; a terminated session drops output.
        while output.count >= maxBufferedOutput, !terminated { condition.wait() }
        guard !terminated else {
            condition.unlock()
            return
        }
        output.append(data)
        condition.broadcast()
        let waiters = takeOutputWaiters()
        condition.unlock()
        for waiter in waiters { waiter.resume() }
    }

    private func ended(_ exit: FFmpegExit) {
        condition.lock()
        exitInfo = exit
        condition.broadcast()
        let waiters = takeOutputWaiters()
        condition.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Under `condition`'s lock.
    private func takeOutputWaiters() -> [CheckedContinuation<Void, Never>] {
        guard !outputWaiters.isEmpty else { return [] }
        defer { outputWaiters = [:] }
        return Array(outputWaiters.values)
    }

    // MARK: Input

    /// Throws the session's failure when the child is gone.
    func send(_ data: Data) throws {
        let current = lockedProcess()
        guard let current, exit == nil else { throw failure }
        do {
            try current.write(data)
            condition.lock()
            bytesIn += data.count
            condition.unlock()
        } catch {
            // A dead child explains the failed write better than the pipe does.
            if waitForExit(timeout: .milliseconds(200)) != nil { throw failure }
            throw error
        }
    }

    func closeInput() { lockedProcess()?.closeInput() }

    private func lockedProcess() -> (any FFmpegProcess)? {
        condition.lock()
        defer { condition.unlock() }
        return terminated ? nil : process
    }

    func terminate() {
        condition.lock()
        let wasTerminated = terminated
        terminated = true
        let current = process
        output.removeAll()
        condition.broadcast()
        let waiters = takeOutputWaiters()
        condition.unlock()
        for waiter in waiters { waiter.resume() }
        if !wasTerminated { current?.terminate() }
    }

    // MARK: Output

    /// Everything the child wrote since the last call.
    func drain() -> Data {
        condition.lock()
        defer { condition.unlock() }
        let data = output
        output = Data()
        condition.broadcast()
        return data
    }

    var bufferedOutputBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return output.count
    }

    /// How the child ended; nil while it runs. (The output it wrote before that is still in `drain()`.)
    var exit: FFmpegExit? {
        condition.lock()
        defer { condition.unlock() }
        return exitInfo
    }

    var isTerminatedByOwner: Bool {
        condition.lock()
        defer { condition.unlock() }
        return terminated
    }

    var failure: MediaCodecError {
        if let exit {
            return .unsupported("ffmpeg (\(label)) \(exit.summary)")
        }
        return .unsupported("ffmpeg (\(label)) is not running")
    }

    /// Blocks until output is buffered, the child ended, or `timeout` passed. Returns whether output is available.
    @discardableResult
    func waitForOutput(timeout: Duration) -> Bool {
        let deadline = Date().addingTimeInterval(timeout / .seconds(1))
        condition.lock()
        defer { condition.unlock() }
        while output.isEmpty, exitInfo == nil, !terminated {
            if !condition.wait(until: deadline) { break }
        }
        return !output.isEmpty
    }

    /// Blocks until the child ended or `timeout` passed.
    @discardableResult
    func waitForExit(timeout: Duration) -> FFmpegExit? {
        let deadline = Date().addingTimeInterval(timeout / .seconds(1))
        condition.lock()
        defer { condition.unlock() }
        while exitInfo == nil {
            if !condition.wait(until: deadline) { break }
        }
        return exitInfo
    }

    /// Returns when output is buffered, the child ended, the session was terminated, `timeout` passed, or the task was cancelled. Woken by the
    /// reader itself (a 2 ms sleep loop here cost about a thousand wake-ups a second with ten cameras' decoders).
    func waitForOutputAsync(timeout: Duration) async {
        let id = makeWaiterID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                condition.lock()
                guard output.isEmpty, exitInfo == nil, !terminated, !Task.isCancelled else {
                    condition.unlock()
                    continuation.resume()
                    return
                }
                outputWaiters[id] = continuation
                condition.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(max(0, timeout / .nanoseconds(1))))) { [weak self] in
                    self?.resumeOutputWaiter(id)
                }
            }
        } onCancel: {
            resumeOutputWaiter(id)
        }
    }

    private func makeWaiterID() -> Int {
        condition.lock()
        defer { condition.unlock() }
        nextWaiter += 1
        return nextWaiter
    }

    private func resumeOutputWaiter(_ id: Int) {
        condition.lock()
        let waiter = outputWaiters.removeValue(forKey: id)
        condition.unlock()
        waiter?.resume()
    }
}
