// Loopback mock cameras (PlatformApple transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import Testing
import TestSupport
@testable import CameraAdapters

/// A camera added as ONVIF is asked for its maker's own interface (`CameraDrivers.ownInterface`), and a camera with no admin password yet
/// says so without a login (`CameraDrivers.needsSetup`). Cameras are loopback fakes; the ANNKE one answers like the owner's I91ET:
/// ISAPI `deviceInfo` with a Digest challenge, realm "IP Camera(GV497)".
@Suite(.timeLimit(.minutes(1))) struct OwnInterfaceTests {
    private let credentials = HTTPCredentials(username: "admin", password: "secret")
    private let realm = "IP Camera(GV497)"

    /// An ISAPI camera: `deviceInfo` behind Digest; `accept` decides whether the password is right. Counts the signed-in requests.
    private func isapi(accept: Bool = true, attempts: Box<Int>) async throws -> MockHTTPServer {
        let realm = realm
        return try await MockHTTPServer.start { request in
            guard request.path == "/ISAPI/System/deviceInfo" else { return .status(404) }
            guard isDigestAuthorization(request.head.headers["Authorization"], realm: realm) else { return .digestChallenge(realm: realm) }
            attempts.update { $0 += 1 }
            return accept ? .xml((try? fixtureText("hikvision/deviceInfo.xml")) ?? "") : .digestChallenge(realm: realm)
        }
    }

    private func endpoint(_ server: MockHTTPServer) -> CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)) }

    @Test func aCameraThatAnswersISAPIIsHikvisionsWithItsModel() async throws {
        let attempts = Box(0)
        let server = try await isapi(attempts: attempts)
        defer { server.stop() }
        let check = await CameraDrivers.ownInterface(endpoint: endpoint(server), credentials: credentials)
        #expect(check == .found(OwnInterface(vendor: .hikvision, manufacturer: nil, model: "DS-2CD2387G2P-LSU/SL")))
        #expect(attempts.value == 1)
    }

    @Test func aCameraWithoutISAPIStaysONVIFAndIsNeverSentTheCredentials() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let signedIn = Box(0)
        camera.otherAPI.set { request in
            if request.head.headers["Authorization"] != nil { signedIn.update { $0 += 1 } }
            return request.path.hasPrefix("/ISAPI") || request.path.hasPrefix("/cgi-bin/magicBox") || request.path == "/api.cgi" ? .status(404) : nil
        }
        #expect(await CameraDrivers.ownInterface(endpoint: camera.endpoint, credentials: credentials) == .none)
        #expect(signedIn.value == 0)
    }

    @Test func aWrongPasswordIsOneFailedLoginThenTheCameraIsLeftAlone() async throws {
        let attempts = Box(0)
        let server = try await isapi(accept: false, attempts: attempts)
        defer { server.stop() }
        let endpoint = endpoint(server)
        #expect(await CameraDrivers.ownInterface(endpoint: endpoint, credentials: credentials) == .rejected)
        #expect(attempts.value == 1)
        // Logins to the camera are paused now: nothing more is sent.
        #expect(await CameraDrivers.ownInterface(endpoint: endpoint, credentials: credentials) == .none)
        #expect(attempts.value == 1)
        ONVIFLoginGuard.shared.clear(host: AmcrestAPI.loginKey(endpoint))
    }

    @Test func nothingIsAskedWithoutCredentials() async throws {
        let asked = Box(0)
        let server = try await MockHTTPServer.start { _ in
            asked.update { $0 += 1 }
            return .status(404)
        }
        defer { server.stop() }
        #expect(await CameraDrivers.ownInterface(endpoint: endpoint(server), credentials: nil) == .none)
        #expect(asked.value == 0)
    }

    @Test func reolinkAndDahuaAreRecognisedWithoutALogin() async throws {
        let reolink = try await MockReolinkCamera.start()
        defer { reolink.stop() }
        #expect(await CameraDrivers.ownInterface(endpoint: reolink.endpoint, credentials: credentials) == .found(OwnInterface(vendor: .reolink)))
        let dahua = try await MockHTTPServer.start { request in
            request.path == "/cgi-bin/magicBox.cgi" ? .digestChallenge(realm: "Login to 4K0123456789") : .status(404)
        }
        defer { dahua.stop() }
        #expect(await CameraDrivers.ownInterface(endpoint: endpoint(dahua), credentials: credentials) == .found(OwnInterface(vendor: .amcrest)))
    }

    @Test func aCameraThatNeverAnswersCostsOneTimeout() async throws {
        let silent = try await MockHTTPServer.start { _ in
            try? await Task.sleep(for: .seconds(30))
            return .status(500)
        }
        defer { silent.stop() }
        let started = ContinuousClock.now
        let check = await CameraDrivers.ownInterface(endpoint: endpoint(silent), credentials: credentials, timeout: .seconds(1))
        #expect(check == .none)
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    // MARK: A camera with no admin password yet

    private func activation(_ status: String?) async throws -> MockHTTPServer {
        try await MockHTTPServer.start { request in
            guard request.path == "/SDK/activateStatus", let status else { return .status(404) }
            return .xml("<?xml version=\"1.0\" encoding=\"UTF-8\"?><ActivateStatus version=\"2.0\" xmlns=\"http://www.hikvision.com/ver20/XMLSchema\"><Activated>\(status)</Activated></ActivateStatus>")
        }
    }

    @Test func aHikvisionCameraThatIsNotActivatedNeedsSetup() async throws {
        let server = try await activation("false")
        defer { server.stop() }
        #expect(await CameraDrivers.needsSetup(endpoint: endpoint(server)) == NotSetUp(maker: "Hikvision", vendor: .hikvision))
    }

    @Test func anActivatedOrUnrelatedCameraDoesNotNeedSetup() async throws {
        let activated = try await activation("true")
        defer { activated.stop() }
        #expect(await CameraDrivers.needsSetup(endpoint: endpoint(activated)) == nil)
        let other = try await activation(nil)
        defer { other.stop() }
        #expect(await CameraDrivers.needsSetup(endpoint: endpoint(other)) == nil)
    }

    @Test func theSetupCheckMakesNoLoginAndIsBounded() async throws {
        let signedIn = Box(0)
        let server = try await MockHTTPServer.start { request in
            if request.head.headers["Authorization"] != nil { signedIn.update { $0 += 1 } }
            try? await Task.sleep(for: .seconds(30))
            return .status(500)
        }
        defer { server.stop() }
        let started = ContinuousClock.now
        #expect(await CameraDrivers.needsSetup(endpoint: endpoint(server), timeout: .seconds(1)) == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(signedIn.value == 0)
    }
}
#endif
