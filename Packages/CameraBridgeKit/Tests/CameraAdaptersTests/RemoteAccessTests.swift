// Loopback fake cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// `CameraSettingsService.readRemoteAccess()`: what each camera family says about its ways out (the maker's cloud, UPnP, DDNS, RTMP, extra
/// services, video without a password), with what could not be read as unknown, never off. Against loopback fakes only.
@Suite(.timeLimit(.minutes(1))) struct RemoteAccessTests {
    private func finding(_ feature: RemoteAccessFeature, _ state: RemoteAccessState, linked: Bool? = nil, service: String? = nil,
                         canChange: Bool = false) -> RemoteAccessFinding {
        RemoteAccessFinding(feature: feature, state: state, linked: linked, service: service, canChange: canChange)
    }

    // MARK: The IPCamera Web family

    @Test func theIPCamWebFamilyReportsWhatItsPageShows() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .onvif)
        let findings = try await service.readRemoteAccess()
        #expect(findings == [
            finding(.cloud, .on, service: "VisionEye cloud", canChange: true),
            finding(.cloud, .absent, service: "cloud service"),
            finding(.cloud, .absent, service: "P2P service"),
            finding(.cloud, .absent, service: "platform service"),
            finding(.upnp, .absent),
            finding(.ddns, .off),
            finding(.rtmp, .off),
            finding(.extraService, .on, service: "Hikvision protocol (port 8000)", canChange: true),
            finding(.unauthenticatedVideo, .on, service: "Hikvision protocol (port 8000)", canChange: true),
            finding(.extraService, .on, service: "Meari service (port 10000)", canChange: true),
            finding(.unauthenticatedVideo, .on, service: "Meari service (port 10000)", canChange: true),
            finding(.unauthenticatedVideo, .on, canChange: true),
        ])
        #expect(camera.signIns.count == 1, "one session for every reading")
        #expect(camera.reads("wifiap") == 0, "its Wi-Fi access point is not read: the camera has no radio")
        #expect(camera.calls.value.allSatisfy { $0.op == "get" }, "a check never writes")
    }

    /// An extra service that is on and asks no password (`authorized` 0) lets anyone at home connect, whatever RTSP and ONVIF ask.
    @Test func anExtraServiceWithoutAPasswordIsVideoWithoutAPassword() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        camera.options.update { options in
            options["rtsp"] = options["rtsp"]?.replacingOccurrences(of: #"authorized="0""#, with: #"authorized="1""#)
            options["onvif"] = options["onvif"]?.replacingOccurrences(of: #"authorized="0""#, with: #"authorized="1""#)
            options["meari"] = #"<meari on="0" authorized="0" port="10000"/>"#
            options["hik"] = #"<hik on="1" authorized="1" port="8000" dataport="8200"/>"#
        }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .onvif)
        let locked = try await service.readRemoteAccess().filter { $0.feature == .unauthenticatedVideo }
        #expect(locked == [finding(.unauthenticatedVideo, .off, canChange: true)], "an extra service that is off, or asks a password, opens nothing")

        camera.options.update { $0["hik"] = #"<hik on="1" authorized="0" port="8000" dataport="8200"/>"# }
        let open = try await CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .onvif)
            .readRemoteAccess().filter { $0.feature == .unauthenticatedVideo }
        #expect(open == [finding(.unauthenticatedVideo, .on, service: "Hikvision protocol (port 8000)", canChange: true),
                         finding(.unauthenticatedVideo, .off, canChange: true)])
    }

    @Test func theIPCamWebFamilysVideoPasswordNeedsAStoredPasswordToBeChanged() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        camera.options.update { $0["mobile"] = #"<mobile on="0" sendalarm="1" cuid="TESTCUID000001"/>"# }
        camera.accepted.set("")   // a camera without a password
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: ""), vendor: .onvif)
        let findings = try await service.readRemoteAccess()
        #expect(findings.first == finding(.cloud, .off, service: "VisionEye cloud", canChange: true))
        #expect(findings.last == finding(.unauthenticatedVideo, .on), "no password saved: the setup can't lock the video")
    }

    @Test func aRefusedSignInLeavesEverythingUnknown() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop(); for key in IPCamWebClient.loginKeys(camera.endpoint) { ONVIFLoginGuard.shared.clear(host: key) } }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "wrong"), vendor: .onvif)
        let findings = try await service.readRemoteAccess()
        #expect(findings.first == finding(.cloud, .unknown, service: "VisionEye cloud"))
        #expect(findings.allSatisfy { $0.state == .unknown }, "never off")
        #expect(camera.signIns.count == 1, "the refusal is not repeated")
    }

    // MARK: Hikvision

    @Test func hikvisionReportsHikConnectUPnPAndDDNS() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .hikvision)
        // registerStatus says whether the camera is signed in to Hik-Connect's servers now, not whether it is bound to an account.
        #expect(try await service.readRemoteAccess() == [
            finding(.cloud, .on, service: "Hik-Connect", canChange: true),
            finding(.upnp, .on, canChange: true),
            finding(.ddns, .absent),
        ])

        camera.documents.update { documents in
            documents["/ISAPI/System/Network/EZVIZ"] = FakeSetupCamera.cloud.replacingOccurrences(of: "<registerStatus>true", with: "<registerStatus>false")
            documents["/ISAPI/System/Network/DDNS"] = """
            <?xml version="1.0" encoding="UTF-8"?><DDNSList version="2.0" \(FakeSetupCamera.ns)><DDNS><id>1</id><enabled>false</enabled>\
            <provider>HiDDNS</provider></DDNS></DDNSList>
            """
            documents[HikvisionISAPI.networkCapabilitiesPath] = FakeSetupCamera.networkCapabilities
                .replacingOccurrences(of: "<isSupportUPnP>true</isSupportUPnP>", with: "<isSupportUPnP>false</isSupportUPnP>")
        }
        #expect(try await service.readRemoteAccess() == [
            finding(.cloud, .on, service: "Hik-Connect", canChange: true),
            finding(.upnp, .absent),
            finding(.ddns, .off),
        ])
        #expect(camera.puts.value.isEmpty, "a check never writes")
    }

    /// Absent only when the camera's capabilities say it has no such feature; a feature Camera Bridge could not read is unknown.
    @Test func aHikConnectOrUPnPThatCannotBeReadIsUnknownNotAbsent() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .hikvision)
        camera.documents.update { documents in
            documents["/ISAPI/System/Network/EZVIZ"] = nil   // the capabilities say it has one, but no path answers
            documents["/ISAPI/System/Network/UPnP"] = nil
        }
        #expect(try await service.readRemoteAccess().prefix(2) == [finding(.cloud, .unknown, service: "Hik-Connect"), finding(.upnp, .unknown)])
        camera.documents.update { $0[HikvisionISAPI.networkCapabilitiesPath] = nil }
        #expect(try await service.readRemoteAccess().prefix(2) == [finding(.cloud, .unknown, service: "Hik-Connect"), finding(.upnp, .unknown)],
                "no capabilities either")
        camera.documents.update {
            $0[HikvisionISAPI.networkCapabilitiesPath] = FakeSetupCamera.networkCapabilities
                .replacingOccurrences(of: "<isSupportEZVIZ>true</isSupportEZVIZ>", with: "<isSupportEZVIZ>false</isSupportEZVIZ>")
        }
        #expect(try await service.readRemoteAccess().first == finding(.cloud, .absent, service: "Hik-Connect"), "the camera says it has none")
    }

    @Test func aHikvisionCameraThatDoesNotAnswerIsUnknown() async throws {
        let camera = try await FakeSetupCamera.start()
        let endpoint = camera.endpoint, credentials = camera.credentials
        camera.stop()
        let service = CameraSettingsService(endpoint: endpoint, credentials: credentials, vendor: .hikvision)
        #expect(try await service.readRemoteAccess() == [
            finding(.cloud, .unknown, service: "Hik-Connect"), finding(.upnp, .unknown), finding(.ddns, .unknown),
        ])
        #expect(await service.remoteAccessUnanswered, "the engine keeps the last readings and tries again soon")
    }

    // MARK: The IP camera web API (Jennov)

    @Test func theIPCameraWebAPIReportsItsCloudUPnPAndRTMP() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .onvif)
        // Its cloud's sign-in status says whether it is online, not whether it is bound to an account; RTMP is not asked (below).
        #expect(try await service.readRemoteAccess() == [
            finding(.cloud, .on, canChange: true),
            finding(.upnp, .off),
            finding(.rtmp, .unknown),
        ])
        #expect(Set(camera.calls.value.map(\.name)).isSubset(of: ["getSystemVersionInfo", "getSystemControlString", "getNetworkConfig"]),
                "only the calls checked by hand")
        #expect(!IPCWebLatch.shared.isTripped(IPCWebLatch.key(camera.endpoint)), "night vision keeps its web API")
    }

    /// A call the camera lacks pauses its web API, and night vision with it, until the camera restarts in the bridge: RTMP and the cloud's
    /// status are not asked until those calls are confirmed on a real camera, also of firmware that names RTMP.
    @Test func rtmpAndTheCloudsStatusAreNotAsked() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .onvif)
        _ = try await service.readRemoteAccess()
        #expect(camera.calls("getMediaStreamConfig").isEmpty && camera.calls("getNetworkStatus").isEmpty)
        #expect(!IPCWebLatch.shared.isTripped(IPCWebLatch.key(camera.endpoint)), "no call the camera might not have")
    }

    // MARK: Reolink

    /// Reolink's `/api.cgi` JSON commands: a login, then `GetP2p`, `GetUpnp` and `GetDdns` (nil answers -9 "not support").
    final class FakeReolink: Sendable {
        let server: MockHTTPServer
        let p2p = Box<String?>(#"{"P2p":{"enable":1,"uid":"95270000TEST0001"}}"#)
        let upnp = Box<String?>(#"{"Upnp":{"enable":0}}"#)
        let ddns = Box<String?>(#"{"Ddns":{"enable":0,"type":"3322","domain":"","userName":"","password":""}}"#)
        /// `GetAbility`'s value; nil answers -9 "not support".
        let ability = Box<String?>(nil)
        let commands = Box<[String]>([])

        var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)) }

        init() async throws {
            let holder = Box<FakeReolink?>(nil)
            server = try await MockHTTPServer.start { request in holder.value?.handle(request) ?? .status(503) }
            holder.set(self)
        }

        private func handle(_ request: MockRequest) -> MockResponse {
            let cmd = request.query("cmd") ?? ""
            commands.update { $0.append(cmd) }
            func value(_ text: String) -> MockResponse { .json(#"[{"cmd":"\#(cmd)","code":0,"value":\#(text)}]"#) }
            switch cmd {
            case "Login": return value(#"{"Token":{"leaseTime":3600,"name":"tok1"}}"#)
            case "Logout": return value(#"{"rspCode":200}"#)
            case "GetP2p", "GetUpnp", "GetDdns":
                guard let answer = (cmd == "GetP2p" ? p2p : cmd == "GetUpnp" ? upnp : ddns).value else {
                    return .json(#"[{"cmd":"\#(cmd)","code":1,"error":{"detail":"not support","rspCode":-9}}]"#)
                }
                return value(answer)
            case "GetAbility" where ability.value != nil: return value(ability.value ?? "")
            default: return .json(#"[{"cmd":"\#(cmd)","code":1,"error":{"detail":"not support","rspCode":-9}}]"#)
            }
        }
    }

    @Test func reolinkReportsItsP2PUPnPAndDDNSAndARefusalIsUnknown() async throws {
        let camera = try await FakeReolink()
        defer { camera.server.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "secret"), vendor: .reolink)
        // "Set up for Camera Bridge" turns the UID and UPnP off through `SetP2p` and `SetUpnp` (GetAbility does not say otherwise here).
        #expect(try await service.readRemoteAccess() == [finding(.cloud, .on, service: "Reolink P2P", canChange: true), finding(.upnp, .off, canChange: true),
                                                         finding(.ddns, .off)])
        camera.p2p.set(nil)
        camera.ddns.set(#"{"Ddns":{"enable":1}}"#)
        #expect(try await service.readRemoteAccess() == [finding(.cloud, .unknown, service: "Reolink P2P"), finding(.upnp, .off, canChange: true),
                                                         finding(.ddns, .on)])
        #expect(camera.commands.value.filter { $0.hasPrefix("Set") }.isEmpty, "a check never writes")
        #expect(camera.commands.value.filter { $0 == "Login" }.count == 1, "one session for the service")
    }

    /// A UID or UPnP switch `GetAbility` says this account may not change is not offered as something the setup can change.
    @Test func aReolinkSwitchTheAccountMayNotChangeIsNotOfferedAsChangeable() async throws {
        let camera = try await FakeReolink()
        defer { camera.server.stop() }
        camera.ability.set(#"{"Ability":{"p2p":{"permit":4,"ver":1},"upnp":{"permit":6,"ver":1}}}"#)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "secret"), vendor: .reolink)
        #expect(try await service.readRemoteAccess() == [finding(.cloud, .on, service: "Reolink P2P"), finding(.upnp, .off, canChange: true),
                                                         finding(.ddns, .off)])
    }

    // MARK: Cameras without a reader

    @Test func anyOtherCamerasCloudIsUnknown() async throws {
        let server = try await MockHTTPServer.start { _ in .status(404) }
        defer { server.stop() }
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port), onvifPort: Int(server.port))
        for vendor in [CameraVendor.amcrest, .rtsp, .doorbird] {
            let service = CameraSettingsService(endpoint: endpoint, credentials: HTTPCredentials(username: "admin", password: "pw"), vendor: vendor)
            #expect(try await service.readRemoteAccess() == [.cloudUnknown], "\(vendor)")
        }
        #expect(server.requests.isEmpty, "nothing to ask")
        let onvif = CameraSettingsService(endpoint: endpoint, credentials: HTTPCredentials(username: "admin", password: "pw"), vendor: .onvif)
        #expect(try await onvif.readRemoteAccess() == [.cloudUnknown], "an ONVIF camera of neither web family")
        #expect(!server.requests.contains { $0.path.hasPrefix("/cgi/") }, "no sign-in")
    }
}
#endif
