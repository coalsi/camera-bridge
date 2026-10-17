#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

/// Which ONVIF profile is the camera's main and which its sub stream (`CameraSettingsService.streamProfiles`): the one whose stream address
/// (`GetStreamUri`) is the configured main or sub URL. Dahua and Amcrest addresses differ only in their query (`subtype=0` main,
/// `subtype=1` sub), so comparing paths alone took every profile for the main stream and Optimize / "Set up for Camera Bridge" changed the
/// sub stream's encoder as if it were the main one.
@Suite(.timeLimit(.minutes(1))) struct StreamProfileMatchTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func dahuaMainAndSubAreDifferentStreams() {
        let main = url("rtsp://192.0.2.20:554/cam/realmonitor?channel=1&subtype=0")
        let sub = url("rtsp://192.0.2.20:554/cam/realmonitor?channel=1&subtype=1")
        #expect(!CameraSettingsService.sameStream(main, sub))
        #expect(CameraSettingsService.sameStream(url("rtsp://192.0.2.20/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif"), main),
                "the camera's own address adds parameters the configured one does not name")
        #expect(CameraSettingsService.sameStream(url("rtsp://192.0.2.20/cam/realmonitor?subtype=1&channel=1"), sub), "in any order")
        #expect(CameraSettingsService.sameStream(url("rtsp://192.0.2.20/CAM/RealMonitor?Channel=1&SubType=1"), sub), "in any case")
        #expect(!CameraSettingsService.sameStream(url("rtsp://192.0.2.20/cam/realmonitor?channel=2&subtype=0"), main), "another channel")
    }

    @Test func aMissingSubtypeIsTheMainStream() {
        let bare = url("rtsp://192.0.2.20:554/cam/realmonitor?channel=1")
        #expect(CameraSettingsService.sameStream(bare, url("rtsp://192.0.2.20/cam/realmonitor?channel=1&subtype=0&unicast=true")))
        #expect(!CameraSettingsService.sameStream(bare, url("rtsp://192.0.2.20/cam/realmonitor?channel=1&subtype=1&unicast=true")))
    }

    @Test func addressesThatDifferInThePathMatchAsBefore() {
        // Hikvision and Reolink: the path names the stream; the camera's own address adds a query.
        #expect(CameraSettingsService.sameStream(url("rtsp://192.0.2.21/Streaming/Channels/101?transportmode=unicast&profile=Profile_1"),
                                                 url("rtsp://192.0.2.21:554/Streaming/Channels/101")))
        #expect(!CameraSettingsService.sameStream(url("rtsp://192.0.2.21/Streaming/Channels/102"), url("rtsp://192.0.2.21/Streaming/Channels/101")))
        #expect(CameraSettingsService.sameStream(url("rtsp://admin:pw@192.0.2.22:554/Preview_01_main"), url("rtsp://192.0.2.22/preview_01_main")))
        #expect(!CameraSettingsService.sameStream(url("rtsp://192.0.2.22/"), url("rtsp://192.0.2.22/")), "an empty path names nothing")
    }

    @Test func anAmcrestListingItsMainProfileFirstGetsTheRightProfiles() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.mainProfileFirst.set(true)
        camera.streamURIs.set([
            "000": "rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif",
            "001": "rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=1&unicast=true&proto=Onvif",
        ])
        let service = CameraSettingsService(endpoint: camera.endpoint,
                                            credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                            mainStreamURL: url("rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0"),
                                            subStreamURL: url("rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=1"))
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.mainProfile?.id == "000")
        #expect(snapshot.subProfile?.id == "001")
    }
}
#endif
