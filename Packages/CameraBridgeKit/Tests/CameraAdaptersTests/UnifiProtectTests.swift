// UniFi Protect: the official Integration API (camera list, RTSPS streams, snapshots with an API key), the events WebSocket's messages
// (Fixtures/unifi, written from Ubiquiti's published API description), and the driver with a fake go2rtc helper (macOS only).
import BridgeSupport
import Foundation
import MediaCore
import RTSP
import TestSupport
import Testing
@testable import CameraAdapters

/// A go2rtc helper that serves no one: it records what drivers ask of it.
actor FakeGo2RTCProvider: Go2RTCStreamProviding {
    private(set) var attached: [(streamID: String, source: Go2RTCSource)] = []
    private(set) var detached: [String] = []
    var failure: (any Error)?
    var problemLines: [String] = []
    var port = 8554

    func setFailure(_ error: (any Error)?) { failure = error }
    func setProblems(_ lines: [String]) { problemLines = lines }

    func attach(streamID: String, source: Go2RTCSource) async throws -> URL {
        if let failure { throw failure }
        attached.append((streamID, source))
        return URL(string: "rtsp://127.0.0.1:\(port)/\(streamID)")!
    }

    func detach(streamID: String) async { detached.append(streamID) }
    func problems(streamID: String) async -> [String] { problemLines }
}

@Suite(.timeLimit(.minutes(1))) struct UnifiProtectParsingTests {
    private let doorbell = "66d025b301ebc903e80003ea"

    @Test func cameraList() throws {
        let cameras = try UnifiCamera.parseList(try fixture("unifi/cameras.json"))
        #expect(cameras.map(\.name) == ["Front Door", "Garage"])
        #expect(cameras[0].isDoorbell && cameras[0].isConnected && cameras[0].mac == "E063DA000001" && cameras[0].type == "UVC G4 Doorbell Pro")
        #expect(!cameras[1].isDoorbell && !cameras[1].isConnected)
        #expect(throws: CameraAdapterError.self) { try UnifiCamera.parseList(Data("{}".utf8)) }
        #expect(try UnifiCamera.parseList(Data(#"[{"name":"no id"},{"id":""},{"id":"x"}]"#.utf8)).map(\.id) == ["x"])
    }

    @Test func streamURLsByQuality() throws {
        let data = try fixture("unifi/rtsps-stream.json")
        #expect(UnifiProtectAPI.streamURL(in: data, quality: "high") == "rtsps://192.0.2.10:7441/5nPr7RCmueGTKMP7?enableSrtp")
        #expect(UnifiProtectAPI.streamURL(in: data, quality: "medium") == nil)   // null: not enabled
        #expect(UnifiProtectAPI.streamURL(in: data, quality: "package") == nil)
        #expect(UnifiProtectAPI.streamURL(in: Data("nope".utf8), quality: "high") == nil)
    }

    @Test func messagesParse() throws {
        let lines = try fixtureText("unifi/events.jsonl").split(separator: "\n").map(String.init)
        let messages = lines.compactMap(UnifiEventMessage.parse)
        #expect(messages.count == 6)
        #expect(messages[0].eventType == "ring" && messages[0].messageType == "add" && !messages[0].hasEnded)
        #expect(messages[2].smartDetectTypes == ["person", "package"])
        #expect(messages[3].hasEnded && messages[3].eventType.isEmpty)
        for text in ["", "nonsense", "{}", #"{"type":"add","item":{"modelKey":"camera","id":"x"}}"#, #"{"type":"add","item":{}}"#] {
            #expect(UnifiEventMessage.parse(text) == nil, "\(text)")
        }
    }

    @Test func trackerTurnsTheRecordedSessionIntoSignals() throws {
        var tracker = UnifiEventTracker(maximumHold: .seconds(120))
        var all: [[EventSignal]] = []
        for line in try fixtureText("unifi/events.jsonl").split(separator: "\n") {
            guard let message = UnifiEventMessage.parse(String(line)), message.device == doorbell else { continue }
            all.append(tracker.signals(for: message))
        }
        #expect(all.count == 5)   // the Garage's event is another camera's
        #expect(all[0] == [.ring])
        #expect(all[1] == [.activate(.motion, source: "protect:ev-motion", hold: .seconds(120))])
        #expect(all[2] == [.activate(.motion, source: "protect:ev-smart", hold: .seconds(120)),
                           .activate(.object(.person), source: "protect:ev-smart", hold: .seconds(120)),
                           .activate(.object(.package), source: "protect:ev-smart", hold: .seconds(120))])
        // The update that ends the smart event carries no types: what it turned on is turned off.
        #expect(all[3] == [.deactivate(.motion, source: "protect:ev-smart"), .deactivate(.object(.person), source: "protect:ev-smart"),
                           .deactivate(.object(.package), source: "protect:ev-smart")])
        #expect(all[4] == [.deactivate(.motion, source: "protect:ev-motion")])
    }

    @Test func updatesRefreshTheHoldAndRingsAreOncePerEvent() {
        var tracker = UnifiEventTracker(maximumHold: .seconds(60))
        let add = UnifiEventMessage(messageType: "add", id: "e", eventType: "motion", device: "d", smartDetectTypes: [], hasEnded: false)
        var update = add
        update.messageType = "update"
        #expect(tracker.signals(for: add).count == 1 && tracker.signals(for: update).count == 1)
        let ring = UnifiEventMessage(messageType: "add", id: "r", eventType: "ring", device: "d", smartDetectTypes: [], hasEnded: false)
        var ringUpdate = ring
        ringUpdate.messageType = "update"
        #expect(tracker.signals(for: ring) == [.ring] && tracker.signals(for: ringUpdate).isEmpty)
        // The end of an event this session never saw (the socket reconnected meanwhile) still switches motion off for that event.
        let unseen = UnifiEventMessage(messageType: "update", id: "gone", eventType: "", device: "d", smartDetectTypes: [], hasEnded: true)
        #expect(tracker.signals(for: unseen) == [.deactivate(.motion, source: "protect:gone")])
        let sensor = UnifiEventMessage(messageType: "add", id: "s", eventType: "sensorOpened", device: "d", smartDetectTypes: [], hasEnded: false)
        #expect(tracker.signals(for: sensor).isEmpty)
        let other = UnifiEventMessage(messageType: "add", id: "o", eventType: "smartDetectZone", device: "d", smartDetectTypes: ["licensePlate", "animal"], hasEnded: false)
        #expect(tracker.signals(for: other).contains(.activate(.object(.animal), source: "protect:o", hold: .seconds(60))))
    }

    @Test func holdStateMakesBalancedEventsOfTheSession() async throws {
        let events = Box<[CameraEvent]>([])
        let state = EventHoldState(ringDedupe: .seconds(3)) { event in events.update { $0.append(event) } }
        var tracker = UnifiEventTracker()
        for line in try fixtureText("unifi/events.jsonl").split(separator: "\n") {
            guard let message = UnifiEventMessage.parse(String(line)), message.device == doorbell else { continue }
            await state.apply(tracker.signals(for: message))
        }
        #expect(events.value.first == .doorbellPressed)
        #expect(events.value.contains(.motion(true)) && events.value.last == .motion(false))
        #expect(events.value.contains(.object(.person, true)) && events.value.contains(.object(.person, false)))
        await state.cancelAll()
    }
}

#if os(macOS)
import PlatformApple

final class MockProtectConsole: Sendable {
    let server: MockHTTPServer
    let apiKey = "KEY-4711"
    let rtspsRequests = Box<[String]>([])
    let existingStream = Box(false)
    let snapshotStatus = Box(200)
    let keysSeen = Box<[String?]>([])

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port), useHTTPS: false) }

    private init(server: MockHTTPServer) { self.server = server }

    static func start() async throws -> MockProtectConsole {
        let box = Box<MockProtectConsole?>(nil)
        let server = try await MockHTTPServer.start { request in
            guard let console = box.value else { return .status(503) }
            return console.handle(request)
        }
        let console = MockProtectConsole(server: server)
        box.set(console)
        return console
    }

    func stop() { server.stop() }

    private func handle(_ request: MockRequest) -> MockResponse {
        keysSeen.update { $0.append(request.head.headers["X-API-KEY"]) }
        guard request.head.headers["X-API-KEY"] == apiKey else { return .json(#"{"error":"Unauthorized","name":"API_ERROR"}"#, status: 401) }
        let base = "/proxy/protect/integration/v1"
        switch (request.method, request.path) {
        case ("GET", base + "/meta/info"): return .json(#"{"applicationVersion":"7.3.70"}"#)
        case ("GET", base + "/cameras"): return .json((try? fixtureText("unifi/cameras.json")) ?? "[]")
        case ("GET", base + "/cameras/66d025b301ebc903e80003ea/rtsps-stream"):
            return existingStream.value ? .json((try? fixtureText("unifi/rtsps-stream.json")) ?? "{}") : .json(#"{"high":null,"medium":null,"low":null}"#)
        case ("POST", base + "/cameras/66d025b301ebc903e80003ea/rtsps-stream"):
            rtspsRequests.update { $0.append(request.bodyText) }
            return .json((try? fixtureText("unifi/rtsps-stream.json")) ?? "{}")
        case ("GET", base + "/cameras/66d025b301ebc903e80003ea/snapshot"):
            return snapshotStatus.value == 200 ? .full(status: 200, headers: [("Content-Type", "image/jpeg")], body: Data([0xFF, 0xD8, 0xFF, 0xD9]))
                : .status(snapshotStatus.value)
        default: return .status(404)
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct UnifiProtectDriverTests {
    private let cameraID = "66d025b301ebc903e80003ea"
    private let info = RTSPSessionInfo(tracks: [], videoFormat: VideoFormat(codec: .h264, width: 2688, height: 1512, parameterSets: []),
                                       audioFormat: AudioFormat(codec: .aac, sampleRate: 48_000, channels: 1))

    private func driver(_ console: MockProtectConsole, provider: FakeGo2RTCProvider? = nil, key: String? = nil, camera: String? = nil,
                        factory: FakeRTSPFactory? = nil, cameraUUID: UUID? = nil) -> UnifiProtectDriver {
        UnifiProtectDriver(endpoint: console.endpoint, credentials: HTTPCredentials(username: "", password: key ?? console.apiKey),
                           settings: IntegrationSettings(service: .unifiProtect, details: [IntegrationSettings.Key.protectCameraID: camera ?? cameraID]),
                           provider: provider ?? FakeGo2RTCProvider(), rtspFactory: (factory ?? FakeRTSPFactory(FakeRTSPSession(info: info))).factory,
                           cameraID: cameraUUID, useHTTPS: false)
    }

    @Test func listingCamerasForTheWizard() async throws {
        let console = try await MockProtectConsole.start()
        defer { console.stop() }
        let cameras = try await UnifiProtectAPI.listCameras(endpoint: console.endpoint, apiKey: "  \(console.apiKey)\n", useHTTPS: false)
        #expect(cameras.map(\.name) == ["Front Door", "Garage"] && cameras[0].isDoorbell && !cameras[1].isConnected)
        #expect(console.keysSeen.value.allSatisfy { $0 == console.apiKey }, "the key goes in X-API-KEY, trimmed")
        await #expect(throws: CameraAdapterError.unauthorized) {
            _ = try await UnifiProtectAPI.listCameras(endpoint: console.endpoint, apiKey: "wrong", useHTTPS: false)
        }
    }

    @Test func probeAsksForTheStreamHandsItToTheHelperAndDescribesTheLocalAddress() async throws {
        let console = try await MockProtectConsole.start()
        defer { console.stop() }
        let provider = FakeGo2RTCProvider()
        let factory = FakeRTSPFactory(FakeRTSPSession(info: info))
        let uuid = UUID()
        let result = try await driver(console, provider: provider, factory: factory, cameraUUID: uuid).probe()
        #expect(console.rtspsRequests.value == [#"{"qualities":["high"]}"#])
        let attached = await provider.attached
        #expect(attached.count == 1 && attached[0].streamID == Go2RTCManager.streamName(for: uuid))
        // The console's own address is replaced by the one the person gave; `?enableSrtp` is gone; it is go2rtc's TLS RTSP.
        #expect(attached[0].source.url == "rtspx://127.0.0.1:7441/5nPr7RCmueGTKMP7")
        #expect(factory.configurations.value.first?.url.absoluteString == "rtsp://127.0.0.1:8554/\(Go2RTCManager.streamName(for: uuid))")
        #expect(factory.configurations.value.first?.credentials == nil, "the helper's RTSP asks for nothing")
        #expect(result.vendor == .unifi && result.manufacturer == "Ubiquiti" && result.model == "UVC G4 Doorbell Pro")
        #expect(result.serialNumber == "E063DA000001" && result.firmware == "Protect 7.3.70")
        #expect(result.mainStream?.width == 2688 && result.capabilities.isDoorbell && result.capabilities.events.contains(.doorbell))
        #expect(result.capabilities.snapshotAPI && !result.capabilities.twoWayAudio)
    }

    @Test func anExistingStreamIsReusedAndNoNewOneCreated() async throws {
        let console = try await MockProtectConsole.start()
        defer { console.stop() }
        console.existingStream.set(true)
        let provider = FakeGo2RTCProvider()
        let url = try await driver(console, provider: provider).attachStreams()
        #expect(console.rtspsRequests.value.isEmpty)
        #expect(url.host() == "127.0.0.1" && url.port == 8554)
    }

    @Test func problemsAreSaidInPlainWords() async throws {
        let console = try await MockProtectConsole.start()
        defer { console.stop() }
        await #expect(throws: CameraAdapterError.unauthorized) { try await driver(console, key: "wrong").probe() }
        await #expect(throws: IntegrationError.self) { try await driver(console, camera: "missing").probe() }
        await #expect(throws: IntegrationError.self) { try await driver(console, camera: "672094f900e26303e800062a").probe() }   // not connected
        await #expect(throws: IntegrationError.self) { try await driver(console, key: "").probe() }
        let helperless = UnifiProtectDriver(endpoint: console.endpoint, credentials: HTTPCredentials(username: "", password: console.apiKey),
                                            settings: IntegrationSettings(service: .unifiProtect, details: [IntegrationSettings.Key.protectCameraID: cameraID]),
                                            provider: nil, rtspFactory: FakeRTSPFactory(FakeRTSPSession(info: info)).factory, useHTTPS: false)
        await #expect(throws: IntegrationError.self) { try await helperless.probe() }
        let noHelper = FakeGo2RTCProvider()
        await noHelper.setFailure(Go2RTCError.helperMissing)
        await #expect(throws: Go2RTCError.helperMissing) { try await driver(console, provider: noHelper).probe() }
    }

    @Test func aStreamThatFailsInTheHelperExplainsWhatTheHelperSaid() async throws {
        let console = try await MockProtectConsole.start()
        defer { console.stop() }
        let provider = FakeGo2RTCProvider()
        await provider.setProblems(["[streams] error=\"rtspx: dial tcp: connection refused\""])
        let failing = FakeRTSPFactory(FakeRTSPSession(info: nil, error: RTSPError.notFound))
        do {
            _ = try await driver(console, provider: provider, factory: failing).probe()
            Issue.record("probe passed")
        } catch let error as IntegrationError {
            #expect(error.message.contains("UniFi Protect") && error.message.contains("connection refused"))
        }
    }

    @Test func snapshotsEventsAndRelease() async throws {
        let console = try await MockProtectConsole.start()
        defer { console.stop() }
        let provider = FakeGo2RTCProvider()
        let uuid = UUID()
        let unifi = driver(console, provider: provider, cameraUUID: uuid)
        #expect(try await unifi.snapshot() == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        console.snapshotStatus.set(503)
        await #expect(throws: CameraAdapterError.self) { _ = try await unifi.snapshot() }
        #expect(unifi.makeEventSource() != nil && unifi.makeTalkbackSink() == nil)
        #expect(driver(console, camera: "").makeEventSource() == nil)
        await unifi.releaseStreams()
        #expect(await provider.detached == [Go2RTCManager.streamName(for: uuid)])
    }
}
#endif
