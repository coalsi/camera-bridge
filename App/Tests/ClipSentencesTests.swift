import BridgeEngine
import Foundation
import Testing

@Suite struct ClipSentencesTests {
    /// 24-hour times, so the expected sentences have no narrow no-break space in them.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    /// 2026-10-12 12:00:00 UTC.
    private let origin = Date(timeIntervalSince1970: 1_791_806_400)

    private func plan(camera: UUID = UUID(), name: String = "Driveway", gaps: [ClipGap] = [], sound: Bool = false) -> PlannedClip {
        let request = ClipRequest(camera: camera, cameraName: name, start: origin, end: origin.addingTimeInterval(600), timeZone: .gmt)
        let part = ClipPart(index: 1, count: 1, start: origin, end: request.end, leadIn: 0, byteCount: 1_000, sampleCount: 10, fileName: "\(name).mp4")
        return PlannedClip(camera: camera, name: name, plan: ClipPlan(request: request, parts: [part], gaps: gaps, soundOmitted: sound))
    }

    // MARK: The sentences of the README's table

    @Test func theFixedSentencesAreTheOnesOfThePage() {
        #expect(ClipSentences.underOneSecond == "Move the end at least 1 second from the start.")
        #expect(ClipSentences.nothingRecorded == "Nothing was recorded in this time.")
        #expect(ClipSentences.soundOmitted == "Sound isn't included in clips yet.")
        #expect(ClipSentences.emptyCamera("Backyard") == "Backyard had no recording in this time.")
        #expect(ClipSentences.saving(2, of: 5, camera: "Driveway") == "Saving 2 of 5: Driveway")
    }

    @Test func theKeyPictureNoteRoundsUpSoItNeverUnderstates() {
        #expect(ClipSentences.keyPicture(leadIn: 1.35) == "Starts up to 2 s before your start: clips begin on a key picture.")
        #expect(ClipSentences.keyPicture(leadIn: 4) == "Starts up to 4 s before your start: clips begin on a key picture.")
        #expect(ClipSentences.keyPicture(leadIn: 0.2) == "Starts up to 1 s before your start: clips begin on a key picture.")
    }

    @Test func aHeldGapAndASkippedGapSayWhereTheyAre() {
        let held = ClipGap(from: origin.addingTimeInterval(30), to: origin.addingTimeInterval(32), held: true)
        #expect(ClipSentences.heldGap(held, calendar: calendar) == "The picture freezes for 2 s at 12:00:30: the camera had no recording.")
        let skipped = ClipGap(from: origin.addingTimeInterval(600), to: origin.addingTimeInterval(612), held: false)
        #expect(ClipSentences.skippedGap(camera: "Patio", gap: skipped, calendar: calendar) == "Patio has no recording from 12:10:00 to 12:10:12; the clip skips it.")
        let short = ClipGap(from: origin, to: origin.addingTimeInterval(1.2), held: true)
        #expect(ClipSentences.heldGap(short, calendar: calendar).contains("freezes for 1 s at 12:00:00"))
    }

    @Test func theLimitsSayTheirNumbers() {
        #expect(ClipSentences.tooLong(maxSeconds: 7_200) == "This clip is too long. The most is 2 hours per camera.")
        #expect(ClipSentences.tooLong(maxSeconds: 3_600) == "This clip is too long. The most is 1 hour per camera.")
        #expect(ClipSentences.tooLong(maxSeconds: 5_400) == "This clip is too long. The most is 1.5 hours per camera.")
        #expect(ClipSentences.tooLarge(maxBytes: 20 << 30) == "This clip is too big. The most is \(RecordingSettings.bytes(20 << 30)) in all.")
        #expect(ClipSentences.notEnoughRoom(needed: 3_000_000_000, free: 2_000_000_000)
                == "There isn't enough room on that drive. The clips need about \(RecordingSettings.bytes(3_000_000_000)) and \(RecordingSettings.bytes(2_000_000_000)) is free.")
    }

    // MARK: Errors

    @Test func everyEngineErrorHasASentence() {
        let when = origin.addingTimeInterval(200)
        let expected: [(ClipError, String)] = [
            (.nothingRecorded, "Nothing was recorded in this time."),
            (.notReady, "The recordings are still loading. Try again in a moment."),
            (.driveGone, "The recordings drive went away, so this clip wasn't saved. Check that it is connected, then try again."),
            (.damaged(at: when), "A recording couldn't be read at 12:03:20, so this clip wasn't saved."),
            (.tooLong(maxSeconds: 7_200), "This clip is too long. The most is 2 hours per camera."),
            (.sink("The destination refused."), "The destination refused."),
            (.sink(""), "The clip couldn't be written to the destination."),
        ]
        for (error, sentence) in expected {
            #expect(ClipSentences.sentence(for: error, calendar: calendar) == sentence, "\(error)")
        }
        #expect(ClipSentences.sentence(for: ClipError.tooLarge(maxBytes: 20 << 30), calendar: calendar) == ClipSentences.tooLarge(maxBytes: 20 << 30))
    }

    @Test func theFileSinksSentenceCrossesTheEnginesWrapperUntouched() {
        let full = ClipFileError(reason: .noRoom)
        #expect(ClipSentences.sentence(for: full, calendar: calendar) == "There isn't enough room on the destination drive.")
        #expect(ClipSentences.sentence(for: ClipError.sink(String(describing: full)), calendar: calendar) == "There isn't enough room on the destination drive.",
                "an engine that wraps the error as text")
        #expect(ClipSentences.sentence(for: ClipError.sink(full.localizedDescription), calendar: calendar) == "There isn't enough room on the destination drive.")
    }

    @Test func anErrorNobodyMappedReadsAsTheAppsOwnWording() {
        struct Unmapped: Error {}
        #expect(ClipSentences.sentence(for: Unmapped(), calendar: calendar) == ErrorText.unexpected)
    }

    @Test func aFailureCanBeShownByTheAppsAlert() {
        #expect(ErrorText.describe(ClipFailure(sentence: "Nothing was recorded in this time.")) == "Nothing was recorded in this time.")
        #expect(ClipFailure(sentence: "a").errorDescription == "a" && ClipFailure(sentence: "a") == ClipFailure(sentence: "a"))
    }

    @Test func aCancellationIsNotAFailure() {
        #expect(ClipSentences.isCancellation(CancellationError()) && ClipSentences.isCancellation(ClipError.cancelled))
        #expect(!ClipSentences.isCancellation(ClipError.driveGone) && !ClipSentences.isCancellation(ClipFileError(reason: .noRoom)))
    }

    // MARK: Notes

    @Test func notesFollowTheOrderOfTheTableAndNameEachGap() {
        let held = ClipGap(from: origin.addingTimeInterval(30), to: origin.addingTimeInterval(32), held: true)
        let skipped = ClipGap(from: origin.addingTimeInterval(300), to: origin.addingTimeInterval(312), held: false)
        let driveway = plan(name: "Driveway", gaps: [skipped, held], sound: true)   // handed over out of order
        let notes = ClipSentences.notes(planned: [driveway, plan(name: "Patio", gaps: [skipped])], empty: ["Backyard"], leadIn: 1.35, calendar: calendar)
        #expect(notes == [
            "Starts up to 2 s before your start: clips begin on a key picture.",
            "Sound isn't included in clips yet.",
            "The picture freezes for 2 s at 12:00:30: the camera had no recording.",
            "Driveway has no recording from 12:05:00 to 12:05:12; the clip skips it.",
            "Patio has no recording from 12:05:00 to 12:05:12; the clip skips it.",
            "Backyard had no recording in this time.",
        ])
    }

    @Test func aSentenceTwoCamerasShareAppearsOnce() {
        let held = ClipGap(from: origin.addingTimeInterval(30), to: origin.addingTimeInterval(32), held: true)
        let notes = ClipSentences.notes(planned: [plan(name: "Driveway", gaps: [held], sound: true), plan(name: "Patio", gaps: [held], sound: true)], empty: [],
                                        leadIn: 0, calendar: calendar)
        #expect(notes == ["Sound isn't included in clips yet.", "The picture freezes for 2 s at 12:00:30: the camera had no recording."],
                "no key-picture note without a lead-in; the shared sentences once")
        #expect(ClipSentences.notes(planned: [plan()], empty: [], leadIn: 0, calendar: calendar).isEmpty, "a plain clip has nothing to say")
    }
}
