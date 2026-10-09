import BridgeSupport
import Foundation
import Synchronization

/// One run of the go2rtc helper: the launched process, its output pump and the facts about how it ended. The manager owns
/// the policy (when to start, restart and stop); this class is the mechanics, shared by the serving helper and the sign-in
/// page's helper.
final class Go2RTCRun: Sendable {
    /// What `Go2RTCRun.start` needs.
    struct Plan: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var pidFile: URL?
        var workingDirectory: URL?
    }

    private struct State {
        var exit: HelperExit?
        var terminating = false
    }

    private final class Box: Sendable {
        let state = Mutex(State())
    }

    private let process: any HelperProcess
    private let box = Box()
    private let pump: Task<Void, Never>
    private let watcher: Task<Void, Never>
    /// Single use: `.exited` is yielded when the process ends.
    let exits: AsyncStream<HelperExit>

    var processID: Int32? { process.processID }

    var exit: HelperExit? { box.state.withLock { $0.exit } }

    /// Launches `plan`. `onLine` gets each output line (the manager sanitizes and logs it).
    init(launcher: any HelperLaunching, plan: Plan, onLine: @escaping @Sendable (String) -> Void) throws {
        let spec = HelperLaunchSpec(executable: plan.executable, arguments: plan.arguments, environment: plan.environment,
                                    workingDirectory: plan.workingDirectory, pidFile: plan.pidFile)
        let process = try launcher.launch(spec)
        self.process = process
        let (stream, continuation) = AsyncStream<HelperExit>.makeStream(bufferingPolicy: .bufferingNewest(1))
        exits = stream
        let output = process.output
        pump = Task {
            for await line in output { onLine(line) }
        }
        let box = box
        watcher = Task {
            let exit = await process.waitUntilExit()
            box.state.withLock { $0.exit = exit }
            continuation.yield(exit)
            continuation.finish()
        }
    }

    /// Ends the process: SIGTERM, then SIGKILL after `grace`. Returns once it ended (at most `grace` + 1 s).
    func terminate(grace: Duration) async {
        guard exit == nil else { return await finish() }
        box.state.withLock { $0.terminating = true }
        process.terminate()
        if await waitForExit(up: grace) == false {
            process.kill()
            _ = await waitForExit(up: .seconds(1))
        }
        await finish()
    }

    var isTerminating: Bool { box.state.withLock { $0.terminating } }

    /// Polls for the exit, at most `limit` (a bounded wait: no unbounded loops).
    private func waitForExit(up limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if exit != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return exit != nil
    }

    /// Lets the output pump drain what the process wrote last (bounded).
    private func finish() async {
        _ = try? await withDeadline(.seconds(1), followsCancellation: false) { [pump] in await pump.value }
    }
}
