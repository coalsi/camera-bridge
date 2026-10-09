// Loopback mock ONVIF camera (PlatformApple transport): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct CameraSettingsServiceTests {
    private let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)

    @Test func fetchSnapshotReadsDeviceProfilesAndImaging() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)

        let snapshot = try await service.fetchSnapshot()

        #expect(snapshot.supportsONVIF)
        #expect(snapshot.webPageURL != nil)
        #expect(snapshot.deviceInfo?.manufacturer.isEmpty == false)

        // Profile "000" (2560x1920) is the larger of the two video profiles → main; "001" (640x480) → sub.
        let main = try #require(snapshot.mainProfile)
        #expect(main.id == "000")
        #expect(main.settings.resolution == CameraResolution(width: 2560, height: 1920))
        #expect(main.settings.encoding == "H264")
        #expect(main.settings.bitrate == 3072)
        #expect(main.settings.iFrameInterval == 30)

        let sub = try #require(snapshot.subProfile)
        #expect(sub.id == "001")
        #expect(sub.settings.resolution == CameraResolution(width: 640, height: 480))

        let options = try #require(main.currentEncodingOptions)
        #expect(options.resolutions.contains(CameraResolution(width: 1920, height: 1080)))
        #expect(options.bitrateRange == 32...8192)
        #expect(options.h264ProfilesSupported.contains("High"))

        let imaging = try #require(snapshot.imaging)
        #expect(imaging.brightness == 55)
        #expect(imaging.irCutMode == .auto)
        #expect(imaging.wideDynamicRangeEnabled == false)

        let imagingOptions = try #require(snapshot.imagingOptions)
        #expect(imagingOptions.brightnessRange == 0...100)
        #expect(Set(imagingOptions.irCutModesSupported) == Set(CameraIRCutMode.allCases))
    }

    @Test func fetchSnapshotRecommendsHomeKitSettingsCorrectly() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)
        let snapshot = try await service.fetchSnapshot()

        // fps 15, GovLength 30 → 2 s I-frame interval, ~2x fps: recommended.
        #expect(snapshot.mainProfile?.settings.isRecommendedForHomeKit == true)

        var tooSparse = try #require(snapshot.mainProfile?.settings)
        tooSparse.iFrameInterval = 300   // 20 s at 15 fps
        #expect(tooSparse.isRecommendedForHomeKit == false)

        var wrongCodec = try #require(snapshot.mainProfile?.settings)
        wrongCodec.encoding = "JPEG"
        #expect(wrongCodec.isRecommendedForHomeKit == false)
    }

    @Test func applySetsVideoEncoderConfigurationOnTheRightToken() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)
        let snapshot = try await service.fetchSnapshot()
        var main = try #require(snapshot.mainProfile?.settings)
        main.bitrate = 4096
        main.resolution = CameraResolution(width: 1920, height: 1080)

        try await service.apply(CameraSettingsChange(mainEncoder: main))

        #expect(camera.setVideoEncoderConfigurationCalls.value == ["000"])
    }

    @Test func applySetsImagingSettingsOnTheVideoSource() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)
        var imaging = CameraImagingSettings()
        imaging.brightness = 70
        imaging.irCutMode = .on

        try await service.apply(CameraSettingsChange(imaging: imaging))

        #expect(camera.setImagingSettingsCalls.value == ["000"])
    }

    @Test func rebootCallsSystemReboot() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)

        try await service.reboot()

        #expect(camera.systemRebootCalled.value == 1)
    }

    @Test func rejectedCredentialsStillOfferTheWebPage() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.rejectCredentials.set(true)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)

        let snapshot = try await service.fetchSnapshot()

        #expect(!snapshot.supportsONVIF)
        #expect(snapshot.webPageURL != nil)
        #expect(snapshot.deviceInfo == nil)
    }

    @Test func noONVIFServiceStillOffersTheWebPage() async throws {
        // An endpoint nothing answers on (closed port): the service can't build a device service URL that
        // resolves to anything useful, but `webPageURL` is still derived from the endpoint alone.
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: 1, onvifPort: 1)
        let service = CameraSettingsService(endpoint: endpoint, credentials: credentials)

        let snapshot = try await service.fetchSnapshot()

        #expect(!snapshot.supportsONVIF)
        #expect(snapshot.webPageURL != nil)
    }
}
#endif
