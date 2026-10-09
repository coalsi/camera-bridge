// Loopback mock ISAPI camera (PlatformApple transport): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct HikvisionSmartCodecTests {
    private let credentials = HTTPCredentials(username: "admin", password: "pa55")

    // MARK: Pure string read-modify-write (no network): the optimizer's edit must not disturb the rest of the document.

    @Test func togglingSmartCodecOffLeavesEverythingElseUnchanged() throws {
        let document = MockHikvisionCamera.channelDocument(id: "101", smartCodecEnabled: true)
        let edited = try #require(HikvisionISAPI.replacingSmartCodecEnabled(in: document, enabled: false))
        #expect(edited.contains("<enabled>false</enabled>"))
        #expect(!edited.contains("<enabled>true</enabled>"))
        #expect(edited.contains("<videoResolutionWidth>1920</videoResolutionWidth>"))
        #expect(edited.contains("<channelName>Camera 1</channelName>"))
    }

    @Test func togglingSmartCodecOnFlipsFalseToTrue() throws {
        let document = MockHikvisionCamera.channelDocument(id: "101", smartCodecEnabled: false)
        let edited = try #require(HikvisionISAPI.replacingSmartCodecEnabled(in: document, enabled: true))
        #expect(edited.contains("<enabled>true</enabled>"))
    }

    @Test func noSmartCodecElementIsLeftUntouched() {
        let document = "<StreamingChannel><id>101</id><Video><videoCodecType>H.264</videoCodecType></Video></StreamingChannel>"
        #expect(HikvisionISAPI.replacingSmartCodecEnabled(in: document, enabled: false) == nil)
    }

    // MARK: Loopback ISAPI: CameraSettingsService.hikvisionSmartCodecEnabled / setHikvisionSmartCodec.

    @Test func readsSmartCodecStateFromTheChannelDocument() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)

        let enabled = try await service.hikvisionSmartCodecEnabled(channelID: "101")

        #expect(enabled == true)
    }

    @Test func disablingSmartCodecPUTsTheWholeDocumentBackWithOnlyEnabledChanged() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)

        try await service.setHikvisionSmartCodec(enabled: false, channelID: "101")

        #expect(camera.putChannelDocuments.value.map(\.id) == ["101"])
        let body = camera.putChannelDocuments.value[0].body
        #expect(body.contains("<enabled>false</enabled>"))
        #expect(body.contains("<videoResolutionWidth>1920</videoResolutionWidth>"))

        // Reading it back confirms the stored document was actually replaced (read-modify-write, not a no-op).
        let enabled = try await service.hikvisionSmartCodecEnabled(channelID: "101")
        #expect(enabled == false)
    }

    @Test func enablingAndDisablingBothMainAndSubChannelsAreIndependent() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)

        try await service.setHikvisionSmartCodec(enabled: false, channelID: "101")
        try await service.setHikvisionSmartCodec(enabled: false, channelID: "102")

        #expect(try await service.hikvisionSmartCodecEnabled(channelID: "101") == false)
        #expect(try await service.hikvisionSmartCodecEnabled(channelID: "102") == false)
        #expect(camera.putChannelDocuments.value.map(\.id) == ["101", "102"])
    }

    @Test func aChannelWithNoSmartCodecElementReportsNilAndSkipsThePUT() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        camera.channelDocuments.update { $0["103"] = "<StreamingChannel><id>103</id><Video><videoCodecType>H.264</videoCodecType></Video></StreamingChannel>" }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials)

        let enabled = try await service.hikvisionSmartCodecEnabled(channelID: "103")
        try await service.setHikvisionSmartCodec(enabled: false, channelID: "103")

        #expect(enabled == nil)
        #expect(camera.putChannelDocuments.value.isEmpty)
    }

    // MARK: CameraDrivers.hikvisionChannelID — the same numbering rule the optimizer and the driver both use.

    @Test func channelIDDefaultsToCameraOneWithoutAnExplicitNVRChannel() {
        #expect(CameraDrivers.hikvisionChannelID(mainStreamURL: nil, sub: false) == "101")
        #expect(CameraDrivers.hikvisionChannelID(mainStreamURL: nil, sub: true) == "102")
    }

    @Test func channelIDFollowsAnExplicitNVRChannelInTheURL() {
        let url = URL(string: "rtsp://10.0.0.5:554/ISAPI/Streaming/channels/402")!
        #expect(CameraDrivers.hikvisionChannelID(mainStreamURL: url, sub: false) == "401")
        #expect(CameraDrivers.hikvisionChannelID(mainStreamURL: url, sub: true) == "402")
    }
}
#endif
