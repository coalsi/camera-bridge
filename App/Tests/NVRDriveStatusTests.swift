import BridgeEngine
import Foundation
import Testing

/// The real archive answers nothing to its lookups while the recordings drive is away (measured with a pulled drive: `extent` and `fragment` are nil, only the
/// read of a fragment that was known throws), which a cell cannot tell from the end of the recordings. The engine's status can (`ArchivePause.folderMissing`);
/// the panel passes it to the session (`recheckDrive(driveMissing:)`), and the cells ask it before they call a silent archive a gap.
@MainActor @Suite(.timeLimit(.minutes(2))) struct NVRDriveStatusTests {
    @Test func aDriveThatTheArchiveCannotSeeHoldsTheClockWhenTheEngineSaysTheFolderIsMissing() async {
        let h = SessionHarness(cameraCount: 2, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(8.0))
        h.session.endScrub()
        await h.until(advancing: false) { h.sink(0).displayed.count >= 2 && h.sink(1).displayed.count >= 2 }
        h.time.advance(by: 1.0)
        #expect(h.clock.isPlaying)
        h.archive.setUnreachable(true)                                        // the drive is pulled: every lookup answers nothing
        h.session.recheckDrive(driveBack: false, driveMissing: true)          // the engine's status says the folder is missing
        await h.until { h.session.driveHold != nil }                          // the cells run out of what they read and find nothing more
        guard let held = h.session.driveHold?.position else {
            Issue.record("the session did not hold for the drive")
            h.session.stopAll()
            return
        }
        #expect(h.clock.state.mode == .paused && !h.clock.isLive, "the clock stands still; it did not go live")
        #expect(h.session.cells.allSatisfy { $0.coverage == .driveMissing && $0.playback.hasPicture }, "the pictures stay and the cells say why")
        h.time.advance(by: 30)
        #expect(h.clock.position() == held, "and the clock stays however long the drive is gone")

        h.archive.setUnreachable(false)                                       // the drive is plugged in again
        h.session.recheckDrive(driveBack: true, driveMissing: false)          // the engine says recording works: the cells ask at once
        await h.until { h.clock.isPlaying }
        #expect(h.clock.isPlaying && h.session.driveHold == nil, "playing goes on")
        #expect(abs(h.clock.position().timeIntervalSince(held)) < 1.0, "from where it stopped")
        h.session.stopAll()
    }

    @Test func withoutTheEnginesWordAnArchiveThatAnswersNothingStillMeansTheEndOfTheRecordings() async {
        let h = SessionHarness(cameraCount: 1, withLive: false)
        h.session.setCameras(h.cameras)
        h.session.beginScrub()
        h.session.scrub(to: h.date(8.0))
        h.session.endScrub()
        await h.until(advancing: false) { h.sink(0).displayed.count >= 2 }
        h.time.advance(by: 1.0)
        h.archive.setUnreachable(true)                                        // nothing more to read, and the engine does not say the drive is missing
        h.session.recheckDrive(driveBack: false, driveMissing: false)
        await h.until { h.clock.isLive }
        #expect(h.clock.isLive && h.session.driveHold == nil, "the end of the recordings: the viewer goes live")
        h.session.stopAll()
    }
}
