import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct Go2RTCManagerTests {
    static let ringSecret = "RT-SECRET-4711"
    static let ring = try! Go2RTCSource(parsing: "ring:?camera_id=1&device_id=dev&refresh_token=\(ringSecret)")
    static let wyze = try! Go2RTCSource(parsing: "wyze://192.168.1.20?uid=WYZEUID1234567890AB&enr=ENR-SECRET&mac=AABBCCDDEEFF&model=HL_CAM4")

    /// Fast timing: restarts and health checks in milliseconds.
    static func timing(backoff: Backoff = Backoff(initial: .milliseconds(40), maximum: .milliseconds(160), jitter: 0)) -> Go2RTCManager.Timing {
        var timing = Go2RTCManager.Timing()
        timing.backoff = backoff
        timing.healthInterval = .milliseconds(10)
        timing.healthTimeout = .seconds(2)
        timing.attachTimeout = .seconds(3)
        timing.terminateGrace = .milliseconds(200)
        timing.settle = .milliseconds(20)
        timing.watchInterval = .milliseconds(10)
        timing.stableAfter = .seconds(30)
        return timing
    }

    static func ports(_ sequence: [UInt16] = [41_001, 41_002, 41_003, 41_004]) -> Go2RTCManager.PortPicker {
        let next = Box(0)
        return {
            next.update { index -> UInt16 in
                defer { index += 1 }
                return sequence[index % sequence.count]
            }
        }
    }

    struct Rig {
        let directory: TemporaryDirectory
        let launcher: FakeHelperLauncher
        let healthy: Box<Bool>
        let healthChecks: Box<[(UInt16, String?)]>
        let manager: Go2RTCManager
    }

    static func rig(launcher: FakeHelperLauncher = FakeHelperLauncher(), healthy: Bool = true, timing: Go2RTCManager.Timing = Go2RTCManagerTests.timing()) throws -> Rig {
        let directory = try TemporaryDirectory(prefix: "Go2RTCTests")
        let flag = Box(healthy)
        let checks = Box<[(UInt16, String?)]>([])
        let manager = Go2RTCManager(launcher: launcher, directory: directory.url.appending(path: "go2rtc", directoryHint: .isDirectory),
                                    pickPort: ports(), healthCheck: { port, password in
                                        checks.update { $0.append((port, password)) }
                                        return flag.value
                                    }, timing: timing)
        return Rig(directory: directory, launcher: launcher, healthy: flag, healthChecks: checks, manager: manager)
    }

    @Test func attachStartsTheHelperAndReturnsALoopbackAddress() async throws {
        let rig = try Self.rig()
        defer { rig.directory.remove() }
        let url = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        #expect(url.absoluteString == "rtsp://127.0.0.1:41002/cb-one")
        #expect(await rig.manager.isRunning)
        #expect(rig.launcher.launchCount == 1)
        let process = try #require(rig.launcher.processes.first)
        #expect(process.spec.executable.lastPathComponent == "go2rtc")
        #expect(process.spec.arguments.first == "-c")
        let yaml = try #require(process.configurationAtLaunch)
        #expect(yaml.contains("listen: \"127.0.0.1:41001\"") && yaml.contains("listen: \"127.0.0.1:41002\""))
        await rig.manager.stop()
    }

    @Test func noSecretIsOnDiskOrInTheCommandLineAndTheFileIsPrivate() async throws {
        let rig = try Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        _ = try await rig.manager.attach(streamID: "cb-two", source: Self.wyze)
        let process = try #require(rig.launcher.processes.last)
        let yaml = try #require(process.configurationAtLaunch)
        for secret in [Self.ringSecret, "ENR-SECRET", "refresh_token", "WYZEUID1234567890AB"] {
            #expect(!yaml.contains(secret))
            #expect(!process.spec.arguments.joined(separator: " ").contains(secret))
        }
        #expect(yaml.contains("'cb-one': '${CB_SRC_0}'") && yaml.contains("'cb-two': '${CB_SRC_1}'"))
        // The secrets travel in the environment, and the environment holds nothing else of ours.
        #expect(process.spec.environment["CB_SRC_0"] == Self.ring.url)
        #expect(process.spec.environment["CB_SRC_1"] == Self.wyze.url)
        #expect(process.spec.environment["CB_API_PASSWORD"]?.count == 64)
        #expect(Set(process.spec.environment.keys) == ["CB_SRC_0", "CB_SRC_1", "CB_API_PASSWORD"])
        #expect(process.configurationPermissionsAtLaunch == 0o600)
        // Whatever the helper's folder holds afterwards has no secret in it either, and the configuration is gone once it answers.
        let folder = rig.directory.url.appending(path: "go2rtc", directoryHint: .isDirectory)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        #expect(!files.contains("go2rtc.yaml"))
        for file in files {
            let text = (try? String(contentsOf: folder.appending(path: file), encoding: .utf8)) ?? ""
            for secret in [Self.ringSecret, "ENR-SECRET"] { #expect(!text.contains(secret)) }
        }
        await rig.manager.stop()
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "go2rtc.yaml").path(percentEncoded: false)))
    }

    @Test func theHealthCheckSendsTheRunsPasswordAndTheHelperGetsStaleCleanup() async throws {
        let rig = try Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        let process = try #require(rig.launcher.processes.first)
        let checks = rig.healthChecks.value
        #expect(!checks.isEmpty && checks.allSatisfy { $0.0 == 41_001 && $0.1 == process.spec.environment["CB_API_PASSWORD"] })
        #expect(rig.launcher.staleCleanups == 1)
        #expect(process.spec.pidFile?.lastPathComponent == "go2rtc.pid")
        await rig.manager.stop()
    }

    @Test func aCrashedHelperRestartsWithGrowingBackoff() async throws {
        let rig = try Self.rig(timing: Self.timing(backoff: Backoff(initial: .milliseconds(100), maximum: .milliseconds(400), jitter: 0)))
        defer { rig.directory.remove() }
        _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        // Crashing again and again (never for a stable run) waits 100, 200, 400 and then 400 ms (the maximum) before each restart.
        let expected: [Duration] = [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(400)]
        for (round, minimum) in expected.enumerated() {
            let began = ContinuousClock.now
            try #require(rig.launcher.processes.last).exit()
            #expect(await eventually(timeout: .seconds(5)) { rig.launcher.launchCount == round + 2 })
            let gap = ContinuousClock.now - began
            #expect(gap >= minimum - .milliseconds(20), "round \(round + 1): \(gap)")
            #expect(gap < minimum + .milliseconds(1_500), "round \(round + 1): \(gap)")
        }
        #expect(await eventually { await rig.manager.isRunning })
        await rig.manager.stop()
        #expect(rig.launcher.processes.allSatisfy { $0.hasExited })
    }

    @Test func backoffStartsOverAfterAStableRun() async throws {
        var timing = Self.timing(backoff: Backoff(initial: .milliseconds(150), maximum: .seconds(5), jitter: 0))
        timing.stableAfter = .milliseconds(100)
        let rig = try Self.rig(timing: timing)
        defer { rig.directory.remove() }
        _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        for round in 1...3 {
            try await Task.sleep(for: .milliseconds(150))   // the run was stable
            let began = ContinuousClock.now
            try #require(rig.launcher.processes.last).exit()
            #expect(await eventually(timeout: .seconds(5)) { rig.launcher.launchCount == round + 1 })
            #expect(ContinuousClock.now - began < .milliseconds(1_000))   // 150 ms, not 150 · 2^n
        }
        await rig.manager.stop()
    }

    @Test func aHelperThatNeverAnswersFailsTheAttachWithItsReason() async throws {
        var timing = Self.timing()
        timing.healthTimeout = .milliseconds(150)
        timing.attachTimeout = .milliseconds(600)
        let rig = try Self.rig(healthy: false, timing: timing)
        defer { rig.directory.remove() }
        await #expect(throws: Go2RTCError.self) {
            _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        }
        #expect(rig.launcher.launchCount >= 1)
        await rig.manager.stop()
        #expect(rig.launcher.processes.allSatisfy { $0.hasExited })
    }

    @Test func aHelperThatDiesAtStartIsRetriedAndTheAttachFailsWhenItCannotRecover() async throws {
        var timing = Self.timing()
        timing.attachTimeout = .milliseconds(500)
        let launcher = FakeHelperLauncher(failingLaunches: 1000)
        let rig = try Self.rig(launcher: launcher, timing: timing)
        defer { rig.directory.remove() }
        do {
            _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
            Issue.record("attached")
        } catch let error as Go2RTCError {
            guard case .notReady(let reason) = error else { Issue.record("wrong error \(error)"); return }
            #expect(reason.contains("could not be started"))
        }
        await rig.manager.stop()
    }

    @Test func aMissingProgramIsReportedAtOnce() async throws {
        let rig = try Self.rig(launcher: FakeHelperLauncher(installed: false))
        defer { rig.directory.remove() }
        await #expect(throws: Go2RTCError.helperMissing) { _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring) }
        #expect(rig.manager.isInstalled == false)
        #expect(rig.launcher.launchCount == 0)
        let installed = try Self.rig()
        defer { installed.directory.remove() }
        await #expect(throws: Go2RTCError.invalidStreamName) { _ = try await installed.manager.attach(streamID: "bad name", source: Self.ring) }
    }

    @Test func changingTheStreamsRestartsTheHelperOnceAndKeepsThePorts() async throws {
        let rig = try Self.rig()
        defer { rig.directory.remove() }
        let first = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        let second = try await rig.manager.attach(streamID: "cb-two", source: Self.wyze)
        #expect(first.port == second.port)
        #expect(rig.launcher.launchCount == 2)
        #expect(rig.launcher.processes[0].hasExited && !rig.launcher.processes[1].hasExited)
        let yaml = try #require(rig.launcher.processes[1].configurationAtLaunch)
        #expect(yaml.contains("'cb-one'") && yaml.contains("'cb-two'"))
        // The same source again changes nothing.
        _ = try await rig.manager.attach(streamID: "cb-two", source: Self.wyze)
        #expect(rig.launcher.launchCount == 2)
        await rig.manager.stop()
    }

    @Test func detachingTheLastStreamEndsTheHelper() async throws {
        let rig = try Self.rig()
        defer { rig.directory.remove() }
        _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        _ = try await rig.manager.attach(streamID: "cb-two", source: Self.wyze)
        await rig.manager.detach(streamID: "cb-one")
        #expect(await eventually { rig.launcher.launchCount == 3 })
        #expect(await eventually { await rig.manager.isRunning })
        await rig.manager.detach(streamID: "cb-two")
        #expect(await eventually { rig.launcher.processes.allSatisfy { $0.hasExited } })
        #expect(await eventually { await !rig.manager.isRunning })
        // A new camera starts it again.
        _ = try await rig.manager.attach(streamID: "cb-three", source: Self.ring)
        #expect(await rig.manager.isRunning)
        await rig.manager.stop()
    }

    @Test func aHelperThatIgnoresSIGTERMIsKilled() async throws {
        let rig = try Self.rig(launcher: FakeHelperLauncher(endsOnTerminate: false))
        defer { rig.directory.remove() }
        _ = try await rig.manager.attach(streamID: "cb-one", source: Self.ring)
        await rig.manager.stop()
        let process = try #require(rig.launcher.processes.first)
        #expect(process.terminateCalls == 1 && process.killCalls == 1 && process.hasExited)
    }

    @Test func outputIsKeptPerStreamWithSecretsMasked() async throws {
        let rig = try Self.rig()
        defer { rig.directory.remove() }
        let id = UUID()
        let name = Go2RTCManager.streamName(for: id)
        _ = try await rig.manager.attach(streamID: name, source: Self.ring)
        let process = try #require(rig.launcher.processes.first)
        process.emit("ERR [streams] error=\"ring: authentication failed\" stream=\(name) url=ring:?camera_id=1&device_id=dev&refresh_token=\(Self.ringSecret)")
        process.emit("WRN [api] something general enr=ENR-SECRET")
        process.emit("INF [rtsp] listen addr=127.0.0.1:41002")
        #expect(await eventually { await !rig.manager.problems(streamID: name).isEmpty })
        let problems = await rig.manager.problems(streamID: name)
        #expect(problems.count == 1 && problems[0].contains("authentication failed"))
        #expect(!problems.joined().contains(Self.ringSecret))
        #expect(await eventually { await !rig.manager.generalProblems.isEmpty })
        let general = await rig.manager.generalProblems
        #expect(!general.joined().contains("ENR-SECRET") && general[0].contains("enr=***"))
        await rig.manager.stop()
    }

    @Test func sanitizingMasksStreamKeysAndSecretsButKeepsTheMessage() {
        let masked = Go2RTCManager.sanitized("ERR [streams] error=\"rtspx://192.168.1.1:7441/ABCDEF123 refused\" password=hunter2 refresh_token=xyz uid=U123 mac=AABB")
        #expect(!masked.contains("ABCDEF123") && !masked.contains("hunter2") && !masked.contains("xyz") && !masked.contains("U123"))
        #expect(masked.contains("refused") && masked.contains("192.168.1.1:7441"))
        #expect(Go2RTCManager.level(of: "ERR boom").0 == .error)
        #expect(Go2RTCManager.level(of: "WRN x").0 == .warning && Go2RTCManager.level(of: "DBG x").0 == .debug)
        #expect(Go2RTCManager.level(of: "something else").1 == "something else")
        #expect(Go2RTCManager.streamName(in: "error=x stream=cb-1234 url=y") == "cb-1234")
    }

    @Test func theSignInPageIsASeparateLoopbackHelperWithoutRTSPOrAPassword() async throws {
        let rig = try Self.rig()
        defer { rig.directory.remove() }
        let url = try await rig.manager.beginSetupSession()
        #expect(url.absoluteString == "http://127.0.0.1:41001/add.html")
        let process = try #require(rig.launcher.processes.first)
        let yaml = try #require(process.configurationAtLaunch)
        #expect(yaml.contains("listen: \"127.0.0.1:41001\"") && !yaml.contains("rtsp:") && !yaml.contains("password"))
        #expect(yaml.contains("/api/ring") && !yaml.contains("exec"))
        #expect(process.spec.environment.isEmpty)
        #expect(await rig.manager.hasSetupSession)
        // It does not touch the serving helper, and ending it removes its folder.
        #expect(await !rig.manager.isRunning)
        let folder = URL(filePath: process.spec.arguments[1]).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        await rig.manager.endSetupSession()
        #expect(process.hasExited && process.terminateCalls == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(await !rig.manager.hasSetupSession)
    }

    @Test func theSignInPageEndsWithTheManagerAndAfterItsLifetime() async throws {
        var timing = Self.timing()
        timing.setupLifetime = .milliseconds(150)
        let rig = try Self.rig(timing: timing)
        defer { rig.directory.remove() }
        _ = try await rig.manager.beginSetupSession()
        #expect(await eventually { await !rig.manager.hasSetupSession })
        #expect(rig.launcher.processes.first?.hasExited == true)
        _ = try await rig.manager.beginSetupSession()
        await rig.manager.stop()
        #expect(rig.launcher.processes.allSatisfy { $0.hasExited })
    }

    @Test func missingProgramHasNoSignInPage() async throws {
        let rig = try Self.rig(launcher: FakeHelperLauncher(installed: false))
        defer { rig.directory.remove() }
        await #expect(throws: Go2RTCError.helperMissing) { _ = try await rig.manager.beginSetupSession() }
    }
}
