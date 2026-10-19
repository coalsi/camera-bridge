import MediaCore
import Synchronization

/// One camera's "Straighten the picture" correction as the running streams see it, changed in place when the person edits it (never a
/// restart: that would close the camera's NVR file). Live view and recording hand it to every transcoder they make, which asks `current`
/// at every picture (nil costs nothing). Off everywhere while the codecs cannot apply one (`MediaCodecs.supportsPictureCorrection`): the
/// correction then never shows in one place and not in another.
final class PictureCorrectionControl: PictureCorrectionProviding {
    private let correction: Mutex<PictureCorrection>
    private let supported: Bool

    init(_ correction: PictureCorrection, supported: Bool) {
        self.correction = Mutex(correction)
        self.supported = supported
    }

    /// Whether that turned the correction on or off (`isOn` changed; never while unsupported). A new value while it stays on is false.
    @discardableResult
    func update(_ correction: PictureCorrection) -> Bool {
        let switched = self.correction.withLock { value -> Bool in
            defer { value = correction }
            return value.isOff != correction.isOff
        }
        return supported && switched
    }

    /// Whether pictures are straightened: video must then be transcoded (`MediaFit`).
    var isOn: Bool { current != nil }

    /// The correction to apply; nil when it is off or the codecs cannot apply one.
    var current: PictureCorrection? {
        guard supported else { return nil }
        let value = correction.withLock { $0 }
        return value.isOff ? nil : value
    }
}
