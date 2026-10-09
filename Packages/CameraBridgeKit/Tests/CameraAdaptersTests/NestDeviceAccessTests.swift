import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct NestDeviceAccessTests {
    private let devices = #"""
    {"devices":[
      {"name":"enterprises/proj-1/devices/AVPHwEu1","type":"sdm.devices.types.DOORBELL",
       "traits":{"sdm.devices.traits.Info":{"customName":"Front Door"},"sdm.devices.traits.CameraLiveStream":{"supportedProtocols":["WEB_RTC"]}},
       "parentRelations":[{"parent":"enterprises/proj-1/structures/s/rooms/r","displayName":"Porch"}]},
      {"name":"enterprises/proj-1/devices/AVPHwEu2","type":"sdm.devices.types.CAMERA",
       "traits":{"sdm.devices.traits.Info":{"customName":""},"sdm.devices.traits.CameraLiveStream":{"supportedProtocols":["RTSP"]}},
       "parentRelations":[{"displayName":"Garage"}]},
      {"name":"enterprises/proj-1/devices/THERM","type":"sdm.devices.types.THERMOSTAT","traits":{}}
    ]}
    """#

    private func access(_ requests: Box<[URLRequest]>, reply: @escaping @Sendable (URLRequest) -> (String, Int)) -> NestDeviceAccess {
        NestDeviceAccess(transport: { request in
            requests.update { $0.append(request) }
            let (body, status) = reply(request)
            return (Data(body.utf8), status)
        })
    }

    @Test func authorizationLinkIsGoogles() throws {
        let url = try NestDeviceAccess.authorizationURL(projectID: " 11111111-2222-3333-4444-555555555555 ", clientID: "id.apps.googleusercontent.com")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "nestservices.google.com" && components.path == "/partnerconnections/11111111-2222-3333-4444-555555555555/auth")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "id.apps.googleusercontent.com" && items["response_type"] == "code" && items["access_type"] == "offline")
        #expect(items["prompt"] == "consent" && items["scope"] == "https://www.googleapis.com/auth/sdm.service" && items["redirect_uri"] == "https://www.google.com")
        for (project, client) in [("", "c"), ("a/b", "c"), ("p", ""), ("p", "a b"), ("p q", "c")] {
            #expect(throws: NestDeviceAccess.Failure.self) { try NestDeviceAccess.authorizationURL(projectID: project, clientID: client) }
        }
    }

    @Test func codeFromWhatWasPasted() {
        #expect(NestDeviceAccess.code(from: "https://www.google.com/?code=4/0AQlEd8x-y_z&scope=https://www.googleapis.com/auth/sdm.service") == "4/0AQlEd8x-y_z")
        #expect(NestDeviceAccess.code(from: "  4/0AQlEd8x-y_z \n") == "4/0AQlEd8x-y_z")
        #expect(NestDeviceAccess.code(from: "https://www.google.com/?error=access_denied") == nil)
        for text in ["", "   ", "two words", "a=b", "https://x/y"] { #expect(NestDeviceAccess.code(from: text) == nil, "\(text)") }
    }

    @Test func exchangeSendsAFormAndReturnsTheTokens() async throws {
        let requests = Box<[URLRequest]>([])
        let nest = access(requests) { _ in (#"{"access_token":"ya29.A","refresh_token":"1//0R","expires_in":3599,"token_type":"Bearer"}"#, 200) }
        let tokens = try await nest.exchange(code: "4/0Acode", clientID: "cid", clientSecret: "GOCSPX-s e")
        #expect(tokens == NestDeviceAccess.Tokens(accessToken: "ya29.A", refreshToken: "1//0R"))
        let request = try #require(requests.value.first)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://www.googleapis.com/oauth2/v4/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "client_id=cid&client_secret=GOCSPX-s+e&code=4%2F0Acode&grant_type=authorization_code&redirect_uri=https%3A%2F%2Fwww.google.com")
        #expect(request.url?.query == nil, "secrets travel in the body, not the address")
    }

    @Test func googlesRefusalsAreReadable() async throws {
        let requests = Box<[URLRequest]>([])
        let used = access(requests) { _ in (#"{"error":"invalid_grant","error_description":"Bad Request"}"#, 400) }
        do {
            _ = try await used.exchange(code: "c", clientID: "i", clientSecret: "s")
            Issue.record("accepted")
        } catch let failure as NestDeviceAccess.Failure {
            #expect(failure == .refused("invalid_grant") && failure.errorDescription?.contains("once") == true)
        }
        let noRefresh = access(requests) { _ in (#"{"access_token":"a"}"#, 200) }
        await #expect(throws: NestDeviceAccess.Failure.self) { _ = try await noRefresh.exchange(code: "c", clientID: "i", clientSecret: "s") }
        let garbage = access(requests) { _ in ("<html>", 200) }
        await #expect(throws: NestDeviceAccess.Failure.invalidResponse) { _ = try await garbage.exchange(code: "c", clientID: "i", clientSecret: "s") }
        let long = access(requests) { _ in (#"{"error":"\#(String(repeating: "x", count: 500))"}"#, 500) }
        do {
            _ = try await long.exchange(code: "c", clientID: "i", clientSecret: "s")
        } catch NestDeviceAccess.Failure.refused(let reason) {
            #expect(reason.count <= 60)
        }
    }

    @Test func listsCamerasAndDoorbellsOnly() async throws {
        let requests = Box<[URLRequest]>([])
        let nest = access(requests) { _ in (devices, 200) }
        let cameras = try await nest.cameras(projectID: "proj-1", accessToken: "ya29.A")
        #expect(cameras == [NestDeviceAccess.Camera(deviceID: "AVPHwEu1", name: "Front Door", protocolName: "WEB_RTC", isDoorbell: true),
                            NestDeviceAccess.Camera(deviceID: "AVPHwEu2", name: "Garage", protocolName: "RTSP", isDoorbell: false)])
        let request = try #require(requests.value.first)
        #expect(request.url?.absoluteString == "https://smartdevicemanagement.googleapis.com/v1/enterprises/proj-1/devices")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.A")
        await #expect(throws: NestDeviceAccess.Failure.self) { _ = try await nest.cameras(projectID: "bad/id", accessToken: "t") }
        let none = access(requests) { _ in ("{}", 200) }
        #expect(try await none.cameras(projectID: "proj-1", accessToken: "t").isEmpty)
    }

    @Test func aRefreshTokenGivesANewAccessToken() async throws {
        let requests = Box<[URLRequest]>([])
        let nest = access(requests) { _ in (#"{"access_token":"fresh"}"#, 200) }
        #expect(try await nest.accessToken(refreshToken: "1//0R", clientID: "c", clientSecret: "s") == "fresh")
        let body = String(decoding: requests.value[0].httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token") && body.contains("refresh_token=1%2F%2F0R"))
    }

    @Test func theSourceTheWizardBuildsFromTheCameraWorksWithTheHelper() throws {
        let camera = NestDeviceAccess.Camera(deviceID: "AVPHwEu2", name: "Garage", protocolName: "RTSP", isDoorbell: false)
        let source = try Go2RTCSource.nest(clientID: "cid", clientSecret: "s", refreshToken: "1//0R", projectID: "proj-1", deviceID: camera.deviceID,
                                           protocols: camera.protocolName)
        #expect(source.url.contains("protocols=RTSP") && source.url.contains("device_id=AVPHwEu2") && source.service == .nest)
    }
}
