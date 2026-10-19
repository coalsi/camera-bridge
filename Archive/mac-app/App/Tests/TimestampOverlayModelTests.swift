import BridgeEngine
import CameraAdapters
import CoreGraphics
import Foundation
import MediaCore
import PlatformApple
import Testing

/// The camera page's timestamp section: the preview is drawn by the encoder's own renderer, edits merge into the draft
/// like the other camera settings, and the "hide the camera's own clock" wording.
@Suite(.timeLimit(.minutes(1))) struct TimestampOverlayModelTests {
    private let moment = Date(timeIntervalSince1970: 1_790_970_135)
    private let us = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func picture(width: Int = 1280, height: Int = 720) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.45, green: 0.55, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    // MARK: Preview

    @Test func thePreviewIsTheEncodersRendererOnTheSnapshot() throws {
        let settings = TimestampOverlaySettings(enabled: true, position: .bottomRight, showCameraName: true, showDate: true, showSeconds: true,
                                                use24Hour: false, size: .medium)
        let snapshot = picture()
        let preview = try #require(TimestampOverlayModel.preview(snapshot: snapshot, settings: settings, cameraName: "Porch", at: moment, locale: us, timeZone: utc))
        // The same call the transcoder's overlay path makes in PlatformApple.
        let direct = try #require(TimestampOverlayPreview.render(image: snapshot, overlay: TimestampOverlay(settings: settings, cameraName: "Porch", clock: FixedOverlayClock(moment)),
                                                                 at: moment, outputHeight: TimestampOverlayModel.previewHeight, locale: us, timeZone: utc))
        #expect(preview.width == 1280 && preview.height == TimestampOverlayModel.previewHeight)
        #expect(rgba(preview) == rgba(direct), "pixel for pixel the renderer's output")
        #expect(rgba(preview) != rgba(snapshot), "and it differs from the plain snapshot: the overlay is drawn")
    }

    @Test func thePreviewFollowsEveryChoice() throws {
        var settings = TimestampOverlaySettings(enabled: true, position: .topLeft, showCameraName: false, showDate: true, showSeconds: true, use24Hour: false, size: .small)
        let base = try #require(TimestampOverlayModel.preview(snapshot: picture(), settings: settings, cameraName: "Porch", at: moment, locale: us, timeZone: utc))
        func changed(_ edit: (inout TimestampOverlaySettings) -> Void) throws -> Bool {
            var other = settings
            edit(&other)
            let image = try #require(TimestampOverlayModel.preview(snapshot: picture(), settings: other, cameraName: "Porch", at: moment, locale: us, timeZone: utc))
            return rgba(image) != rgba(base)
        }
        #expect(try changed { $0.position = .bottomRight })
        #expect(try changed { $0.size = .large })
        #expect(try changed { $0.showDate = false })
        #expect(try changed { $0.showSeconds = false })
        #expect(try changed { $0.use24Hour = true })
        #expect(try changed { $0.showCameraName = true })
        // Other camera name text, same settings with the name off: the same picture.
        settings.showCameraName = false
        let renamed = try #require(TimestampOverlayModel.preview(snapshot: picture(), settings: settings, cameraName: "Gate", at: moment, locale: us, timeZone: utc))
        #expect(rgba(renamed) == rgba(base))
    }

    @Test func theTimeAdvancesWithTheClock() throws {
        let settings = TimestampOverlaySettings(enabled: true, showDate: false, showSeconds: true)
        let a = try #require(TimestampOverlayModel.preview(snapshot: picture(), settings: settings, cameraName: "", at: moment, locale: us, timeZone: utc))
        let b = try #require(TimestampOverlayModel.preview(snapshot: picture(), settings: settings, cameraName: "", at: moment.addingTimeInterval(1), locale: us, timeZone: utc))
        #expect(rgba(a) != rgba(b))
    }

    @Test func theNextRedrawIsAtTheNextWholeSecond() {
        let whole = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(abs(TimestampOverlayModel.secondsUntilNextSecond(from: whole) - 1.02) < 0.001)
        #expect(abs(TimestampOverlayModel.secondsUntilNextSecond(from: whole.addingTimeInterval(0.75)) - 0.27) < 0.001)
    }

    // MARK: Editing

    @Test func overlayEditsMergeLikeOtherSettings() {
        let base = CameraEditorTests.sample
        var edited = base
        edited.timestampOverlay.position = .bottomLeft
        edited.timestampOverlay.enabled = true
        var latest = base
        latest.name = "Driveway (new)"
        latest.hiddenCameraClock = HiddenCameraClock(method: .hikvisionISAPI, wasShown: true)
        let merged = CameraEditor.merge(base: base, edited: edited, latest: latest)
        #expect(merged.timestampOverlay.position == .bottomLeft && merged.timestampOverlay.enabled, "the edit is kept")
        #expect(merged.name == "Driveway (new)" && merged.hiddenCameraClock?.method == .hikvisionISAPI, "what the form does not edit follows the engine")
    }

    // MARK: Wording

    @Test func hiddenClockWording() {
        #expect(TimestampOverlayModel.hiddenDescription(HiddenCameraClock(method: .hikvisionISAPI, wasShown: true)).contains("ISAPI"))
        #expect(TimestampOverlayModel.hiddenDescription(HiddenCameraClock(method: .reolinkAPI, wasShown: false)).contains("already off"))
        #expect(TimestampOverlayModel.hiddenDescription(HiddenCameraClock(method: .onvifFull)).contains("ONVIF"))
    }

    @Test func changeResultWording() {
        let done = CameraClockChange(succeeded: true, method: .reolinkAPI)
        #expect(TimestampOverlayModel.describe(done, hiding: true).contains("Reolink API"))
        #expect(TimestampOverlayModel.describe(done, hiding: false) == "Shown again.")
        let unsupported = CameraClockChange(succeeded: false, method: nil, failures: [CameraConfigAttempt(method: .onvifMinimal, failure: .unsupported("no OSD"))])
        #expect(TimestampOverlayModel.describe(unsupported, hiding: true) == "Not supported by this camera.")
        let refused = CameraClockChange(succeeded: false, method: nil, failures: [CameraConfigAttempt(method: .onvifMinimal, failure: .unauthorized)])
        #expect(TimestampOverlayModel.describe(refused, hiding: true).contains("login rejected"))
    }
}
