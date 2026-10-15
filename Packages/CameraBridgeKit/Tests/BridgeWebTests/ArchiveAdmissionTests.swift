import BridgeEngine
import BridgeSupport
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

/// The pieces every NVR route stands on (T00-contracts.md C.3, C.4, C.8): admission slots, the gates, the one error mapping, the caches, the folder
/// probe and the content security policy.
@Suite(.timeLimit(.minutes(1))) struct NVRAdmissionTests {
    @Test func aTotalOfTwentyFourAndSixteenPerAddressAreServedAtOnce() async throws {
        let rig = try await NVRRig.make()
        let app = rig.harness.app
        #expect((0..<16).allSatisfy { _ in app.takeArchiveSlot(address: "192.0.2.10") })
        #expect(!app.takeArchiveSlot(address: "192.0.2.10"), "the seventeenth from one address")
        #expect((0..<8).allSatisfy { _ in app.takeArchiveSlot(address: "192.0.2.11") })
        #expect(app.archiveSlotsInUse == 24)
        #expect(!app.takeArchiveSlot(address: "192.0.2.12"), "the twenty-fifth in all, whoever asks")
        app.releaseArchiveSlot(address: "192.0.2.10")
        #expect(app.takeArchiveSlot(address: "192.0.2.12") && app.archiveSlotsInUse == 24)
        for _ in 0..<20 { app.releaseArchiveSlot(address: "192.0.2.10"); app.releaseArchiveSlot(address: "192.0.2.11"); app.releaseArchiveSlot(address: "192.0.2.12") }
        #expect(app.archiveSlotsInUse == 0, "releasing more than was taken does not go negative")
        #expect(app.takeArchiveSlot(address: "192.0.2.10"))
    }

    @Test func theLimitsComeFromTheConfiguration() async throws {
        let rig = try await NVRRig.make { $0.maximumArchiveReads = 3; $0.maximumArchiveReadsPerAddress = 2 }
        let app = rig.harness.app
        #expect(app.takeArchiveSlot(address: "192.0.2.10") && app.takeArchiveSlot(address: "192.0.2.10") && !app.takeArchiveSlot(address: "192.0.2.10"))
        #expect(app.takeArchiveSlot(address: "192.0.2.11") && !app.takeArchiveSlot(address: "192.0.2.12"))
    }

    @Test func aRequestNeedsAnArchiveAndAReadyOne() async throws {
        let none = try await NVRRig.make(archive: nil)
        do {
            _ = try none.harness.app.readyArchive()
            Issue.record("a backend without an archive was accepted")
        } catch let error as APIError {
            #expect(error.status == 503 && error.code == "archive_unavailable" && error.headers.isEmpty, "no retry hint: it will not appear")
        }
        let archive = FakeArchiveReading()
        archive.setReady(false)
        let loading = try await NVRRig.make(archive: archive)
        do {
            _ = try loading.harness.app.readyArchive()
            Issue.record("an archive that is still loading was accepted")
        } catch let error as APIError {
            #expect(error.status == 503 && error.code == "archive_unavailable" && error.headers.contains { $0.0 == "Retry-After" && $0.1 == "2" })
        }
        archive.setReady(true)
        #expect(try loading.harness.app.readyArchive().isReady)
    }

    // MARK: Errors

    private struct Unlisted: Error {}

    @Test func everyArchiveFailureIsOneKindOfAnswerWithoutPathsOrFiles() {
        let secret = "/var/lib/camera-bridge/recordings/SECRET/2026-09-14/13-24-05.mp4"
        let cases: [(any Error, Int, String, String?)] = [
            (ArchiveError.fileGone, 410, "gone", nil),
            (ArchiveError.timedOut, 504, "drive_slow", "2"),
            (DeadlineExceeded(limit: .seconds(8)), 504, "drive_slow", "2"),
            (ArchiveError.unreadable(secret), 502, "unreadable", nil),
            (ArchiveError.noKeyframe, 502, "unreadable", nil),
            (ArchiveMedia.Failure.malformed(secret), 502, "unreadable", nil),
            (ArchiveMedia.Failure.unsupported(secret), 502, "unreadable", nil),
            (Unlisted(), 502, "unreadable", nil),
            (CancellationError(), 503, "archive_unavailable", "2"),
            (APIError.notFound("That doesn’t exist."), 404, "not_found", nil),
        ]
        for (error, status, code, retry) in cases {
            let mapped = WebApp.archiveAPIError(error)
            #expect(mapped.status == status && mapped.code == code, "\(error)")
            #expect(mapped.headers.first { $0.0 == "Retry-After" }?.1 == retry, "\(error)")
            #expect(!mapped.message.contains("SECRET") && !mapped.message.contains("/var"), "\(mapped.message)")
        }
    }

    // MARK: Small helpers

    @Test func timesAndFoldersAreWrittenTheWayTheRoutesCompareThem() {
        #expect(WebApp.milliseconds(Date(timeIntervalSince1970: 1_789_387_200.25)) == 1_789_387_200_250)
        #expect(WebApp.date(milliseconds: 1_789_387_200_250) == Date(timeIntervalSince1970: 1_789_387_200.25))
        #expect(WebApp.normalizedPath("/var/lib/recordings///") == "/var/lib/recordings" && WebApp.normalizedPath("/") == "/" && WebApp.normalizedPath("/a") == "/a")
        #expect(WebApp.earliestTime == 978_307_200_000 && WebApp.latestTime == 4_102_444_800_000)
    }

    @Test func theFileInformationCacheKeepsTheLastUsedTwoHundredAndFiftySix() {
        let cache = FileInfoCache()
        func info(_ segment: String) -> FileInfoCache.Info { FileInfoCache.Info(segment: segment, mime: "video/mp4", width: 640, height: 360, sound: false, anchor: 1) }
        for index in 0..<256 { cache.store(info("camera/2026-09-14/\(index)"), fileKey: "key\(index)") }
        #expect(cache.count == 256)
        #expect(cache.info(fileKey: "key0", segment: "camera/2026-09-14/0") != nil, "used again: no longer the oldest")
        cache.store(info("camera/2026-09-14/256"), fileKey: "key256")
        #expect(cache.count == 256)
        #expect(cache.info(fileKey: "key0", segment: "camera/2026-09-14/0") != nil && cache.info(fileKey: "key256", segment: "camera/2026-09-14/256") != nil)
        #expect(cache.info(fileKey: "key1", segment: "camera/2026-09-14/1") == nil, "the least recently used went")
        #expect(cache.info(fileKey: "key0", segment: "another/2026-09-14/0") == nil, "a key shared with another file's path serves nothing")
        #expect(cache.info(fileKey: "nope", segment: "x") == nil)
    }

    @Test func aFileIsReportedAsUnreadableOnlyTheFirstTime() {
        let state = ArchiveWebState()
        #expect(state.firstReport(of: "a1b2c3d4e5f6") && !state.firstReport(of: "a1b2c3d4e5f6") && state.firstReport(of: "ffffffffffff"))
        for index in 0..<300 { _ = state.firstReport(of: String(format: "%012x", index)) }
        #expect(state.firstReport(of: "a1b2c3d4e5f6"), "the memory is bounded: it starts again")
    }

    // MARK: The folder probe

    private func counting() -> (CountingBackend, FakeBackend) {
        let fake = FakeBackend()
        return (CountingBackend(fake), fake)
    }

    @Test func oneCheckRunsAtATimePerFolderAndTheChoosersAnswerIsReused() async throws {
        let (backend, _) = counting()
        let gate = AsyncGate()
        backend.folderGate.withLock { $0 = gate }
        let probe = ArchiveFolderProbe()
        let callers = (0..<5).map { _ in Task { await probe.inspect("/srv/recordings", using: backend, reusing: true) } }
        #expect(await eventually { gate.waiting == 1 })
        gate.open()
        var outcomes: [ArchiveFolderProbe.Outcome] = []
        for caller in callers { outcomes.append(await caller.value) }
        let report = ArchiveFolderReport(freeBytes: 200_000_000_000, totalBytes: 500_000_000_000)
        #expect(outcomes.allSatisfy { $0 == .usable(report) } && backend.folderChecks.withLock { $0 } == 1, "five callers, one check")
        #expect(await probe.inspect("/srv/recordings", using: backend, reusing: true) == .usable(report) && backend.folderChecks.withLock { $0 } == 1, "reused")
        _ = await probe.inspect("/srv/recordings", using: backend, reusing: false)
        #expect(backend.folderChecks.withLock { $0 } == 2, "a change of folder is checked afresh")
        _ = await probe.inspect("/mnt/other", using: backend, reusing: true)
        #expect(backend.folderChecks.withLock { $0 } == 3, "another folder is another check")
    }

    @Test func aCheckThatNeverReturnsIsAbandonedAtTheDeadlineAndNotRemembered() async throws {
        let (backend, _) = counting()
        let gate = AsyncGate()
        backend.folderGate.withLock { $0 = gate }
        let probe = ArchiveFolderProbe(deadline: .milliseconds(60), reuse: .seconds(10))
        let started = ContinuousClock.now
        #expect(await probe.inspect("/srv/recordings", using: backend, reusing: true) == .unresponsive)
        #expect(ContinuousClock.now - started < .seconds(3))
        gate.open()   // the drive comes back
        let again = await probe.inspect("/srv/recordings", using: backend, reusing: true)
        guard case .usable = again else {
            Issue.record("a hung drive that recovered was still reported as slow: \(again)")
            return
        }
        #expect(backend.folderChecks.withLock { $0 } == 2, "the timeout was not reused")
    }

    @Test func aRefusalCarriesTheEnginesSentence() async throws {
        let (backend, fake) = counting()
        fake.write { $0.folderReport = .failure(ArchiveFolderError.notAFolder) }
        let probe = ArchiveFolderProbe()
        #expect(await probe.inspect("/srv/recordings", using: backend, reusing: false) == .rejected("That isn’t a folder."))
        fake.write { $0.folderReport = .failure(Unlisted()) }
        #expect(await probe.inspect("/srv/recordings", using: backend, reusing: false) == .rejected(ErrorText.unexpected), "an error nobody worded reads as unexpected")
    }

    // MARK: Content security policy

    @Test func theContentSecurityPolicyChangesByExactlyOneDirective() async throws {
        let rig = try await NVRRig.make()
        let expectedPolicy = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; font-src 'self'; "
            + "manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        let wasBefore = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; manifest-src 'self'; base-uri 'none'; "
            + "form-action 'self'; frame-ancestors 'none'"
        #expect(expectedPolicy.replacingOccurrences(of: "media-src 'self' blob:; ", with: "") == wasBefore, "the only difference from the policy of the last release")
        let answers = [await rig.harness.send("GET", "/api/v1/status"), await rig.get("cameras"), await rig.harness.send("GET", "/"), await rig.get("nothing"),
                       await rig.harness.send("GET", "/api/v1/status", headers: [("Host", "evil.example")])]
        for answer in answers {
            let policy = try #require(answer.headers["Content-Security-Policy"])
            #expect(policy == expectedPolicy, "\(policy)")
            for forbidden in ["unsafe-inline", "unsafe-eval", "wasm", "worker-src", "frame-src", "child-src", "object-src", "http:", "https:", "*"] {
                #expect(!policy.contains(forbidden), "\(forbidden)")
            }
        }
    }
}
