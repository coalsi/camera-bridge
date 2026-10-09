import Foundation
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct Go2RTCSourceTests {
    static let ring = "ring:?camera_id=123&device_id=abc&refresh_token=RT-SECRET-1"
    static let wyze = "wyze://192.168.1.20?uid=WYZEUID1234567890AB&enr=ENR-SECRET&mac=AABBCCDDEEFF&model=HL_CAM4&dtls=true"
    static let tuya = "tuya://protect-us.ismartlife.me?device_id=dev1&email=me%40example.com&password=hunter2"

    @Test func parsesTheSupportedSources() throws {
        let ring = try Go2RTCSource(parsing: Self.ring)
        #expect(ring.service == .ring && ring.scheme == "ring" && ring.host.isEmpty)
        #expect(ring.parameterNames == ["camera_id", "device_id", "refresh_token"])
        let wyze = try Go2RTCSource(parsing: Self.wyze)
        #expect(wyze.service == .wyze && wyze.host == "192.168.1.20")
        let tuya = try Go2RTCSource(parsing: Self.tuya)
        #expect(tuya.service == .tuya && tuya.host == "protect-us.ismartlife.me")
        let cloud = try Go2RTCSource(parsing: "tuya://openapi.tuyaus.com?device_id=d&uid=u&client_id=c&client_secret=s")
        #expect(cloud.service == .tuya)
        let other = try Go2RTCSource(parsing: "rtspx://192.168.1.1:7441/KEY123")
        #expect(other.service == .other && other.host == "192.168.1.1:7441")
    }

    @Test func descriptionNeverShowsASecret() throws {
        for text in [Self.ring, Self.wyze, Self.tuya, "rtspx://user:pw@192.168.1.1:7441/KEY123"] {
            let source = try Go2RTCSource(parsing: text)
            let shown = "\(source) \(source.description) \(String(describing: source))"
            for secret in ["RT-SECRET-1", "ENR-SECRET", "hunter2", "KEY123", "pw@", "example.com"] { #expect(!shown.contains(secret)) }
        }
        #expect(try Go2RTCSource(parsing: Self.ring).description == "ring:")
    }

    @Test func refusesSourcesThatRunProgramsAndBadInput() {
        let bad = ["", "   ", "exec:ffmpeg -i x", "echo:curl evil", "expr:1+1", "ffmpeg:rtsp://a/b", "http://a/b", "file:///etc/passwd", "no colon here",
                   "ring:?device_id=1&refresh_token=2",   // no camera_id
                   "nest:?client_id=1", "tuya://host?device_id=d", "wyze://?uid=1&enr=2", "ring:?camera_id=1&device_id=2&refresh_token=3\nexec:x",
                   "ring:?camera_id=1&device_id=2&refresh_token=a b", "rtspx://", String(repeating: "a", count: 5000)]
        for text in bad {
            #expect(throws: Go2RTCSource.Invalid.self, "\(text.prefix(30))") { try Go2RTCSource(parsing: text) }
        }
    }

    @Test func invalidMessagesDoNotQuoteTheInput() {
        do {
            _ = try Go2RTCSource(parsing: "ring:?device_id=1&refresh_token=TOPSECRET")
            Issue.record("accepted")
        } catch let invalid as Go2RTCSource.Invalid {
            #expect(!invalid.reason.contains("TOPSECRET"))
            #expect(invalid.reason.contains("camera_id"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func rtspsBecomesRtspx() throws {
        let source = try Go2RTCSource(parsing: "RTSPS://192.168.1.1:7441/KEY")
        #expect(source.scheme == "rtspx" && source.url == "rtspx://192.168.1.1:7441/KEY")
    }

    @Test func nestSourceEncodesLikeGo() throws {
        let source = try Go2RTCSource.nest(clientID: "id.apps.googleusercontent.com", clientSecret: "GOCSPX-a+b", refreshToken: "1//0g/x y",
                                           projectID: "proj-1", deviceID: "AVPHw")
        #expect(source.url == "nest:?client_id=id.apps.googleusercontent.com&client_secret=GOCSPX-a%2Bb&device_id=AVPHw&project_id=proj-1"
            + "&protocols=WEB_RTC&refresh_token=1%2F%2F0g%2Fx+y")
        #expect(source.service == .nest)
        #expect(throws: Go2RTCSource.Invalid.self) {
            try Go2RTCSource.nest(clientID: "", clientSecret: "s", refreshToken: "r", projectID: "p", deviceID: "d")
        }
    }

    @Test func unifiRTSPSBecomesRtspxWithoutTheSRTPSuffixOrUserInfo() throws {
        let source = try Go2RTCSource.unifiProtect(rtspsURL: "rtsps://192.168.1.1:7441/5nPr7RCmueGTKMP7?enableSrtp")
        #expect(source.url == "rtspx://192.168.1.1:7441/5nPr7RCmueGTKMP7")
        let withUser = try Go2RTCSource.unifiProtect(rtspsURL: "rtsps://u:p@192.168.1.1:7441/KEY?enableSrtp")
        #expect(withUser.url == "rtspx://192.168.1.1:7441/KEY")
        #expect(throws: Go2RTCSource.Invalid.self) { try Go2RTCSource.unifiProtect(rtspsURL: "https://192.168.1.1/x") }
        #expect(throws: Go2RTCSource.Invalid.self) { try Go2RTCSource.unifiProtect(rtspsURL: "rtsps://192.168.1.1:7441") }
    }
}

@Suite(.timeLimit(.minutes(1))) struct Go2RTCConfigTests {
    @Test func configurationHoldsNoSecretAndOnlyLoopback() {
        let config = Go2RTCConfig(apiPort: 41_001, rtspPort: 41_002,
                                  streams: [.init(name: "cb-abc", variable: "CB_SRC_0"), .init(name: "cb-def", variable: "CB_SRC_1")])
        let yaml = config.yaml
        #expect(yaml.contains("listen: \"127.0.0.1:41001\""))
        #expect(yaml.contains("listen: \"127.0.0.1:41002\""))
        #expect(!yaml.contains("0.0.0.0") && !yaml.contains(":8554") && !yaml.contains(":1984") && !yaml.contains(":8555"))
        #expect(yaml.contains("'cb-abc': '${CB_SRC_0}'"))
        #expect(yaml.contains("password: '${CB_API_PASSWORD}'") && yaml.contains("local_auth: true"))
        #expect(yaml.contains("allow_paths: [/api, /api/streams]"))
    }

    @Test func dangerousModulesNeverStart() {
        for modules in [Go2RTCConfig.servingModules, Go2RTCConfig.setupModules] {
            for forbidden in ["exec", "echo", "expr", "ffmpeg", "ngrok", "pinggy", "hass", "homekit", "webtorrent", "webrtc", "mqtt", "debug"] {
                #expect(!modules.contains(forbidden), "\(forbidden)")
            }
        }
        #expect(Go2RTCConfig.servingModules.contains("rtsp") && !Go2RTCConfig.setupModules.contains("rtsp"))
        #expect(Go2RTCConfig(apiPort: 1, rtspPort: 2).yaml.contains("modules: [api, rtsp, ring, nest, tuya, wyze, tapo, doorbird, dvrip, xiaomi]"))
    }

    @Test func setupConfigurationHasNoRTSPServerAndNoPassword() {
        let yaml = Go2RTCConfig(apiPort: 5000, rtspPort: nil, modules: Go2RTCConfig.setupModules, apiPaths: Go2RTCConfig.setupAPIPaths,
                                requiresAPIPassword: false).yaml
        #expect(!yaml.contains("rtsp:") && !yaml.contains("password"))
        #expect(yaml.contains("streams: {}"))
    }

    @Test func streamNamesAndEnvironmentValues() {
        #expect(Go2RTCConfig.isValidStreamName("cb-0a1b2c3d-1111-2222-3333-444455556666"))
        for bad in ["", "a b", "a/b", "a'b", "a\nb", "a:b", String(repeating: "a", count: 81)] { #expect(!Go2RTCConfig.isValidStreamName(bad)) }
        #expect(Go2RTCConfig.environmentValue(forSource: "tuya://h?password=it's") == "tuya://h?password=it''s")
        #expect(Go2RTCConfig.randomPassword().count == 64)
        #expect(Go2RTCConfig.randomPassword() != Go2RTCConfig.randomPassword())
    }
}
