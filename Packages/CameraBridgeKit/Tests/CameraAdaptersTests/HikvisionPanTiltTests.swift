// Loopback mock ISAPI camera (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// Review Oct 31 (adapters I1): a Hikvision or ANNKE PTZ dome added through its own interface (ISAPI, which the wizard now prefers over
/// ONVIF, and Hikvision ships with ONVIF off) had no pan/tilt pad. It pans, tilts and zooms through ISAPI's `PTZCtrl`, in steps like ONVIF's.
@Suite(.timeLimit(.minutes(1))) struct HikvisionPanTiltTests {
    /// A camera whose channel 1 has continuous pan/tilt (and zoom when `zoom`), or no PTZ at all (404); every PTZ PUT is kept.
    final class Dome: Sendable {
        let server: MockHTTPServer
        let puts = Box<[String]>([])
        init(ptz: Bool, zoom: Bool = true) async throws {
            let puts = puts
            server = try await MockHTTPServer.start { request in
                guard isDigestAuthorization(request.head.headers["Authorization"]) else { return .digestChallenge() }
                switch (request.method, request.path) {
                case ("GET", "/ISAPI/PTZCtrl/channels/1/capabilities"):
                    guard ptz else { return .status(404) }
                    let zoomSpace = zoom ? "<ContinuousZoomSpace><XRange><Min>-100</Min><Max>100</Max></XRange></ContinuousZoomSpace>" : ""
                    return .xml("""
                    <?xml version="1.0" encoding="UTF-8"?><PTZChanelCap version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema">\
                    <ContinuousPanTiltSpace><XRange><Min>-100</Min><Max>100</Max></XRange></ContinuousPanTiltSpace>\(zoomSpace)</PTZChanelCap>
                    """)
                case ("PUT", "/ISAPI/PTZCtrl/channels/1/continuous"):
                    puts.update { $0.append(request.bodyText) }
                    return .xml("<ResponseStatus><statusCode>1</statusCode><statusString>OK</statusString></ResponseStatus>")
                default:
                    return .status(404)
                }
            }
        }
        var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)) }
    }

    private func driver(_ dome: Dome) -> HikvisionDriver {
        HikvisionDriver(endpoint: dome.endpoint, credentials: HTTPCredentials(username: "admin", password: "pa55"), mainStreamURL: nil, subStreamURL: nil,
                        transport: PlatformNetworkTransport())
    }

    @Test func aDomePansTiltsAndZoomsInSteps() async throws {
        let dome = try await Dome(ptz: true)
        defer { dome.server.stop() }
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(dome.server.port)")
        let control = try #require(driver(dome).makePanTilt())
        #expect(try await control.capabilities() == PanTiltCapabilities(panTilt: true, zoom: true))
        try await control.move(pan: 1, tilt: 0)
        try await control.zoom(-1)
        try await control.stop()
        let puts = dome.puts.value
        #expect(puts.count == 5, "\(puts)")
        #expect(puts[0].contains("<pan>50</pan>") && puts[0].contains("<tilt>0</tilt>") && !puts[0].contains("<zoom>"))
        #expect(puts[1].contains("<pan>0</pan>") && puts[1].contains("<tilt>0</tilt>") && puts[1].contains("<zoom>0</zoom>"), "a stop after each step")
        #expect(puts[2].contains("<zoom>-50</zoom>") && !puts[2].contains("<pan>"))
        #expect(puts[4].contains("<pan>0</pan>"), "and on release")
    }

    @Test func aCameraWithoutPTZHasNoPad() async throws {
        let dome = try await Dome(ptz: false)
        defer { dome.server.stop() }
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(dome.server.port)")
        let control = try #require(driver(dome).makePanTilt())
        #expect(try await control.capabilities() == PanTiltCapabilities(panTilt: false, zoom: false))
        await #expect(throws: CameraAdapterError.self) { try await control.move(pan: 1, tilt: 0) }
        #expect(dome.puts.value.isEmpty)
    }
}
#endif
