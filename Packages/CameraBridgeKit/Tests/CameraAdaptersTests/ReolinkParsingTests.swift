import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

@Suite struct ReolinkParsingTests {
    @Test func jsonValueNavigation() throws {
        let json = try JSONValue.parse(fixture("reolink/GetDevInfo-doorbell.json"))
        let info = json[0]?["value"]?["DevInfo"]
        #expect(info?["model"]?.string == "Reolink Video Doorbell WiFi")
        #expect(info?["channelNum"]?.int == 1)
        #expect(info?["missing"] == nil)
        #expect(json[5] == nil)
        #expect(throws: (any Error).self) { try JSONValue.parse(Data("{not json".utf8)) }
        let encoded = try JSONEncoder().encode(JSONValue.object(["cmd": .string("Login"), "action": .number(0)]))
        #expect(try JSONValue.parse(encoded)["cmd"]?.string == "Login")
    }

    @Test func eventStateFromGetEvents() throws {
        let value = try #require(try JSONValue.parse(fixture("reolink/GetEvents.json"))[0]?["value"])
        let state = ReolinkEventState(events: value)
        #expect(state.motion == true)
        #expect(state.visitor == false)
        #expect(state.objects == [.person: true, .vehicle: false, .animal: false, .package: false])
        #expect(state.supported == [.motion, .person, .vehicle, .animal, .package, .doorbell])
    }

    @Test func eventStateFromLegacyCommands() throws {
        let ai = try JSONValue.parse(fixture("reolink/GetAiState.json"))[0]?["value"]
        let md = JSONValue.object(["state": .number(0)])
        let state = ReolinkEventState(motionState: md, aiState: ai)
        #expect(state.motion == false)
        #expect(state.visitor == nil)
        #expect(state.objects == [.animal: true, .person: false, .vehicle: true])
        #expect(state.supported == [.motion, .person, .vehicle, .animal])
    }

    @Test func loginFirstErrorAsksForRelogin() throws {
        // What a command sent with an expired or unknown token gets back (code 1, error.rspCode -6).
        let result = try ReolinkAPI.firstResponse(fixture("reolink/Error-LoginFirst.json"), command: "GetMdState")
        guard case .failure(let code) = result else {
            Issue.record("\"please login first\" parsed as a success: \(result)")
            return
        }
        #expect(code == -6)
        #expect(ReolinkAPI.reloginCodes.contains(code))
    }

    @Test func mapperEmitsLevelsAndRisingEdgeRings() {
        var mapper = ReolinkEventMapper()
        var state = ReolinkEventState(motion: false, objects: [.person: false], visitor: true, supported: [])
        // First poll is the baseline: a visitor flag that is already set is not a new press.
        #expect(mapper.signals(for: state) == [.deactivate(.motion, source: "md"), .deactivate(.object(.person), source: "poll"),
                                               .deactivate(.motion, source: "ai")])
        state.visitor = false
        _ = mapper.signals(for: state)
        state.visitor = true
        state.motion = true
        state.objects[.person] = true
        #expect(mapper.signals(for: state) == [.activate(.motion, source: "md", hold: nil), .activate(.object(.person), source: "poll", hold: nil),
                                               .activate(.motion, source: "ai", hold: nil), .ring])
        #expect(!mapper.signals(for: state).contains(.ring))   // still pressed: no second ring
    }

    @Test func streamURLBuilders() {
        let endpoint = CameraEndpoint(host: "192.0.2.120", httpPort: 80, rtspPort: 554)
        #expect(ReolinkStreamURLs.rtsp(endpoint: endpoint)?.absoluteString == "rtsp://192.0.2.120:554/h264Preview_01_main")
        #expect(ReolinkStreamURLs.rtsp(endpoint: endpoint, main: false)?.absoluteString == "rtsp://192.0.2.120:554/h264Preview_01_sub")
        #expect(ReolinkStreamURLs.rtsp(endpoint: endpoint, channel: 1, hevc: true)?.absoluteString == "rtsp://192.0.2.120:554/h265Preview_02_main")
        #expect(ReolinkStreamURLs.flv(endpoint: endpoint)?.absoluteString
                == "http://192.0.2.120:80/flv?port=1935&app=bcs&stream=channel0_main.bcs")
        #expect(ReolinkStreamURLs.flv(endpoint: endpoint, main: false)?.absoluteString
                == "http://192.0.2.120:80/flv?port=1935&app=bcs&stream=channel0_sub.bcs")
        let secret = ReolinkStreamURLs.flv(endpoint: endpoint, credentials: HTTPCredentials(username: "admin", password: "p@ss&1"))
        #expect(secret?.absoluteString == "http://192.0.2.120:80/flv?port=1935&app=bcs&stream=channel0_main.bcs&user=admin&password=p%40ss%261")
        #expect(secret.map(Redact.url)?.contains("p@ss") == false)
    }
}
