#if os(Linux)
import BridgeSupport
import Foundation
import Glibc
import Synchronization

/// `HelperLaunching` on Linux: helper programs (go2rtc) installed next to the daemon or under `/usr/lib/camera-bridge`,
/// started with `Process` with an almost empty environment, standard input closed and output (stdout and stderr together)
/// delivered line by line.
///
/// Where a helper is looked for, in order: the folder named by the `CAMERABRIDGE_HELPERS_DIR` environment variable
/// (development and tests), the daemon's own folder, `/usr/lib/camera-bridge/helpers`, `/usr/libexec/camera-bridge`.
public final class ProcessHelperLauncher: HelperLaunching {
    public static let helpersDirectoryVariable = "CAMERABRIDGE_HELPERS_DIR"

    private let searchDirectories: [URL]

    /// `searchDirectories` replaces the default places (tests).
    public init(searchDirectories: [URL]? = nil) {
        if let searchDirectories {
            self.searchDirectories = searchDirectories
        } else {
            var directories: [URL] = []
            if let override = ProcessInfo.processInfo.environment[Self.helpersDirectoryVariable], !override.isEmpty {
                directories.append(URL(filePath: override, directoryHint: .isDirectory))
            }
            if let own = Self.executablePath(of: getpid()) {
                directories.append(URL(filePath: own).deletingLastPathComponent())
            }
            directories.append(URL(filePath: "/usr/lib/camera-bridge/helpers", directoryHint: .isDirectory))
            directories.append(URL(filePath: "/usr/libexec/camera-bridge", directoryHint: .isDirectory))
            self.searchDirectories = directories
        }
    }

    public func locate(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in searchDirectories {
            let candidate = directory.appending(path: name, directoryHint: .notDirectory)
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }

    public func launch(_ spec: HelperLaunchSpec) throws -> any HelperProcess {
        guard FileManager.default.isExecutableFile(atPath: spec.executable.path(percentEncoded: false)) else {
            throw HelperLaunchError.unavailable("\(spec.executable.lastPathComponent) is not installed")
        }
        let helper = ProcessHelper()
        do {
            try helper.start(spec)
        } catch {
            throw HelperLaunchError.launchFailed("\(spec.executable.lastPathComponent) could not be started (\((error as NSError).domain) \((error as NSError).code))")
        }
        if let pidFile = spec.pidFile, let pid = helper.processID {
            try? PrivateFiles.write(Data("\(pid)\n".utf8), to: pidFile)
        }
        return helper
    }

    @discardableResult
    public func endStaleProcess(pidFile: URL, executable: URL) -> Bool {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let data = try? Data(contentsOf: pidFile), let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        // Only a process that still is this very program: the number may belong to anything by now.
        guard let running = Self.executablePath(of: pid) else { return false }
        guard URL(filePath: running).resolvingSymlinksInPath().path(percentEncoded: false)
                == executable.resolvingSymlinksInPath().path(percentEncoded: false) else { return false }
        Glibc.kill(pid, SIGTERM)
        for _ in 0..<20 {   // at most two seconds
            if Glibc.kill(pid, 0) != 0 { return true }
            usleep(100_000)
        }
        Glibc.kill(pid, SIGKILL)
        return true
    }

    /// Where process `pid` was started from (`/proc/<pid>/exe`), nil when there is no such process.
    static func executablePath(of pid: Int32) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
    }
}

/// One `Process` with its output pipe.
private final class ProcessHelper: HelperProcess {
    private struct State {
        var exit: HelperExit?
        var waiters: [CheckedContinuation<HelperExit, Never>] = []
    }

    private let process = Process()
    private let pipe = Pipe()
    private let state = Mutex(State())
    private let stream = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(500))

    var output: AsyncStream<String> { stream.stream }

    var processID: Int32? {
        let pid = process.processIdentifier
        return pid > 0 ? pid : nil
    }

    func start(_ spec: HelperLaunchSpec) throws {
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        var environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        for (key, value) in spec.environment { environment[key] = value }
        process.environment = environment
        process.currentDirectoryURL = spec.workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [weak self] process in
            let exit = HelperExit(status: process.terminationStatus, reason: process.terminationReason == .uncaughtSignal ? .signaled : .exited)
            self?.finished(exit)
        }
        // The child inherits the signal mask of the thread that starts it, and libdispatch's worker threads block every signal: a
        // helper started from one would never see SIGTERM. Start it with an empty mask.
        var unblocked = sigset_t()
        var previous = sigset_t()
        sigemptyset(&unblocked)
        pthread_sigmask(SIG_SETMASK, &unblocked, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        try process.run()
        // The child holds the only write end now (swift-corelibs-foundation leaves the parent's open, and the reader below would
        // never see the end of the file).
        try? pipe.fileHandleForWriting.close()
        startReading()
    }

    /// Reads the pipe on a thread of its own (a blocking read, to its end), cutting it into lines.
    private func startReading() {
        let continuation = stream.continuation
        let readHandle = pipe.fileHandleForReading
        let descriptor = readHandle.fileDescriptor
        DispatchQueue.global(qos: .utility).async {
            var splitter = HelperOutput.LineSplitter()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                // (`FileHandle.availableData` traps on EINTR, which the child's exit signal causes.)
                let count = buffer.withUnsafeMutableBytes { Glibc.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }   // end of file: the helper ended and everything it wrote was read
                for line in splitter.feed(Data(buffer[0..<count])) { continuation.yield(line) }
            }
            if let rest = splitter.finish() { continuation.yield(rest) }
            continuation.finish()
            try? readHandle.close()
        }
    }

    private func finished(_ exit: HelperExit) {
        let waiters = state.withLock { state -> [CheckedContinuation<HelperExit, Never>] in
            state.exit = exit
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: exit) }
    }

    func waitUntilExit() async -> HelperExit {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> HelperExit? in
                if let exit = state.exit { return exit }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    /// SIGTERM to the helper while it runs (sent directly: `Process.terminate()` does nothing when the process has not settled
    /// into its running state yet).
    func terminate() {
        send(SIGTERM)
    }

    func kill() {
        send(SIGKILL)
    }

    private func send(_ number: Int32) {
        let pid = process.processIdentifier
        guard pid > 1, state.withLock({ $0.exit == nil }) else { return }
        Glibc.kill(pid, number)
    }
}
#endif
