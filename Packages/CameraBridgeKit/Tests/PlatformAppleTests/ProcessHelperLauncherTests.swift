#if os(macOS)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import PlatformApple

/// The macOS helper launcher with small system programs: output, exit, environment, ending, and the leftover-process cleanup.
@Suite(.timeLimit(.minutes(1)), .serialized) struct ProcessHelperLauncherTests {
    private let launcher = ProcessHelperLauncher(searchDirectories: [URL(filePath: "/bin", directoryHint: .isDirectory),
                                                                      URL(filePath: "/usr/bin", directoryHint: .isDirectory)])

    private func collect(_ helper: any HelperProcess) async -> [String] {
        var lines: [String] = []
        for await line in helper.output { lines.append(line) }
        return lines
    }

    private func shell(_ script: String, environment: [String: String] = [:], pidFile: URL? = nil) throws -> any HelperProcess {
        try launcher.launch(HelperLaunchSpec(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script], environment: environment, pidFile: pidFile))
    }

    @Test func locateFindsOnlyExecutablesByPlainName() {
        #expect(launcher.locate("sh") == URL(filePath: "/bin/sh"))
        #expect(launcher.locate("env")?.path(percentEncoded: false) == "/usr/bin/env")
        #expect(launcher.locate("definitely-not-installed") == nil)
        #expect(launcher.locate("../bin/sh") == nil && launcher.locate("") == nil && launcher.locate("/bin/sh") == nil)
        #expect(ProcessHelperLauncher(searchDirectories: []).locate("sh") == nil)
    }

    @Test func outputIsDeliveredLineByLineWithStdoutAndStderrTogether() async throws {
        let helper = try shell("echo one; echo two 1>&2; printf 'no newline at the end'; exit 3")
        let lines = await collect(helper)
        #expect(lines == ["one", "two", "no newline at the end"])
        let exit = await helper.waitUntilExit()
        #expect(exit == HelperExit(status: 3, reason: .exited))
        #expect(await helper.waitUntilExit() == exit, "waiting again returns the same answer")
    }

    @Test func aLongLineIsClipped() async throws {
        let helper = try shell("head -c 5000 /dev/zero | tr '\\0' 'x'; echo")
        let lines = await collect(helper)
        #expect(lines.count == 1 && lines[0].count == HelperOutput.maximumLineLength + 1 && lines[0].hasSuffix("…"))
    }

    @Test func theHelperGetsOnlyWhatItIsGiven() async throws {
        setenv("CB_TEST_SECRET_LEAK", "leaked", 1)
        defer { unsetenv("CB_TEST_SECRET_LEAK") }
        let helper = try launcher.launch(HelperLaunchSpec(executable: URL(filePath: "/usr/bin/env"), environment: ["CB_GIVEN": "yes"]))
        let lines = await collect(helper)
        _ = await helper.waitUntilExit()
        #expect(lines.contains("CB_GIVEN=yes") && lines.contains { $0.hasPrefix("PATH=") })
        #expect(!lines.joined().contains("CB_TEST_SECRET_LEAK") && !lines.joined().contains("leaked"))
        #expect(!lines.contains { $0.hasPrefix("HOME=") || $0.hasPrefix("USER=") }, "\(lines)")
    }

    @Test func standardInputIsClosed() async throws {
        let helper = try shell("cat; echo cat-ended")
        #expect(await collect(helper) == ["cat-ended"])
    }

    @Test func terminateEndsAHelperWithSIGTERM() async throws {
        let helper = try launcher.launch(HelperLaunchSpec(executable: URL(filePath: "/bin/sleep"), arguments: ["30"]))
        #expect(helper.processID != nil)
        helper.terminate()
        let exit = await helper.waitUntilExit()
        #expect(exit == HelperExit(status: 15, reason: .signaled))
        helper.terminate()   // idempotent
        helper.kill()
    }

    @Test func killEndsAHelperThatIgnoresSIGTERM() async throws {
        let helper = try shell("trap '' TERM; while true; do sleep 0.1; done")
        try await Task.sleep(for: .milliseconds(300))
        helper.terminate()
        try await Task.sleep(for: .milliseconds(400))
        let stillRunning = !(await helperHasExited(helper))
        #expect(stillRunning, "SIGTERM was ignored")
        helper.kill()
        let exit = await helper.waitUntilExit()
        #expect(exit == HelperExit(status: 9, reason: .signaled))
    }

    @Test func aMissingProgramIsReportedWithoutItsPath() throws {
        do {
            _ = try launcher.launch(HelperLaunchSpec(executable: URL(filePath: "/nonexistent/secret-folder/go2rtc")))
            Issue.record("launched")
        } catch let error as HelperLaunchError {
            guard case .unavailable(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(!message.contains("secret-folder"))
        }
    }

    @Test func pidFileAndLeftoverCleanup() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let pidFile = directory.file("helper.pid")
        let helper = try launcher.launch(HelperLaunchSpec(executable: URL(filePath: "/bin/sleep"), arguments: ["30"], pidFile: pidFile))
        let written = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int32(written) == helper.processID)
        let attributes = try FileManager.default.attributesOfItem(atPath: pidFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        // A different program at that number is left alone (the number may belong to anything by now).
        let other = ProcessHelperLauncher(searchDirectories: [])
        #expect(!other.endStaleProcess(pidFile: pidFile, executable: URL(filePath: "/bin/sh")))
        #expect(!FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)), "the file is removed either way")
        #expect(!(await helperHasExited(helper)))

        // The same program: a helper left behind by a crashed app is ended.
        try Data("\(written)\n".utf8).write(to: pidFile)
        #expect(other.endStaleProcess(pidFile: pidFile, executable: URL(filePath: "/bin/sleep")))
        let exit = await helper.waitUntilExit()
        #expect(exit.reason == .signaled)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)))
    }

    @Test func leftoverCleanupIgnoresNonsense() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let other = ProcessHelperLauncher(searchDirectories: [])
        let pidFile = directory.file("x.pid")
        #expect(!other.endStaleProcess(pidFile: pidFile, executable: URL(filePath: "/bin/sleep")))   // no file
        for text in ["", "abc", "0", "1", "-5", "99999999999", "4999999"] {
            try Data(text.utf8).write(to: pidFile)
            #expect(!other.endStaleProcess(pidFile: pidFile, executable: URL(filePath: "/bin/sleep")), "\(text)")
            #expect(!FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)))
        }
    }

    /// Whether the helper ended within a moment. A deadline, not a task group: a group waits for `waitUntilExit`, which only returns
    /// when the process ends.
    private func helperHasExited(_ helper: any HelperProcess) async -> Bool {
        (try? await withDeadline(.milliseconds(150)) { await helper.waitUntilExit(); return true }) ?? false
    }
}
#endif
