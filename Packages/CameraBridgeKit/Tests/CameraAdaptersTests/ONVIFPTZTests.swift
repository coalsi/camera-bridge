import BridgeSupport
import Foundation
import Testing
import TestSupport
@testable import CameraAdapters

/// ONVIF PTZ: the messages the camera gets (ContinuousMove with only the axes asked for, Stop of both) and reading its node's spaces.
@Suite struct ONVIFPTZTests {
    @Test func aMoveSendsOnlyTheAxesAskedFor() {
        let pan = ONVIFClient.continuousMoveBody(profileToken: "Profile_1", pan: 0.5, tilt: -0.25, zoom: nil)
        #expect(pan.contains("<tptz:ProfileToken>Profile_1</tptz:ProfileToken>"))
        #expect(pan.contains("<tt:PanTilt x=\"0.50\" y=\"-0.25\"/>") && !pan.contains("Zoom"))
        #expect(pan.contains("xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\""))
        let zoom = ONVIFClient.continuousMoveBody(profileToken: "a<b", pan: nil, tilt: nil, zoom: -2)
        #expect(zoom.contains("<tt:Zoom x=\"-1.00\"/>") && !zoom.contains("PanTilt"), "clamped, and no pan/tilt for a zoom")
        #expect(zoom.contains("a&lt;b"))
        #expect(pan.contains("</tptz:Velocity><tptz:Timeout>PT1S</tptz:Timeout></tptz:ContinuousMove>"),
                "a camera stops by itself after a second, even when the Stop is lost")
        #expect(!ONVIFClient.continuousMoveBody(profileToken: "P", pan: 0.5, tilt: 0, zoom: nil, timeout: false).contains("Timeout"))
    }

    @Test func theNodeSaysWhatTheCameraCanDo() throws {
        let xml = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
        <s:Body><tptz:GetNodesResponse><tptz:PTZNode token="PTZNODE"><tt:Name>PTZ</tt:Name><tt:SupportedPTZSpaces>
        <tt:ContinuousPanTiltVelocitySpace><tt:URI>http://www.onvif.org/ver10/tptz/PanTiltSpaces/VelocityGenericSpace</tt:URI></tt:ContinuousPanTiltVelocitySpace>
        <tt:ContinuousZoomVelocitySpace><tt:URI>http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace</tt:URI></tt:ContinuousZoomVelocitySpace>
        </tt:SupportedPTZSpaces></tptz:PTZNode></tptz:GetNodesResponse></s:Body></s:Envelope>
        """
        let nodes = ONVIFClient.parsePTZNodes(try XMLTree.parse(Data(xml.utf8)))
        #expect(nodes == [ONVIFPTZNode(continuousPanTilt: true, continuousZoom: true)])
    }

    @Test func aProfileWithAPTZConfigurationIsMarked() throws {
        let xml = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
        <s:Body><trt:GetProfilesResponse>
        <trt:Profiles token="Profile_1"><tt:Name>main</tt:Name><tt:PTZConfiguration token="PTZ"><tt:Name>PTZ</tt:Name></tt:PTZConfiguration></trt:Profiles>
        <trt:Profiles token="Profile_2"><tt:Name>sub</tt:Name></trt:Profiles>
        </trt:GetProfilesResponse></s:Body></s:Envelope>
        """
        let profiles = ONVIFClient.parseProfiles(try XMLTree.parse(Data(xml.utf8)))
        #expect(profiles.map(\.ptzConfigured) == [true, false])
    }
}

#if os(macOS) || os(Linux)
/// Review Oct 31 (adapters F1, F2): a step whose ContinuousMove (or Stop) failed left the camera turning, and a held arrow on a slow camera
/// queued steps that kept turning it for seconds after the button was let go. On Linux through `PlainHTTP`, as the daemon asks a camera
/// (`.plainHTTPRoute`: the camera drops a move or a stop).
@Suite(.timeLimit(.minutes(1)), .plainHTTPRoute) struct ONVIFPanTiltStepTests {
    private func started() async throws -> (MockONVIFCamera, ONVIFPanTilt, String) {
        let camera = try await MockONVIFCamera.start()
        camera.ptz.set(true)
        let host = "127.0.0.1:\(camera.server.port)"
        ONVIFLoginGuard.shared.clear(host: host)
        let url = try #require(ONVIFClient.deviceServiceURL(for: camera.endpoint))
        let client = ONVIFClient(deviceServiceURL: url, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                 timeout: .seconds(2))
        let control = ONVIFPanTilt(client: client, log: Log(category: "PTZTest"))
        #expect(try await control.capabilities() == PanTiltCapabilities(panTilt: true, zoom: true))
        return (camera, control, host)
    }

    @Test(arguments: [MockONVIFCamera.PTZMoveAnswer.lost, .notSOAP])
    func aMoveWhoseAnswerWentWrongIsStillStopped(_ answer: MockONVIFCamera.PTZMoveAnswer) async throws {
        let (camera, control, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.ptzMoveAnswer.set(answer)
        await #expect(throws: (any Error).self) { try await control.move(pan: 1, tilt: 0) }
        #expect(await eventually(timeout: .seconds(5)) { camera.ptzCalls.value.last == "Stop" }, "\(camera.ptzCalls.value)")
    }

    @Test func aLostStopIsSentAgain() async throws {
        let (camera, control, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.ptzStopsLost.set(1)
        try await control.move(pan: 1, tilt: 0)
        #expect(camera.ptzCalls.value == ["ContinuousMove+Timeout", "Stop", "Stop"])
    }

    @Test func aCameraThatRefusesTheTimeoutIsMovedWithoutIt() async throws {
        let (camera, control, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.ptzMoveAnswer.set(.refusesTimeout)
        try await control.move(pan: 1, tilt: 0)
        try await control.move(pan: 0, tilt: 1)
        #expect(camera.ptzCalls.value == ["ContinuousMove+Timeout", "ContinuousMove", "Stop", "ContinuousMove", "Stop"], "asked once, then left out")
    }

    /// The page holds an arrow: moves come faster than a slow camera takes a step. At most one waits (the newest direction), and the
    /// release's stop drops it, so nothing turns the camera after the Stop.
    @Test func aHeldArrowOnASlowCameraDoesNotPileUpSteps() async throws {
        let (camera, control, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.ptzMoveDelay.set(.milliseconds(300))
        let first = Task { try await control.move(pan: 1, tilt: 0) }
        #expect(await eventually(timeout: .seconds(5)) { camera.ptzCalls.value.count == 1 })
        let answered = Box(0)
        let queued = (0..<5).map { _ in Task { try await control.move(pan: 1, tilt: 0); answered.update { $0 += 1 } } }
        #expect(await eventually { answered.value == 4 }, "four gave their place to a newer one and answered at once, no step taken")
        try await control.stop()
        for task in queued { try await task.value }   // the last one is dropped by the stop
        try await first.value
        try await Task.sleep(for: .milliseconds(200))
        let calls = camera.ptzCalls.value
        #expect(calls.filter { $0.hasPrefix("ContinuousMove") }.count == 1, "\(calls)")
        #expect(calls.last == "Stop", "\(calls)")
    }
}
#endif

/// The main-stream bit rate cap Optimize and Camera setup use: 6 Mbit/s, 8 Mbit/s for 4K and 8 MP cameras.
@Suite struct MainBitrateCapTests {
    @Test func fourKCamerasMayKeepEightMegabits() {
        #expect(HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: 3840, height: 2160) == 8000)
        #expect(HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: 4256, height: 1888) == 8000, "the 8 MP panoramic Hikvisions")
        #expect(HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: 2688, height: 1520) == 6000)
        #expect(HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: nil, height: nil) == 6000)
    }
}
