import CameraAdapters
import Foundation
import HAPCamera
import MediaCore
import Testing
@testable import BridgeEngine

/// The per-camera "CameraBridge timestamp": its configuration (backward compatible), the passthrough rule it overrides
/// (`MediaFit`), and when a configuration change restarts the camera.
@Suite struct TimestampOverlayEngineTests {
    private func camera() -> CameraConfiguration {
        CameraConfiguration(name: "Porch", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "10.0.0.2"), username: "admin")
    }

    // MARK: Configuration

    @Test func defaultsAreOffTopRightAndMediumSized() {
        let settings = TimestampOverlaySettings()
        #expect(!settings.enabled)
        #expect(settings.position == .topRight)
        #expect(!settings.showCameraName && settings.showDate && settings.showSeconds)
        #expect(settings.size == .medium)
        #expect(settings.use24Hour == TimestampOverlayText.systemUses24Hour)
        #expect(camera().timestampOverlay == settings)
        #expect(camera().hiddenCameraClock == nil)
    }

    @Test func aConfigurationWrittenBeforeTheOverlayExistedLoadsWithDefaults() throws {
        // The keys of a camera saved by an earlier build: nothing about the overlay.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Porch","kind":"camera","vendor":"hikvision","endpoint":{"host":"10.0.0.2","httpPort":80,"rtspPort":554,"useHTTPS":false},
         "username":"admin","liveQualityMode":"originalQuality","preferredConfigMethod":"onvifFull"}
        """
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: Data(json.utf8))
        #expect(decoded.timestampOverlay == TimestampOverlaySettings())
        #expect(decoded.hiddenCameraClock == nil)
        #expect(decoded.liveQualityMode == .originalQuality && decoded.preferredConfigMethod == .onvifFull)   // the rest still reads
    }

    @Test func aPartialOverlayObjectKeepsWhatItHasAndDefaultsTheRest() throws {
        let json = Data(#"{"enabled":true,"position":"bottomLeft","size":"large"}"#.utf8)
        let decoded = try JSONDecoder().decode(TimestampOverlaySettings.self, from: json)
        #expect(decoded.enabled && decoded.position == .bottomLeft && decoded.size == .large)
        #expect(decoded.showDate && decoded.showSeconds && !decoded.showCameraName)
        #expect(decoded.use24Hour == TimestampOverlayText.systemUses24Hour)
    }

    @Test func aValueFromANewerBuildFallsBackForThatKeyOnly() throws {
        let json = Data(#"{"enabled":true,"position":"center","size":"large","showDate":false}"#.utf8)
        let decoded = try JSONDecoder().decode(TimestampOverlaySettings.self, from: json)
        #expect(decoded.enabled && decoded.size == .large && !decoded.showDate)
        #expect(decoded.position == .topRight, "an unknown position reads as the default")
    }

    @Test func settingsAndHiddenClockRoundTrip() throws {
        var config = camera()
        config.timestampOverlay = TimestampOverlaySettings(enabled: true, position: .bottomLeft, showCameraName: true, showDate: false, showSeconds: false,
                                                           use24Hour: true, size: .small)
        config.hiddenCameraClock = HiddenCameraClock(method: .onvifMinimal, removedOSDs: [.init(token: "OSD_1", children: "<tt:Type>Text</tt:Type>", how: .deleted)])
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    @Test func anUnreadableHiddenClockReadsAsNotHidden() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Porch","kind":"camera","vendor":"hikvision","endpoint":{"host":"10.0.0.2","httpPort":80,"rtspPort":554,"useHTTPS":false},
         "username":"admin","hiddenCameraClock":{"method":"somethingNewer"}}
        """
        #expect(try JSONDecoder().decode(CameraConfiguration.self, from: Data(json.utf8)).hiddenCameraClock == nil)
    }

    // MARK: MediaFit

    private static let source = RuntimeMediaFitTests.h264(1920, 1080)

    @Test func theOverlayForcesALiveTranscodeThatWouldOtherwisePassThrough() {
        let requested = RuntimeMediaFitTests.live(1920, 1080)
        #expect(MediaFit.live(source: Self.source, frameRate: 25, requested: requested) == .passthrough)
        #expect(MediaFit.live(source: Self.source, frameRate: 25, requested: requested, timestampOverlay: true) == .transcode(MediaFit.timestampOverlayReason))
        #expect(MediaFit.timestampOverlayReason == "timestamp overlay")
        // Original quality passes the camera's stream through untouched, until there is something to draw on it.
        #expect(MediaFit.live(source: Self.source, frameRate: 25, requested: RuntimeMediaFitTests.live(640, 360), qualityMode: .originalQuality) == .passthrough)
        #expect(MediaFit.live(source: Self.source, frameRate: 25, requested: RuntimeMediaFitTests.live(640, 360), qualityMode: .originalQuality,
                              timestampOverlay: true) == .transcode(MediaFit.timestampOverlayReason))
    }

    @Test func theOverlayForcesARecordingTranscodeThatWouldOtherwisePassThrough() {
        let configuration = RuntimeMediaFitTests.recording(1920, 1080)
        #expect(MediaFit.recording(source: Self.source, frameRate: 25, gop: .seconds(2), configuration: configuration) == .passthrough)
        #expect(MediaFit.recording(source: Self.source, frameRate: 25, gop: .seconds(2), configuration: configuration, timestampOverlay: true)
            == .transcode(MediaFit.timestampOverlayReason))
        #expect(MediaFit.recording(source: Self.source, frameRate: 25, gop: .seconds(2), configuration: configuration, qualityMode: .originalWhenPossible,
                                   timestampOverlay: true) == .transcode(MediaFit.timestampOverlayReason))
    }

    @Test func withoutTheOverlayNothingChanges() {
        let requested = RuntimeMediaFitTests.live(1280, 720)
        #expect(MediaFit.live(source: RuntimeMediaFitTests.h264(1280, 720), frameRate: 25, requested: requested, timestampOverlay: false) == .passthrough)
        #expect(MediaFit.liveEncoderSettings(for: requested, source: Self.source, sourceFrameRate: 25, qualityMode: .matchHomeKitRequest, timestampOverlay: false)
            == MediaFit.encoderSettings(for: requested, sourceFrameRate: 25))
    }

    @Test func originalQualityWithTheOverlayEncodesAtTheCamerasOwnSize() {
        let requested = RuntimeMediaFitTests.live(640, 360)
        let settings = MediaFit.liveEncoderSettings(for: requested, source: RuntimeMediaFitTests.h264(2560, 1440), sourceFrameRate: 24.6,
                                                    qualityMode: .originalQuality, timestampOverlay: true)
        #expect(settings.width == 2560 && settings.height == 1440 && settings.fps == 25)
        #expect(settings.bitrateKbps > requested.maxBitrateKbps && settings.bitrateKbps <= 12_000)
        #expect(settings.level == .auto)
        let recording = MediaFit.recordingEncoderSettings(for: RuntimeMediaFitTests.recording(1280, 720), source: Self.source, sourceFrameRate: 30,
                                                          qualityMode: .originalWhenPossible, timestampOverlay: true)
        #expect(recording.width == 1920 && recording.height == 1080 && recording.fps == 30)
        // Quality matched to the request: the requested size even with the overlay.
        let matched = MediaFit.recordingEncoderSettings(for: RuntimeMediaFitTests.recording(1280, 720), source: Self.source, sourceFrameRate: 30,
                                                        qualityMode: .matchHubRequest, timestampOverlay: true)
        #expect(matched.width == 1280 && matched.height == 720)
    }

    // MARK: Restarts

    @MainActor @Test func changingTheLookOfTheOverlayDoesNotRestartTheCamera() {
        let old = camera()
        var new = old
        new.timestampOverlay.position = .bottomLeft
        new.timestampOverlay.size = .large
        new.timestampOverlay.showCameraName = true
        new.timestampOverlay.use24Hour.toggle()
        #expect(!BridgeEngine.needsRestart(old, new, paired: true))
        var on = old
        on.timestampOverlay.enabled = true
        on.timestampOverlay.position = .bottomRight
        #expect(BridgeEngine.needsRestart(old, on, paired: true), "turning it on changes the video path")
        var off = on
        off.timestampOverlay.enabled = false
        #expect(BridgeEngine.needsRestart(on, off, paired: true))
    }

    @MainActor @Test func rememberingHowTheCamerasClockWasHiddenDoesNotRestartTheCamera() {
        let old = camera()
        var new = old
        new.hiddenCameraClock = HiddenCameraClock(method: .hikvisionISAPI, wasShown: true)
        #expect(!BridgeEngine.needsRestart(old, new, paired: true))
    }

    // MARK: The control the streams read

    @Test func theControlHandsStreamsTheCurrentSettingsOrNothingWhenOff() async {
        let hub = MediaHub()
        let control = TimestampOverlayControl(settings: TimestampOverlaySettings(enabled: false), cameraName: "Porch")
        let provider = control.provider(for: hub)
        #expect(provider.current == nil && !control.isEnabled)
        control.update(settings: TimestampOverlaySettings(enabled: true, position: .bottomLeft), cameraName: "Porch 2")
        let current = provider.current
        #expect(current?.settings.position == .bottomLeft && current?.cameraName == "Porch 2" && control.isEnabled)
    }
}
