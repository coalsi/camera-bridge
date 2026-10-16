import Foundation
import Testing
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

/// The main-stream bit rate cap Optimize and Camera setup use: 6 Mbit/s, 8 Mbit/s for 4K and 8 MP cameras.
@Suite struct MainBitrateCapTests {
    @Test func fourKCamerasMayKeepEightMegabits() {
        #expect(HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: 3840, height: 2160) == 8000)
        #expect(HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: 4256, height: 1888) == 8000, "the 8 MP panoramic Hikvisions")
        #expect(HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: 2688, height: 1520) == 6000)
        #expect(HomeKitReadinessAdvisor.maximumMainBitrateKbps(width: nil, height: nil) == 6000)
    }
}
