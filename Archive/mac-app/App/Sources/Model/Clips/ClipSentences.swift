import BridgeEngine
import Foundation

/// One camera's plan for the selected range, with the name the person knows the camera by.
nonisolated struct PlannedClip: Sendable {
    var camera: UUID
    var name: String
    var plan: ClipPlan
}

/// A failed clip as an error that `AppModel.fail` can show: the alert's text is the sentence.
nonisolated struct ClipFailure: LocalizedError, Equatable {
    var sentence: String

    var errorDescription: String? { sentence }
}

/// The words of the clip flow: the notes under the clip bar, the label of the progress and the sentence of every failure. The box's web page says the
/// same ones; the apostrophes are straight on purpose, so the app and the page match to the character.
enum ClipSentences {
    static let underOneSecond = String(localized: "Move the end at least 1 second from the start.")
    static let nothingRecorded = String(localized: "Nothing was recorded in this time.")
    static let soundOmitted = String(localized: "Sound isn't included in clips yet.")

    /// Clips begin on a key picture, up to `leadIn` seconds (rounded up to whole seconds) before the chosen start.
    static func keyPicture(leadIn: TimeInterval) -> String {
        let seconds = max(1, Int(leadIn.rounded(.up)))
        return String(localized: "Starts up to \(seconds) s before your start: clips begin on a key picture.")
    }

    /// A gap of a few seconds that the clip bridges by holding the last picture.
    static func heldGap(_ gap: ClipGap, calendar: Calendar) -> String {
        let seconds = max(1, Int(gap.to.timeIntervalSince(gap.from).rounded()))
        let time = gap.from.formatted(date: .omitted, time: .standard, in: calendar)
        return String(localized: "The picture freezes for \(seconds) s at \(time): the camera had no recording.")
    }

    /// A longer gap that the clip jumps over.
    static func skippedGap(camera: String, gap: ClipGap, calendar: Calendar) -> String {
        let from = gap.from.formatted(date: .omitted, time: .standard, in: calendar)
        let to = gap.to.formatted(date: .omitted, time: .standard, in: calendar)
        return String(localized: "\(camera) has no recording from \(from) to \(to); the clip skips it.")
    }

    static func emptyCamera(_ name: String) -> String {
        String(localized: "\(name) had no recording in this time.")
    }

    static func tooLong(maxSeconds: Int) -> String {
        let hours = Double(maxSeconds) / 3_600
        let text = hours == hours.rounded() ? String(Int(hours)) : hours.formatted(.number.precision(.fractionLength(1)))
        return hours == 1 ? String(localized: "This clip is too long. The most is 1 hour per camera.")
                          : String(localized: "This clip is too long. The most is \(text) hours per camera.")
    }

    static func tooLarge(maxBytes: Int64) -> String {
        String(localized: "This clip is too big. The most is \(RecordingSettings.bytes(UInt64(clamping: maxBytes))) in all.")
    }

    static func notEnoughRoom(needed: Int64, free: Int64) -> String {
        let needed = RecordingSettings.bytes(UInt64(clamping: needed)), free = RecordingSettings.bytes(UInt64(clamping: max(0, free)))
        return String(localized: "There isn't enough room on that drive. The clips need about \(needed) and \(free) is free.")
    }

    /// "Saving 2 of 5: Driveway": `index` counts the files, from 1.
    static func saving(_ index: Int, of count: Int, camera: String) -> String {
        String(localized: "Saving \(index) of \(count): \(camera)")
    }

    // MARK: Failures

    /// A cancelled export is not a failure and says nothing; the caller checks this first.
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? ClipError) == .cancelled
    }

    /// The one sentence for a failed plan or export: the engine's `ClipError`, the file sink's `ClipFileError`, or (for anything else) the app's
    /// own wording for an error nobody mapped.
    static func sentence(for error: any Error, calendar: Calendar) -> String {
        switch error {
        case let error as ClipError: sentence(for: error, calendar: calendar)
        case let error as ClipFileError: error.errorDescription ?? ErrorText.unexpected
        default: ErrorText.describe(error)
        }
    }

    static func sentence(for error: ClipError, calendar: Calendar) -> String {
        switch error {
        case .nothingRecorded:
            nothingRecorded
        case .notReady:
            String(localized: "The recordings are still loading. Try again in a moment.")
        case .driveGone:
            String(localized: "The recordings drive went away, so this clip wasn't saved. Check that it is connected, then try again.")
        case .damaged(let date):
            String(localized: "A recording couldn't be read at \(date.formatted(date: .omitted, time: .standard, in: calendar)), so this clip wasn't saved.")
        case .tooLong(let maxSeconds):
            tooLong(maxSeconds: maxSeconds)
        case .tooLarge(let maxBytes):
            tooLarge(maxBytes: maxBytes)
        case .cancelled:
            String(localized: "The clip was cancelled.")
        case .sink(let text):
            text.isEmpty ? String(localized: "The clip couldn't be written to the destination.") : text
        }
    }

    // MARK: Notes

    /// What the clip bar says about the plans besides the size: the key-picture lead-in, sound, each camera's gaps (in time order, cameras in the order
    /// of `planned`), then the cameras with no recording. A sentence that two cameras share (the same hold at the same second) appears once.
    static func notes(planned: [PlannedClip], empty: [String], leadIn: TimeInterval, calendar: Calendar) -> [String] {
        var notes: [String] = []
        if leadIn > 0 { notes.append(keyPicture(leadIn: leadIn)) }
        if planned.contains(where: { $0.plan.soundOmitted }) { notes.append(soundOmitted) }
        for clip in planned {
            for gap in clip.plan.gaps.sorted(by: { $0.from < $1.from }) {
                notes.append(gap.held ? heldGap(gap, calendar: calendar) : skippedGap(camera: clip.name, gap: gap, calendar: calendar))
            }
        }
        notes += empty.map(emptyCamera)
        var seen = Set<String>()
        return notes.filter { seen.insert($0).inserted }
    }
}
