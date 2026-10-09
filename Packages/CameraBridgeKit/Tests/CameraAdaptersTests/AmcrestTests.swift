// Amcrest / Dahua: the event stream parser and mapper (recorded-style payloads written from the public descriptions in
// Fixtures/amcrest), and the driver against a loopback camera (macOS only).
import BridgeSupport
import Foundation
import MediaCore
import RTSP
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct AmcrestEventParsingTests {
    private func parse(_ fixtureName: String, chunk: Int = .max, crlf: Bool = false) throws -> [AmcrestEventStreamParser.Item] {
        var text = try fixtureText(fixtureName)
        if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        var parser = AmcrestEventStreamParser()
        var items: [AmcrestEventStreamParser.Item] = []
        let data = Data(text.utf8)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset &+ chunk)
            items += parser.feed(data[offset..<end])
            offset = end
        }
        return items
    }

    @Test func motionStreamWithHeartbeat() throws {
        let items = try parse("amcrest/events-motion.txt")
        #expect(items == [.event(AmcrestEvent(code: "VideoMotion", action: "Start", index: 0, data: nil)), .heartbeat,
                          .event(AmcrestEvent(code: "VideoMotion", action: "Stop", index: 0, data: nil))])
    }

    @Test func framingDoesNotMatter() throws {
        let plain = try parse("amcrest/events-ivs.txt")
        #expect(plain.count == 3)
        // CRLF lines, and every chunk size down to one byte: the same events.
        #expect(try parse("amcrest/events-ivs.txt", crlf: true) == plain)
        for chunk in [1, 2, 7, 64] { #expect(try parse("amcrest/events-ivs.txt", chunk: chunk) == plain, "chunk \(chunk)") }
        // Devices without the multipart envelope: bare lines.
        var parser = AmcrestEventStreamParser()
        let bare = parser.feed(Data("Code=VideoMotion;action=Start;index=0\nHeartbeat\nCode=VideoMotion;action=Stop;index=0\n".utf8))
        #expect(bare.count == 3)
    }

    @Test func multiLineJSONWithSemicolonsBracesAndQuotes() throws {
        let items = try parse("amcrest/events-ivs.txt")
        guard case .event(let line) = items[0] else { Issue.record("no event"); return }
        #expect(line.code == "CrossLineDetection" && line.isStart && line.index == 0)
        #expect(line.data?["Name"]?.string == "Rule; with {braces} and \"quotes\"")
        #expect(line.data?["Object"]?["ObjectType"]?.string == "Human")
        #expect(line.data?["RuleId"]?.int == 1)
        guard case .event(let vehicle) = items[1] else { Issue.record("no event"); return }
        #expect(vehicle.code == "SmartMotionVehicle" && vehicle.data?["RegionName"]?[0]?.string == "Region1")
        guard case .event(let stop) = items[2] else { Issue.record("no event"); return }
        #expect(stop.isStop)
    }

    /// Braces inside a JSON string (a rule named by the user) do not count towards where the data block ends.
    @Test func bracesInsideStringsDoNotEndOrExtendTheBlock() {
        var parser = AmcrestEventStreamParser()
        let items = parser.feed(Data("Code=CrossLineDetection;action=Start;index=0;data={\n \"Name\" : \"open { brace\",\n \"Other\" : \"close } \\\" } brace\"\n}\nHeartbeat\n".utf8))
        #expect(items.count == 2)
        guard case .event(let event) = items[0] else { Issue.record("no event"); return }
        #expect(event.data?["Name"]?.string == "open { brace" && event.data?["Other"]?.string == "close } \" } brace")
        #expect(items[1] == .heartbeat)
    }

    @Test func garbageAndEndlessLinesAreHarmless() {
        var parser = AmcrestEventStreamParser()
        #expect(parser.feed(Data("\u{0}\u{1}\u{2}garbage\n\n---\nCode=\nCode=;action=Start\nCode=Foo;action=Start;index=x\n".utf8)).count == 1)
        let big = Data(repeating: 0x41, count: AmcrestEventStreamParser.maximumLine + 10)
        #expect(parser.feed(big).isEmpty)
        #expect(parser.feed(Data("\nCode=VideoMotion;action=Start;index=2\n".utf8)).count == 1)
        // A data block that never closes does not swallow the stream forever.
        var open = AmcrestEventStreamParser()
        _ = open.feed(Data("Code=X;action=Start;index=0;data={\n".utf8))
        _ = open.feed(Data(repeating: 0x20, count: AmcrestEventStreamParser.maximumLine + 1))
        #expect(open.feed(Data("\nCode=VideoMotion;action=Start;index=0\n".utf8)).count == 1)
    }

    @Test func eventLineParsing() {
        let event = AmcrestEvent.parse("Code=VideoMotion;action=Start;index=2")
        #expect(event == AmcrestEvent(code: "VideoMotion", action: "Start", index: 2, data: nil))
        #expect(AmcrestEvent.parse("Heartbeat") == nil && AmcrestEvent.parse("code=x") == nil)
        #expect(AmcrestEvent.parse("Code=AudioMutation;action=Pulse")?.isPulse == true)
        #expect(AmcrestEvent.parse("Code=A;action=Start;index=0;data={not json")?.data == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct AmcrestEventMappingTests {
    private let hold = Duration.seconds(20)

    private func signals(_ line: String) -> [EventSignal] {
        AmcrestEventMapper.signals(for: AmcrestEvent.parse(line)!, pulseHold: hold)
    }

    @Test func motionIsALevelBetweenStartAndStop() {
        #expect(signals("Code=VideoMotion;action=Start;index=0") == [.activate(.motion, source: "VideoMotion", hold: nil)])
        #expect(signals("Code=VideoMotion;action=Stop;index=0") == [.deactivate(.motion, source: "VideoMotion")])
        #expect(signals("Code=VideoMotion;action=Pulse;index=0") == [.activate(.motion, source: "VideoMotion", hold: hold)])
    }

    @Test func smartDetectionsAreObjectsAndMotion() {
        #expect(signals("Code=SmartMotionHuman;action=Start;index=0")
            == [.activate(.object(.person), source: "SmartMotionHuman", hold: nil), .activate(.motion, source: "SmartMotionHuman", hold: nil)])
        #expect(signals("Code=SmartMotionVehicle;action=Stop;index=0")
            == [.deactivate(.object(.vehicle), source: "SmartMotionVehicle"), .deactivate(.motion, source: "SmartMotionVehicle")])
        let human = signals(#"Code=CrossLineDetection;action=Start;index=0;data={"Object":{"ObjectType":"Human"}}"#)
        #expect(human.contains(.activate(.object(.person), source: "CrossLineDetection", hold: hold)))
        #expect(human.contains(.activate(.motion, source: "CrossLineDetection", hold: hold)))
        let car = signals(#"Code=CrossRegionDetection;action=Start;index=0;data={"Object":{"ObjectType":"Vehicle"}}"#)
        #expect(car.contains(.activate(.object(.vehicle), source: "CrossRegionDetection", hold: hold)))
        let unknown = signals(#"Code=CrossLineDetection;action=Start;index=0;data={"Object":{"ObjectType":"Unknown"}}"#)
        #expect(unknown == [.activate(.motion, source: "CrossLineDetection", hold: hold)])
        #expect(signals("Code=FaceDetection;action=Pulse;index=0").contains(.activate(.object(.face), source: "FaceDetection", hold: hold)))
    }

    @Test func tamperAudioAndInputs() {
        #expect(signals("Code=VideoBlind;action=Start;index=0") == [.activate(.tamper, source: "VideoBlind", hold: nil)])
        #expect(signals("Code=VideoBlind;action=Stop;index=0") == [.deactivate(.tamper, source: "VideoBlind")])
        #expect(signals("Code=AudioMutation;action=Pulse;index=0") == [.activate(.audioAlarm, source: "AudioMutation", hold: hold)])
        #expect(signals("Code=AlarmLocal;action=Start;index=1") == [.activate(.digitalInput("2"), source: "AlarmLocal", hold: nil)])
    }

    @Test func doorbellPressesRingOnceAndNothingElseDoes() throws {
        #expect(signals("Code=CallNoAnswered;action=Start;index=0") == [.ring])
        #expect(signals("Code=PhoneCallDetect;action=Pulse;index=0") == [.ring])
        #expect(signals(#"Code=_DoTalkAction_;action=Pulse;index=0;data={ "Action" : "Invite", "CallID" : "1" }"#) == [.ring])
        #expect(signals(#"Code=_DoTalkAction_;action=Pulse;index=0;data={ "Action" : "Hangup" }"#).isEmpty)
        #expect(signals(#"Code=BackKeyLight;action=Pulse;index=0;data={ "State" : 1 }"#) == [.ring])
        #expect(signals(#"Code=BackKeyLight;action=Pulse;index=0;data={ "State" : 0 }"#).isEmpty)
        #expect(signals("Code=CallNoAnswered;action=Stop;index=0").isEmpty)
        // Noise the camera also sends.
        for code in ["TimeChange", "NTPAdjustTime", "NewFile", "StorageLowSpace", "InterVideoAccess", "Unknown123"] {
            #expect(signals("Code=\(code);action=Pulse;index=0").isEmpty, "\(code)")
        }
        // The recorded doorbell stream rings for the first three events only.
        var parser = AmcrestEventStreamParser()
        let items = parser.feed(Data(try fixtureText("amcrest/events-doorbell.txt").utf8))
        let rings = items.compactMap { item -> [EventSignal]? in
            guard case .event(let event) = item else { return nil }
            return AmcrestEventMapper.signals(for: event, pulseHold: hold)
        }.filter { $0 == [.ring] }
        #expect(rings.count == 3)
    }

    @Test func holdStateTurnsSignalsIntoBalancedEvents() async throws {
        let events = Box<[CameraEvent]>([])
        let state = EventHoldState(ringDedupe: .seconds(3)) { event in events.update { $0.append(event) } }
        var parser = AmcrestEventStreamParser()
        for item in parser.feed(Data(try fixtureText("amcrest/events-motion.txt").utf8)) {
            guard case .event(let event) = item else { continue }
            await state.apply(AmcrestEventMapper.signals(for: event, pulseHold: hold))
        }
        #expect(events.value == [.motion(true), .motion(false)])
        // Two presses within the dedupe window are one ring.
        await state.apply([.ring])
        await state.apply([.ring])
        #expect(events.value.filter { $0 == .doorbellPressed }.count == 1)
        await state.cancelAll()
    }
}

#if os(macOS)
import PlatformApple

/// A loopback Amcrest camera: Digest-protected CGI, a `magicBox.cgi`, a JPEG with a vendor block, an event stream.
final class MockAmcrestCamera: Sendable {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x02, 0xFF, 0xD9])
    let server: MockHTTPServer
    let model = Box("IPC-HDW5831R-ZE")
    let deviceClass = Box<String?>("IPC")
    let eventConnections = Box(0)
    let eventQueries = Box<[String]>([])
    let eventBody = Box<Data>(Data())
    let rejectAll = Box(false)
    let loginAttempts = Box(0)

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)) }

    private init(server: MockHTTPServer) { self.server = server }

    static func start() async throws -> MockAmcrestCamera {
        let box = Box<MockAmcrestCamera?>(nil)
        let server = try await MockHTTPServer.start { request in
            guard let camera = box.value else { return .status(503) }
            return await camera.handle(request)
        }
        let camera = MockAmcrestCamera(server: server)
        box.set(camera)
        return camera
    }

    func stop() {
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(server.port)")
        server.stop()
    }

    private func handle(_ request: MockRequest) async -> MockResponse {
        let authorization = request.head.headers["Authorization"]
        guard !rejectAll.value, isDigestAuthorization(authorization) else {
            if authorization != nil { loginAttempts.update { $0 += 1 } }
            return .digestChallenge()
        }
        switch request.path {
        case "/cgi-bin/magicBox.cgi":
            switch request.query("action") {
            case "getSystemInfo":
                let text = ((try? fixtureText("amcrest/getSystemInfo.txt")) ?? "")
                    .replacingOccurrences(of: "IPC-HDW5831R-ZE", with: model.value).replacingOccurrences(of: "4X7C5A1ZAG21L3F", with: "SN12345")
                return .full(status: 200, headers: [], body: Data(text.utf8))
            case "getSoftwareVersion": return .full(status: 200, headers: [], body: Data("version=2.800.0000016.0.R,build:2020-06-05\n".utf8))
            case "getMachineName": return .full(status: 200, headers: [], body: Data("name=Front\n".utf8))
            case "getDeviceClass":
                guard let value = deviceClass.value else { return .status(404) }
                return .full(status: 200, headers: [], body: Data("class=\(value)\n".utf8))
            default: return .status(400)
            }
        case "/cgi-bin/snapshot.cgi":
            return .full(status: 200, headers: [("Content-Type", "image/jpeg")], body: Self.jpeg + Data("dhav-vendor-block".utf8))
        case "/cgi-bin/eventManager.cgi":
            eventConnections.update { $0 += 1 }
            eventQueries.update { $0.append(request.head.target) }
            return .stream(status: 200, headers: [("Content-Type", "multipart/x-mixed-replace; boundary=myboundary")]) { [eventBody] writer in
                await writer.write(eventBody.value)
                try? await Task.sleep(for: .seconds(30))
            }
        default:
            return .status(404)
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct AmcrestDriverTests {
    private let credentials = HTTPCredentials(username: "admin", password: "pa55")
    private let info = RTSPSessionInfo(tracks: [], videoFormat: VideoFormat(codec: .h264, width: 3840, height: 2160, parameterSets: []),
                                       audioFormat: AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))

    private func timing() -> AmcrestEventTiming {
        var timing = AmcrestEventTiming()
        timing.pulseHold = .milliseconds(300)
        timing.policy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(20), maximum: .milliseconds(50), jitter: 0), healthyAfter: .seconds(10))
        return timing
    }

    private func driver(_ camera: MockAmcrestCamera, factory: FakeRTSPFactory? = nil, credentials: HTTPCredentials? = nil) -> AmcrestDriver {
        AmcrestDriver(endpoint: camera.endpoint, credentials: credentials ?? self.credentials, mainStreamURL: nil, subStreamURL: nil, transport: AppleNetworkTransport(),
                      rtspFactory: (factory ?? FakeRTSPFactory(FakeRTSPSession(info: info))).factory, timing: timing())
    }

    @Test func probeReadsTheDeviceAndBothRTSPStreams() async throws {
        let camera = try await MockAmcrestCamera.start()
        defer { camera.stop() }
        let factory = FakeRTSPFactory(FakeRTSPSession(info: info))
        let result = try await driver(camera, factory: factory).probe()
        #expect(result.vendor == .amcrest)
        #expect(result.manufacturer == "Dahua" && result.model == "IPC-HDW5831R-ZE" && result.serialNumber == "SN12345")
        #expect(result.firmware == "2.800.0000016.0.R")
        #expect(result.mainStream?.url.absoluteString == "rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=0")
        #expect(result.subStream?.url.absoluteString == "rtsp://127.0.0.1:554/cam/realmonitor?channel=1&subtype=1")
        #expect(result.mainStream?.width == 3840 && result.mainStream?.audioCodec == .pcmu)
        #expect(result.capabilities.snapshotAPI && !result.capabilities.isDoorbell && !result.capabilities.twoWayAudio)
        #expect(result.capabilities.events == [.motion, .person, .vehicle, .tamper, .audioAlarm])
        #expect(factory.configurations.value.allSatisfy { $0.credentials == credentials })
    }

    @Test func doorbellsAreRecognisedByClassOrModel() async throws {
        let camera = try await MockAmcrestCamera.start()
        defer { camera.stop() }
        camera.model.set("AD410")
        let byModel = try await driver(camera).probe()
        #expect(byModel.capabilities.isDoorbell && byModel.capabilities.events.contains(.doorbell) && byModel.manufacturer == "Amcrest")
        camera.model.set("VTO2111D-P")
        camera.deviceClass.set("VTO")
        let vto = try await driver(camera).probe()
        #expect(vto.capabilities.isDoorbell && vto.manufacturer == "Dahua")
        camera.model.set("IPC-ABC")
        camera.deviceClass.set(nil)   // older firmware has no getDeviceClass
        #expect(try await !driver(camera).probe().capabilities.isDoorbell)
        #expect(AmcrestDeviceInfo(deviceType: "DB61i", serialNumber: "", firmware: "", machineName: "", deviceClass: "").isDoorbell)
        #expect(!AmcrestDeviceInfo(deviceType: "IP4M-1041", serialNumber: "", firmware: "", machineName: "", deviceClass: "").isDoorbell)
    }

    @Test func aWrongPasswordIsOneRejectedLoginThenTheGuardBlocksFurtherAttempts() async throws {
        let camera = try await MockAmcrestCamera.start()
        defer { camera.stop() }
        camera.rejectAll.set(true)
        let bad = driver(camera)
        await #expect(throws: CameraAdapterError.unauthorized) { try await bad.probe() }
        let attempts = camera.loginAttempts.value
        #expect(attempts >= 1)
        // Every later call, the event stream's included, refuses without sending anything: a camera locks the account after a few.
        await #expect(throws: CameraAdapterError.self) { try await bad.probe() }
        await #expect(throws: CameraAdapterError.self) { _ = try await bad.snapshot() }
        let source = try #require(bad.makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.authenticationFailed) })
        await source.stop()
        #expect(camera.loginAttempts.value == attempts)
        #expect(camera.eventConnections.value == 0)
    }

    @Test func snapshotCutsTheVendorBlockAfterTheJPEG() async throws {
        let camera = try await MockAmcrestCamera.start()
        defer { camera.stop() }
        #expect(try await driver(camera).snapshot() == MockAmcrestCamera.jpeg)
        #expect(AmcrestAPI.trimmedJPEG(Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9, 0xFF, 0xD9, 0x00, 0x00])) == Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9, 0xFF, 0xD9]))
    }

    @Test func eventStreamRequestAndEvents() async throws {
        let camera = try await MockAmcrestCamera.start()
        defer { camera.stop() }
        camera.eventBody.set(try fixture("amcrest/events-motion.txt") + fixture("amcrest/events-doorbell.txt"))
        let source = try #require(driver(camera).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.doorbellPressed) && $0.contains(.motion(false)) })
        await source.stop()
        let events = recorder.values
        #expect(events.first == .eventChannel(connected: true))
        #expect(events.contains(.motion(true)) && events.contains(.motion(false)))
        #expect(events.filter { $0 == .doorbellPressed }.count == 1, "three presses within the dedupe window are one ring")
        let query = try #require(camera.eventQueries.value.first)
        #expect(query.hasPrefix("/cgi-bin/eventManager.cgi?"))
        #expect(query.contains("action=attach") && query.contains("heartbeat=5"))
        #expect(query.contains("codes=%5BAll%5D") || query.contains("codes=[All]"))
    }

    @Test func aDroppedStreamReconnectsAndReleasesMotion() async throws {
        let camera = try await MockAmcrestCamera.start()
        defer { camera.stop() }
        camera.eventBody.set(Data("--myboundary\r\nContent-Type: text/plain\r\nContent-Length: 39\r\n\r\nCode=VideoMotion;action=Start;index=0\r\n\r\n".utf8))
        let source = try #require(driver(camera).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.motion(true)) })
        camera.server.dropConnections()
        // The level ends with the channel, and the next connection brings it back.
        #expect(await recorder.wait { $0.contains(.motion(false)) && $0.filter { $0 == .eventChannel(connected: true) }.count >= 2 })
        await source.stop()
        #expect(camera.eventConnections.value >= 2)
    }

    @Test func talkbackIsNotOffered() async throws {
        let camera = try await MockAmcrestCamera.start()
        defer { camera.stop() }
        #expect(driver(camera).makeTalkbackSink() == nil)
        #expect(driver(camera).vendor == .amcrest)
    }
}
#endif
