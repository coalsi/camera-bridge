// Loopback mock cameras (PlatformApple transport): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct DetectVendorTests {
    private let credentials = HTTPCredentials(username: "admin", password: "secret")

    private func detect(_ endpoint: CameraEndpoint, credentials: HTTPCredentials? = nil) async -> CameraVendor? {
        await CameraDrivers.detectVendor(endpoint: endpoint, credentials: credentials, fallbackONVIFPorts: [])
    }

    @Test func hikvisionByDigestRealm() async throws {
        let server = try await MockHTTPServer.start { request in
            request.path == "/ISAPI/System/deviceInfo" ? .digestChallenge(realm: "DS-2CD2387G2P-LSU") : .status(404)
        }
        defer { server.stop() }
        #expect(await detect(CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port))) == .hikvision)
    }

    @Test func hikvisionByISAPINamespaceWhenTheRealmIsGeneric() async throws {
        let server = try await MockHTTPServer.start { request in
            guard request.path == "/ISAPI/System/deviceInfo" else { return .status(404) }
            guard isDigestAuthorization(request.head.headers["Authorization"]) else { return .digestChallenge(realm: "IP Camera") }
            return .xml((try? fixtureText("hikvision/deviceInfo.xml")) ?? "")
        }
        defer { server.stop() }
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port))
        #expect(await detect(endpoint) == nil)                                  // generic realm, no credentials: inconclusive
        #expect(await detect(endpoint, credentials: credentials) == .hikvision)
    }

    @Test func reolinkByJSONAPI() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        #expect(await detect(camera.endpoint) == .reolink)
    }

    @Test func onvifByUnauthenticatedGetSystemDateAndTime() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        #expect(await detect(camera.endpoint) == .onvif)
    }

    @Test func hikvisionTakesPrecedenceOverONVIF() async throws {
        // A Hikvision camera also speaks ONVIF on the same port: ISAPI wins.
        let server = try await MockHTTPServer.start { request in
            if request.path == "/ISAPI/System/deviceInfo" { return .digestChallenge(realm: "Hikvision") }
            guard request.method == "POST", let body = try? XMLTree.parse(request.body),
                  body.child("Body")?.children.first?.name == "GetSystemDateAndTime" else { return .status(404) }
            return .soap("""
            <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>\
            <GetSystemDateAndTimeResponse><SystemDateAndTime/></GetSystemDateAndTimeResponse></s:Body></s:Envelope>
            """)
        }
        defer { server.stop() }
        #expect(await detect(CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port))) == .hikvision)
    }

    @Test func unreachableHostFailsWithinOneProbeTimeout() async throws {
        // A listener that accepts but never answers.
        let silent = try await MockHTTPServer.start { _ in
            try? await Task.sleep(for: .seconds(30))
            return .status(500)
        }
        defer { silent.stop() }
        let started = ContinuousClock.now
        let vendor = await CameraDrivers.detectVendor(endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(silent.port)), credentials: nil,
                                                      fallbackONVIFPorts: [], timeout: .seconds(1))
        #expect(vendor == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func nilWhenNothingAnswers() async throws {
        let server = try await MockHTTPServer.start { _ in .status(404) }
        defer { server.stop() }
        #expect(await detect(CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port))) == nil)
    }

    /// Many ONVIF devices serve the device service on 8000, 8080 or 2020 (Tapo), not on the HTTP port: detection
    /// reports the port that answered, so the probe and the saved camera reach the device service there.
    @Test func onvifOnAnotherPortReportsThatPort() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let web = try await MockHTTPServer.start { _ in .status(404) }
        defer { web.stop() }
        let onvifPort = Int(camera.server.port)
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(web.port))
        let detection = await CameraDrivers.detect(endpoint: endpoint, credentials: nil, fallbackONVIFPorts: [onvifPort])
        #expect(detection == VendorDetection(vendor: .onvif, onvifPort: onvifPort))
        #expect(await CameraDrivers.detectVendor(endpoint: endpoint, credentials: nil, fallbackONVIFPorts: [onvifPort]) == .onvif)
        #expect(await CameraDrivers.onvifPort(endpoint: endpoint, fallbackONVIFPorts: [onvifPort]) == onvifPort)

        var found = endpoint
        found.onvifPort = detection?.onvifPort
        let url = try #require(ONVIFClient.deviceServiceURL(for: found))
        let client = ONVIFClient(deviceServiceURL: url, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password))
        #expect(try await client.deviceInformation().manufacturer.isEmpty == false)
    }

    /// The device service on the HTTP port (or the configured ONVIF port) needs no extra port.
    @Test func onvifOnTheHTTPPortReportsNoExtraPort() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.server.port))
        #expect(await CameraDrivers.detect(endpoint: endpoint, credentials: nil, fallbackONVIFPorts: []) == VendorDetection(vendor: .onvif, onvifPort: nil))
        #expect(await CameraDrivers.onvifPort(endpoint: endpoint, fallbackONVIFPorts: []) == nil)
    }
}
#endif
