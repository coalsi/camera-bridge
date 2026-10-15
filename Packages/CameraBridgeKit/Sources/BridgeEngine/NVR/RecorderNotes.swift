import Foundation

/// The lines under a camera's recording status that last (`CameraArchiveStatus.notes`). Texts are fixed so the status changes rarely.
enum RecorderNotes {
    static let soundFailed = ArchiveNote(id: .sound, text: "sound could not be recorded")
    static let soundCameraAudioOff = ArchiveNote(id: .sound, text: "no sound is recorded while Camera audio is off")
    static let soundMissing = ArchiveNote(id: .sound, text: "this camera sends no sound")

    static func keyframe(seconds: Int) -> ArchiveNote {
        ArchiveNote(id: .keyframe, text: "keyframe every \(seconds) s: scrubbing is slow")
    }
}

/// The measured time between keyframes, as a note. The note appears when the median of the last gaps exceeds 10 s, goes away at 8 s or less,
/// and its number follows the median only when it moved by 3 s or more, so a camera with a varying interval does not rewrite its status.
struct KeyframeIntervalNote: Sendable {
    static let showAbove: Double = 10
    static let hideAtOrBelow: Double = 8
    static let followStep: Double = 3
    static let gapsKept = 5
    static let gapsNeeded = 2

    private var lastKeyframe: Int64?
    private var gaps: [Double] = []
    private(set) var shown: Int?

    /// A keyframe with decode time `ticks` (90 kHz). Returns true when `note` changed.
    mutating func observe(keyframeAt ticks: Int64) -> Bool {
        defer { lastKeyframe = ticks }
        guard let last = lastKeyframe, ticks > last else { return false }
        gaps.append(Double(ticks - last) / 90_000)
        if gaps.count > Self.gapsKept { gaps.removeFirst(gaps.count - Self.gapsKept) }
        guard gaps.count >= Self.gapsNeeded else { return false }
        let sorted = gaps.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let before = shown
        if let current = shown {
            if median <= Self.hideAtOrBelow {
                shown = nil
            } else if abs(median - Double(current)) >= Self.followStep {
                shown = Int(median.rounded())
            }
        } else if median > Self.showAbove {
            shown = Int(median.rounded())
        }
        return shown != before
    }

    /// The timeline restarted (a reconnect): the next keyframe starts a new gap.
    mutating func restart() {
        lastKeyframe = nil
    }

    var note: ArchiveNote? { shown.map(RecorderNotes.keyframe(seconds:)) }
}
