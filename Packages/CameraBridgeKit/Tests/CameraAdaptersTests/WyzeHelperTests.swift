import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

/// The pieces around the Wyze helper programs: the Gwell credential signature, the helpers' status lines, the go2rtc stream they push into.
@Suite struct WyzeHelperTests {
    @Test func hmacMD5MatchesRFC2202() {
        #expect(WyzeCloud.hmacMD5Hex(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8)) == "750c783e6ab0b503eaa86e310a5db738")
        #expect(WyzeCloud.hmacMD5Hex(key: [UInt8](repeating: 0x0b, count: 16), message: Array("Hi There".utf8)) == "9294727a3638bb1c13f48ef8158bfc9d")
        #expect(WyzeCloud.hmacMD5Hex(key: [UInt8](repeating: 0xaa, count: 80),
                                     message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8)) == "6b1ab7fe4bd7bf8f0b62e6ce61b9d0cd")
    }

    @Test func statusLinesAreReadAsFields() {
        let fields = WyzeHelperSupervisor.fields(of: #"cb-lake event=session_end reason="agora gateway closed" code=1"#)
        #expect(fields["event"] == "session_end" && fields["reason"] == "agora gateway closed" && fields["code"] == "1")
        #expect(WyzeHelperSupervisor.fields(of: "cb-gwell event=first_video codec=h264")["event"] == "first_video")
        // Go's logger puts the date and time first.
        let dated = WyzeHelperSupervisor.statusLine("2026/10/16 03:24:01.123456 cb-lake event=first_video", prefix: "cb-")
        #expect(dated == "cb-lake event=first_video" && WyzeHelperSupervisor.statusLine("no status here", prefix: "cb-") == nil)
    }

    @Test func aPublishedStreamHasNoSourceInTheConfiguration() {
        #expect(Go2RTCSource.published.isPublished && Go2RTCSource.published.description == "publish:")
        let config = Go2RTCConfig(apiPort: 1984, rtspPort: 8554, streams: [Go2RTCConfig.Stream(name: "cb-a", variable: nil),
                                                                            Go2RTCConfig.Stream(name: "cb-b", variable: "CB_SRC_1")])
        #expect(config.yaml.contains("  'cb-a': []\n"))
        #expect(config.yaml.contains("  'cb-b': '${CB_SRC_1}'\n"))
    }

    @Test func aPadMoveBecomesOneNudgeInTheStrongerDirection() {
        #expect(WyzeLakePanTilt.nudge(pan: 0.6, tilt: 0)! == ("right", 12))
        #expect(WyzeLakePanTilt.nudge(pan: -1, tilt: 0.2)! == ("left", 20))
        #expect(WyzeLakePanTilt.nudge(pan: 0.1, tilt: -0.6)! == ("down", 12))
        #expect(WyzeLakePanTilt.nudge(pan: 0, tilt: 0.01)! == ("up", 1))
        #expect(WyzeLakePanTilt.nudge(pan: 0, tilt: 0) == nil)
        #expect(WyzeModels.pansAndTilts("hl_pan4") && !WyzeModels.pansAndTilts("HL_CAM4"))
    }

    @Test func theHelperKindComesFromTheSavedWay() {
        #expect(WyzeHelpers.kind(of: IntegrationSettings(service: .wyze, details: [IntegrationSettings.Key.wyzeWay: "cloud"])) == .cloud)
        #expect(WyzeHelpers.kind(of: IntegrationSettings(service: .wyze, details: [IntegrationSettings.Key.wyzeWay: "gwell"])) == .gwell)
        #expect(WyzeHelpers.kind(of: IntegrationSettings(service: .wyze, details: [IntegrationSettings.Key.wyzeWay: "rtsp"])) == nil)
        #expect(WyzeHelpers.kind(of: IntegrationSettings(service: .ring, details: [IntegrationSettings.Key.wyzeWay: "cloud"])) == nil)
    }
}
