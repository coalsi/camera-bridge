import CameraAdapters
import Foundation
import HAP
import HAPCamera
import MediaCore
import Testing
@testable import BridgeEngine

/// HAP options derived from the probed source (plan W3-1 item 2, integration brief §5.1): recording resolutions are frozen
/// per camera; live resolutions follow the source.
@Suite struct RuntimeAccessoryOptionsTests {
    @Test func recordingResolutionsAreSixteenByNineOrAlsoFourByThree() {
        #expect(AccessoryOptions.recordingResolutions(aspect: .wide) == [VideoResolution(1280, 720, 30), VideoResolution(1920, 1080, 30)])
        #expect(AccessoryOptions.recordingResolutions(aspect: .standard)
                == [VideoResolution(1280, 720, 30), VideoResolution(1920, 1080, 30), VideoResolution(1280, 960, 30), VideoResolution(1600, 1200, 30)])
        #expect(AccessoryOptions.Aspect(width: 1920, height: 1080) == .wide)
        #expect(AccessoryOptions.Aspect(width: 2688, height: 1520) == .wide)
        #expect(AccessoryOptions.Aspect(width: 2560, height: 1920) == .standard)
        #expect(AccessoryOptions.Aspect(width: 1280, height: 1024) == .standard)
        #expect(AccessoryOptions.Aspect(width: 0, height: 0) == nil)
    }

    @Test func recordingResolutionsGainTheSourcesNativeClassWhenItIsLargeEnough() {
        #expect(!AccessoryOptions.recordingResolutions(aspect: .wide, sourceWidth: 1920, sourceHeight: 1080)
                    .contains(VideoResolution(2560, 1440, 30)))
        let uhd = AccessoryOptions.recordingResolutions(aspect: .wide, sourceWidth: 3840, sourceHeight: 2160)
        #expect(uhd.contains(VideoResolution(3840, 2160, 30)) && uhd.contains(VideoResolution(2560, 1440, 30)))
        let fourByThree = AccessoryOptions.recordingResolutions(aspect: .standard, sourceWidth: 2048, sourceHeight: 1536)
        #expect(fourByThree.contains(VideoResolution(2048, 1536, 30)))
        #expect(!AccessoryOptions.recordingResolutions(aspect: .standard, sourceWidth: 1600, sourceHeight: 1200)
                    .contains(VideoResolution(2048, 1536, 30)))
    }

    @Test func liveResolutionsFollowTheSource() {
        let hd = AccessoryOptions.streamingResolutions(sourceWidth: 1920, sourceHeight: 1080)
        #expect(hd.first == VideoResolution(1920, 1080, 30))
        #expect(hd.contains(VideoResolution(1280, 720, 30)) && hd.contains(VideoResolution(640, 360, 30)))
        #expect(hd.contains(VideoResolution(320, 240, 15)), "Apple Watch")
        #expect(!hd.contains(VideoResolution(3840, 2160, 30)) && !hd.contains(VideoResolution(1600, 1200, 30)))
        let uhd = AccessoryOptions.streamingResolutions(sourceWidth: 3840, sourceHeight: 2160)
        #expect(uhd.first == VideoResolution(3840, 2160, 30) && uhd.contains(VideoResolution(2560, 1440, 30)))
        let qhd = AccessoryOptions.streamingResolutions(sourceWidth: 2560, sourceHeight: 1440)
        #expect(qhd.first == VideoResolution(2560, 1440, 30))
        let fourByThree = AccessoryOptions.streamingResolutions(sourceWidth: 2048, sourceHeight: 1536)
        #expect(fourByThree.contains(VideoResolution(1600, 1200, 30)) && fourByThree.contains(VideoResolution(640, 480, 30)))
        #expect(fourByThree.contains(VideoResolution(1920, 1080, 30)))
        // Unknown source: up to 1080p.
        #expect(AccessoryOptions.streamingResolutions(sourceWidth: nil, sourceHeight: nil) == hd)
        // No duplicates, largest first.
        #expect(Set(fourByThree).count == fourByThree.count)
    }

    @Test func frozenOptionsRoundTripThroughTheHAPState() throws {
        let store = InMemoryHAPStore()
        #expect(try AccessoryOptions.frozenAspect(in: store) == nil)
        var state = HAPPersistentState()
        state.extras["other"] = Data([1])
        try store.saveState(state)
        #expect(try AccessoryOptions.frozenAspect(in: store) == nil)
        state.extras[AccessoryOptions.frozenKey] = try AccessoryOptions.encodeFrozen(.standard)
        try store.saveState(state)
        #expect(try AccessoryOptions.frozenAspect(in: store) == .standard)
        state.extras[AccessoryOptions.frozenKey] = Data("garbage".utf8)
        try store.saveState(state)
        #expect(try AccessoryOptions.frozenAspect(in: store) == nil)
    }

    @Test func rememberedPictureSizeRoundTripsThroughTheHAPState() throws {
        let store = InMemoryHAPStore()
        #expect(AccessoryOptions.sourceSize(in: store) == nil)
        var state = HAPPersistentState()
        state.extras[AccessoryOptions.sourceSizeKey] = try AccessoryOptions.encode(AccessoryOptions.SourceSize(width: 2560, height: 1920))
        try store.saveState(state)
        let size = try #require(AccessoryOptions.sourceSize(in: store))
        #expect(size == AccessoryOptions.SourceSize(width: 2560, height: 1920) && size.aspect == .standard)
        // Its live options are the source's (4:3 sizes, 1440p) even before the stream delivers a picture.
        let live = AccessoryOptions.streamingResolutions(sourceWidth: size.width, sourceHeight: size.height)
        #expect(live.first == VideoResolution(2560, 1440, 30) && live.contains(VideoResolution(1600, 1200, 30)))
        for bad in [Data("garbage".utf8), try AccessoryOptions.encode(AccessoryOptions.SourceSize(width: 0, height: 1080)),
                    try AccessoryOptions.encode(AccessoryOptions.SourceSize(width: 1920, height: 100_000))] {
            state.extras[AccessoryOptions.sourceSizeKey] = bad
            try store.saveState(state)
            #expect(AccessoryOptions.sourceSize(in: store) == nil)
        }
    }

    @Test func controllerConfigurationPerCamera() {
        var camera = CameraConfiguration(name: "Front Door", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: "192.0.2.1"), username: "u")
        camera.twoWayAudio = true
        let doorbell = AccessoryOptions.controllerConfiguration(for: camera, aspect: .wide, sourceWidth: 2560, sourceHeight: 1920, talkback: true)
        #expect(doorbell.isDoorbell && doorbell.streamCount == 2 && doorbell.streaming.twoWayAudio)
        #expect(doorbell.recording?.resolutions == AccessoryOptions.recordingResolutions(aspect: .wide, sourceWidth: 2560, sourceHeight: 1920))
        #expect(doorbell.recording?.resolutions.contains(VideoResolution(2560, 1440, 30)) == true, "the native 1920-tall source adds its own class")
        #expect(doorbell.recording?.prebufferLengthMs == 4000 && doorbell.recording?.fragmentLengthMs == 4000)
        #expect(doorbell.recording?.audioSampleRates == [.khz32] && doorbell.recording?.audioChannels == 1)
        #expect(doorbell.streaming.profiles == [.main] && doorbell.streaming.cryptoSuites == [.aesCm128HmacSha1_80])
        #expect(doorbell.streaming.audioCodecs.map(\.codec) == [.opus])
        // Two-way audio needs both the setting and a camera that can play audio.
        let noSink = AccessoryOptions.controllerConfiguration(for: camera, aspect: .wide, sourceWidth: nil, sourceHeight: nil, talkback: false)
        #expect(!noSink.streaming.twoWayAudio)
        camera.twoWayAudio = false
        camera.kind = .camera
        let plain = AccessoryOptions.controllerConfiguration(for: camera, aspect: .standard, sourceWidth: nil, sourceHeight: nil, talkback: true)
        #expect(!plain.isDoorbell && !plain.streaming.twoWayAudio && plain.recording?.resolutions.count == 4)
    }

    @Test func accessoryInformationHasFallbacks() {
        var camera = CameraConfiguration(name: "Garage  / Cam", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.9"), username: "")
        let info = AccessoryOptions.accessoryInfo(for: camera)
        #expect(info.name == "Garage Cam")
        #expect(info.manufacturer == "ONVIF" && info.model == "ONVIF Camera" && !info.serialNumber.isEmpty && info.firmwareRevision == "1.0")
        camera.manufacturer = "Amcrest"
        camera.model = "IP5M"
        camera.serialNumber = "ABC"
        camera.firmware = "V2.800.00AC000.0.R, build 2023"
        let named = AccessoryOptions.accessoryInfo(for: camera)
        #expect(named.manufacturer == "Amcrest" && named.model == "IP5M" && named.serialNumber == "ABC")
        #expect(named.firmwareRevision == "2.800.0", "HAP wants x[.y[.z]] numbers")
        camera.name = "***"
        #expect(AccessoryOptions.accessoryInfo(for: camera).name == "Camera")
    }
}
