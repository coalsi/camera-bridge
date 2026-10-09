import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

/// The real process layer with ordinary Unix programs standing in for ffmpeg.
@Suite(.serialized) struct ProcessLayerTests {
    private func spec(_ script: String, label: String = "test") -> FFmpegProcessSpec {
        FFmpegProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], label: label)
    }

    private func session(_ script: String, launcher: SystemFFmpegLauncher = SystemFFmpegLauncher(), maxBufferedOutput: Int = 64 << 20) throws -> FFmpegSession {
        try FFmpegSession(launcher: launcher, spec: spec(script), maxBufferedOutput: maxBufferedOutput)
    }

    /// This process's children that are zombies (ended and not reaped).
    private func zombieChildren(_ text: String) -> [String] { ChildProcesses.zombies(commandContaining: text) }

    @Test func stdinReachesTheChildAndItsStdoutComesBack() throws {
        let session = try session("cat")
        try session.send(Data("hello ".utf8))
        try session.send(Data("world".utf8))
        session.closeInput()
        let exit = try #require(session.waitForExit(timeout: .seconds(10)))
        #expect(exit.status == 0 && !exit.signaled)
        #expect(String(decoding: session.drain(), as: UTF8.self) == "hello world")
    }

    @Test func largeInputAndOutputFlowWithoutDeadlock() throws {
        let session = try session("cat")
        let block = Data(repeating: 0xAB, count: 1 << 20)
        for _ in 0..<12 { try session.send(block) }   // 12 MB through a pipe that holds 64 KB
        session.closeInput()
        var received = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            session.waitForOutput(timeout: .milliseconds(100))
            received += session.drain().count
            if received >= 12 << 20 { break }
        }
        #expect(received == 12 << 20)
        #expect(session.waitForExit(timeout: .seconds(10))?.status == 0)
    }

    @Test func theLastTwentyStderrLinesGoIntoTheError() throws {
        let session = try session("i=1; while [ $i -le 30 ]; do echo \"line $i\" >&2; i=$((i+1)); done; exit 7")
        let exit = try #require(session.waitForExit(timeout: .seconds(10)))
        #expect(exit.status == 7 && !exit.signaled)
        #expect(exit.stderrTail.count == 20)
        #expect(exit.stderrTail.first == "line 11" && exit.stderrTail.last == "line 30")
        let message = "\(session.failure)"
        #expect(message.contains("exited with status 7") && message.contains("line 30") && !message.contains("line 10 "))
        #expect(throws: MediaCodecError.self) { try session.send(Data([1])) }
    }

    @Test func aLongStderrLineIsCut() throws {
        let session = try session("head -c 5000 /dev/zero | tr '\\0' x >&2; echo >&2; exit 1")
        let exit = try #require(session.waitForExit(timeout: .seconds(10)))
        #expect(exit.stderrTail.allSatisfy { $0.count <= 400 })
        #expect(!exit.stderrTail.isEmpty)
    }

    // The scripts `exec` their last program: a shell that forks it would leave a grandchild holding the pipes, and Foundation on
    // Linux does not report a child's end until every holder of its pipes is gone.
    @Test func terminateEndsAChildThatNeverReadsItsInput() throws {
        let session = try session("exec sleep 60")
        #expect(session.exit == nil)
        let begun = ContinuousClock.now
        session.terminate()
        // terminate() itself never waits; the child goes away within the SIGTERM/SIGKILL window.
        #expect(ContinuousClock.now - begun < .milliseconds(200))
        let exit = session.waitForExit(timeout: .seconds(5))
        #expect(exit?.signaled == true)
    }

    @Test func aChildThatIgnoresSIGTERMIsKilled() throws {
        let session = try session("trap '' TERM; while true; do sleep 1; done")
        Thread.sleep(forTimeInterval: 0.3)   // let the shell install its trap
        session.terminate()
        let exit = session.waitForExit(timeout: .seconds(5))
        #expect(exit != nil, "SIGKILL must follow SIGTERM")
        #expect(exit?.signaled == true)
    }

    @Test func releasingTheSessionKillsTheChild() throws {
        var session: FFmpegSession? = try session("exec sleep 60")
        session = nil
        _ = session
        // The session's deinit terminated it; give the reaper a moment, then no zombie may be left.
        var zombies = ["pending"]
        for _ in 0..<50 {
            zombies = zombieChildren("sleep")
            if zombies.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(zombies.isEmpty, "zombies: \(zombies)")
    }

    @Test func manyShortChildrenLeaveNoZombies() throws {
        for index in 0..<20 {
            let session = try session("echo out; echo err >&2; exit \(index % 3)")
            _ = session.waitForExit(timeout: .seconds(10))
        }
        var zombies = ["pending"]
        for _ in 0..<50 {
            zombies = zombieChildren("sh")
            if zombies.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(zombies.isEmpty, "zombies: \(zombies)")
    }

    @Test func aChildThatDiesWhileWeWriteGivesTheFailureNotAPipeError() throws {
        let session = try session("echo 'fatal: cannot open input' >&2; exit 3")
        var failure: (any Error)?
        for _ in 0..<200 {
            do { try session.send(Data(repeating: 1, count: 1 << 16)) } catch { failure = error; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let error = try #require(failure as? MediaCodecError)
        #expect("\(error)".contains("status 3") && "\(error)".contains("cannot open input"))
    }

    @Test func inputThatTheChildDoesNotReadIsBoundedNotQueuedForever() throws {
        let launcher = SystemFFmpegLauncher(maxPendingInput: 1 << 20)
        let session = try session("exec sleep 30", launcher: launcher)
        defer { session.terminate() }
        var sent = 0
        var failure: (any Error)?
        for _ in 0..<200 {
            do {
                try session.send(Data(repeating: 1, count: 256 << 10))
                sent += 256 << 10
            } catch {
                failure = error
                break
            }
        }
        let error = try #require(failure as? MediaCodecError)
        #expect("\(error)".contains("not keeping up"), "\(error)")
        // The pipe's own buffer (64 KB) plus the 1 MB queue and a chunk in flight.
        #expect(sent <= 3 << 20, "accepted \(sent) bytes")
    }

    @Test func outputIsBufferedUpToTheLimitThenTheChildIsHeldBack() throws {
        let session = try session("head -c 20000000 /dev/zero", maxBufferedOutput: 1 << 20)
        defer { session.terminate() }
        Thread.sleep(forTimeInterval: 1.0)
        // Nothing drained: the reader stops at the limit (plus the chunk in its hand), the child blocks on its stdout.
        #expect(session.bufferedOutputBytes <= (1 << 20) + (256 << 10))
        #expect(session.exit == nil)
        var total = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while total < 20_000_000, ContinuousClock.now < deadline {
            session.waitForOutput(timeout: .milliseconds(50))
            total += session.drain().count
        }
        #expect(total == 20_000_000)
    }

    @Test func aProgramThatCannotBeStartedThrows() {
        let launcher = SystemFFmpegLauncher()
        #expect(throws: MediaCodecError.self) {
            _ = try FFmpegSession(launcher: launcher, spec: FFmpegProcessSpec(executable: URL(fileURLWithPath: "/nonexistent/ffmpeg"), arguments: [], label: "missing"))
        }
    }

    @Test func waitingForOutputTimesOut() throws {
        let session = try session("exec sleep 30")
        defer { session.terminate() }
        let begun = ContinuousClock.now
        #expect(session.waitForOutput(timeout: .milliseconds(150)) == false)
        #expect(ContinuousClock.now - begun < .seconds(2))
        #expect(session.waitForExit(timeout: .milliseconds(100)) == nil)
    }

    @Test func executableResolution() {
        let environment = ["PATH": "/opt/none:/opt/here", "CAMERABRIDGE_FFMPEG": ""]
        let configuration = FFmpegCodecsConfiguration()
        #expect(configuration.resolveExecutable(environment: environment, fileExists: { $0 == "/opt/here/ffmpeg" })?.path == "/opt/here/ffmpeg")
        #expect(configuration.resolveExecutable(environment: ["PATH": "", "CAMERABRIDGE_FFMPEG": "/custom/ffmpeg"], fileExists: { $0 == "/custom/ffmpeg" })?.path == "/custom/ffmpeg")
        #expect(configuration.resolveExecutable(environment: ["PATH": ""], fileExists: { $0 == "/usr/bin/ffmpeg" })?.path == "/usr/bin/ffmpeg")
        #expect(configuration.resolveExecutable(environment: ["PATH": ""], fileExists: { _ in false }) == nil)
        let explicit = FFmpegCodecsConfiguration(executable: URL(fileURLWithPath: "/x/ffmpeg"))
        #expect(explicit.resolveExecutable(environment: environment, fileExists: { $0 == "/opt/here/ffmpeg" }) == nil)
        #expect(explicit.resolveExecutable(environment: environment, fileExists: { $0 == "/x/ffmpeg" })?.path == "/x/ffmpeg")
    }

    @Test func listingsAndVersionsParse() {
        let names = FFmpegCapabilities.names(inListing: FakeListings.encoders)
        #expect(names == ["libx264", "h264_vaapi", "mjpeg", "aac", "libopus", "pcm_alaw"])
        let filters = FFmpegCapabilities.names(inListing: FakeListings.filters)
        #expect(filters == ["abench", "scale", "drawtext", "testsrc"])
        // The legend and heading lines are not names.
        #expect(!filters.contains("=") && !filters.contains("Filters:") && !filters.contains("Timeline"))
        #expect(FFmpegCapabilities.versionName(inBanner: "ffmpeg version 7.1.1-1+b1 Copyright (c) 2000-2025 the FFmpeg developers\nbuilt with gcc") == "7.1.1-1+b1")
        #expect(FFmpegCapabilities.versionName(inBanner: "") == "")
    }
}
