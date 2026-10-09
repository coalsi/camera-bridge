#if os(macOS)
import BridgeSupport
import Darwin
import Foundation
import Synchronization

/// `HelperLaunching` on macOS: helper programs shipped inside the app bundle (`Contents/Helpers/<name>`), started with
/// `Process` with an almost empty environment, standard input closed and output (stdout and stderr together) delivered line
/// by line. The app is not sandboxed (Developer ID), which is what lets it run a child program.
///
/// Where a helper is looked for, in order: the folder named by the `CAMERABRIDGE_HELPERS_DIR` environment variable
/// (development and tests), `Contents/Helpers` of the main bundle, then `Contents/MacOS` (`forAuxiliaryExecutable`).
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
            directories.append(Bundle.main.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory))
            if let auxiliary = Bundle.main.executableURL?.deletingLastPathComponent() { directories.append(auxiliary) }
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
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let running = URL(filePath: String(cString: buffer)).resolvingSymlinksInPath().path(percentEncoded: false)
        guard running == executable.resolvingSymlinksInPath().path(percentEncoded: false) else { return false }
        Darwin.kill(pid, SIGTERM)
        for _ in 0..<20 {   // at most two seconds
            if Darwin.kill(pid, 0) != 0 { return true }
            usleep(100_000)
        }
        Darwin.kill(pid, SIGKILL)
        return true
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

        let continuation = stream.continuation
        let readHandle = pipe.fileHandleForReading
        let splitter = Mutex(HelperOutput.LineSplitter())
        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {   // end of file: the helper ended and everything it wrote was read
                handle.readabilityHandler = nil
                if let rest = splitter.withLock({ $0.finish() }) { continuation.yield(rest) }
                continuation.finish()
                return
            }
            for line in splitter.withLock({ $0.feed(data) }) { continuation.yield(line) }
        }
        process.terminationHandler = { [weak self] process in
            let exit = HelperExit(status: process.terminationStatus, reason: process.terminationReason == .uncaughtSignal ? .signaled : .exited)
            self?.finished(exit)
        }
        try process.run()
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

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        let pid = process.processIdentifier
        guard pid > 1, process.isRunning else { return }
        Darwin.kill(pid, SIGKILL)
    }
}
#endif
