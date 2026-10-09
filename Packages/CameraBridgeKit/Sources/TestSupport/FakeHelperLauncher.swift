import BridgeSupport
import Foundation
import Synchronization

/// A helper process the test drives: it prints lines (`emit`) and ends (`exit`) when the test says, or when it is asked to end.
public final class FakeHelperProcess: HelperProcess {
    private struct State {
        var exit: HelperExit?
        var waiters: [CheckedContinuation<HelperExit, Never>] = []
        var terminateCalls = 0
        var killCalls = 0
    }

    public let spec: HelperLaunchSpec
    /// The text of the configuration file named by `-c`, read at launch (the file is gone after a healthy start).
    public let configurationAtLaunch: String?
    /// POSIX permissions of that file at launch.
    public let configurationPermissionsAtLaunch: Int?
    public let processID: Int32?
    private let stream = AsyncStream<String>.makeStream()
    private let state = Mutex(State())
    /// Ends on SIGTERM (a well-behaved helper) or only on SIGKILL.
    private let endsOnTerminate: Bool

    init(spec: HelperLaunchSpec, processID: Int32, endsOnTerminate: Bool) {
        self.spec = spec
        self.processID = processID
        self.endsOnTerminate = endsOnTerminate
        var text: String?
        var permissions: Int?
        if let index = spec.arguments.firstIndex(of: "-c"), spec.arguments.indices.contains(index + 1) {
            let path = spec.arguments[index + 1]
            text = try? String(contentsOfFile: path, encoding: .utf8)
            permissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
        }
        configurationAtLaunch = text
        configurationPermissionsAtLaunch = permissions
    }

    public var output: AsyncStream<String> { stream.stream }

    public var hasExited: Bool { state.withLock { $0.exit != nil } }
    public var terminateCalls: Int { state.withLock { $0.terminateCalls } }
    public var killCalls: Int { state.withLock { $0.killCalls } }

    /// The helper prints a line.
    public func emit(_ line: String) {
        stream.continuation.yield(line)
    }

    /// The helper ends by itself (a crash).
    public func exit(_ exit: HelperExit = HelperExit(status: 2)) {
        let waiters = state.withLock { state -> [CheckedContinuation<HelperExit, Never>] in
            guard state.exit == nil else { return [] }
            state.exit = exit
            defer { state.waiters = [] }
            return state.waiters
        }
        stream.continuation.finish()
        for waiter in waiters { waiter.resume(returning: exit) }
    }

    public func waitUntilExit() async -> HelperExit {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> HelperExit? in
                if let exit = state.exit { return exit }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    public func terminate() {
        state.withLock { $0.terminateCalls += 1 }
        if endsOnTerminate { exit(HelperExit(status: 15, reason: .signaled)) }
    }

    public func kill() {
        state.withLock { $0.killCalls += 1 }
        exit(HelperExit(status: 9, reason: .signaled))
    }
}

/// A `HelperLaunching` for tests: nothing runs; every launch is a `FakeHelperProcess` the test controls.
public final class FakeHelperLauncher: HelperLaunching {
    private struct State {
        var processes: [FakeHelperProcess] = []
        var nextPID: Int32 = 40_000
        var staleCalls: [(pidFile: URL, executable: URL)] = []
    }

    private let state = Mutex(State())
    private let installed: Bool
    private let failLaunches: Box<Int>
    public let endsOnTerminate: Bool
    public let executable: URL

    /// `installed`: whether `locate` finds the program. `failingLaunches`: the first launches throw.
    public init(installed: Bool = true, endsOnTerminate: Bool = true, failingLaunches: Int = 0) {
        self.installed = installed
        self.endsOnTerminate = endsOnTerminate
        self.failLaunches = Box(failingLaunches)
        self.executable = URL(filePath: "/fake/Helpers/go2rtc")
    }

    public func locate(_ name: String) -> URL? {
        installed ? executable.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory) : nil
    }

    public func launch(_ spec: HelperLaunchSpec) throws -> any HelperProcess {
        let shouldFail = failLaunches.update { remaining -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if shouldFail { throw HelperLaunchError.launchFailed("scripted failure") }
        return state.withLock { state in
            state.nextPID += 1
            let process = FakeHelperProcess(spec: spec, processID: state.nextPID, endsOnTerminate: endsOnTerminate)
            state.processes.append(process)
            return process
        }
    }

    public func endStaleProcess(pidFile: URL, executable: URL) -> Bool {
        state.withLock { $0.staleCalls.append((pidFile, executable)) }
        return false
    }

    public var processes: [FakeHelperProcess] { state.withLock { $0.processes } }
    public var launchCount: Int { processes.count }
    public var staleCleanups: Int { state.withLock { $0.staleCalls.count } }
}
