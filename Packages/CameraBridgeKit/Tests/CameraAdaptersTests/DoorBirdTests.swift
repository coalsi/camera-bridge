// DoorBird LAN API: info parsing, the event monitor's lines (Fixtures/doorbird, written from DoorBird's public LAN API document), the
// mapper, and the driver against a loopback device (macOS only).
import BridgeSupport
import Foundation
import MediaCore
import RTSP
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct DoorBirdParsingTests {
    @Test func infoFromTheDocumentedShape() throws {
        let info = try DoorBirdInfo.parse(try fixture("doorbird/info.json"))
        #expect(info.deviceType == "DoorBird D2101V" && info.firmware == "000125" && info.build == "15870439")
        #expect(info.macAddress == "1CCAE3700000" && info.relays == ["1", "2", "gggaaa@1"])
        // Older firmware: only firmware and build.
        let old = try DoorBirdInfo.parse(Data(#"{"BHA":{"RETURNCODE":"1","VERSION":[{"FIRMWARE":"000108","BUILD_NUMBER":"1"}]}}"#.utf8))
        #expect(old.deviceType == "DoorBird" && old.relays.isEmpty && old.macAddress.isEmpty)
    }

    @Test func infoErrors() {
        // A refusal with a version in it is still a refusal.
        #expect(throws: CameraAdapterError.self) {
            try DoorBirdInfo.parse(Data(#"{"BHA":{"RETURNCODE":"0","VERSION":[{"FIRMWARE":"1"}]}}"#.utf8))
        }
        for text in ["", "not json", "{}", #"{"BHA":{"RETURNCODE":"0"}}"#, #"{"BHA":{"RETURNCODE":"1","VERSION":[]}}"#, #"[1,2]"#] {
            #expect(throws: CameraAdapterError.self, "\(text)") { try DoorBirdInfo.parse(Data(text.utf8)) }
        }
    }

    @Test func monitorLines() {
        #expect(DoorBirdMonitorLine.parse("doorbell:H") == .doorbell(active: true))
        #expect(DoorBirdMonitorLine.parse("doorbell:L\r") == .doorbell(active: false))
        #expect(DoorBirdMonitorLine.parse(" motionsensor:H ") == .motion(active: true))
        #expect(DoorBirdMonitorLine.parse("MotionSensor:l") == .motion(active: false))
        for text in ["", "--ioboundary", "Content-Type: text/plain", "doorbell", "doorbell:X", "rfid:H", ":H"] {
            #expect(DoorBirdMonitorLine.parse(text) == nil, "\(text)")
        }
    }

    @Test func recordedMonitorStreamInAnyChunking() throws {
        let data = try fixture("doorbird/monitor.txt")
        let expected: [DoorBirdMonitorLine] = [.doorbell(active: true), .motion(active: true), .doorbell(active: false), .motion(active: false)]
        for chunk in [1, 5, 17, data.count] {
            var parser = DoorBirdMonitorParser()
            var lines: [DoorBirdMonitorLine] = []
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + chunk)
                lines += parser.feed(data[offset..<end])
                offset = end
            }
            #expect(lines == expected, "chunk \(chunk)")
        }
    }

    @Test func mapper() {
        #expect(DoorBirdEventMapper.signals(for: .doorbell(active: true), motionHold: .seconds(20)) == [.ring])
        #expect(DoorBirdEventMapper.signals(for: .doorbell(active: false), motionHold: .seconds(20)).isEmpty)
        #expect(DoorBirdEventMapper.signals(for: .motion(active: true), motionHold: .seconds(20)) == [.activate(.motion, source: "motionsensor", hold: .seconds(20))])
        #expect(DoorBirdEventMapper.signals(for: .motion(active: false), motionHold: .seconds(20)).isEmpty)
    }

    @Test func statusMapping() {
        func check(_ status: Int) throws { try DoorBirdAPI.check(status: status, key: "doorbird-test-\(status):80", hasCredentials: true) }
        #expect(throws: Never.self) { try check(200) }
        #expect(throws: CameraAdapterError.unauthorized) { try check(401) }
        #expect(throws: CameraAdapterError.self) { try check(204) }
        #expect(throws: CameraAdapterError.httpStatus(503)) { try check(503) }
        do {
            try check(423)
            Issue.record("423 accepted")
        } catch let CameraAdapterError.lockedOut(until) {
            #expect(until > Date())
        } catch {
            Issue.record("wrong error \(error)")
        }
        for status in [401, 423] { ONVIFLoginGuard.shared.clear(host: "doorbird-test-\(status):80") }
    }
}

#if os(macOS) || os(Linux)

final class MockDoorBird: Sendable {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let server: MockHTTPServer
    let monitorBody = Box(Data())
    let monitorConnections = Box(0)
    let monitorTargets = Box<[String]>([])
    let imageStatus = Box(200)
    let rejectAll = Box(false)
    let status423 = Box(false)
    let loginAttempts = Box(0)

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)) }

    private init(server: MockHTTPServer) { self.server = server }

    static func start() async throws -> MockDoorBird {
        let box = Box<MockDoorBird?>(nil)
        let server = try await MockHTTPServer.start { request in
            guard let device = box.value else { return .status(503) }
            return device.handle(request)
        }
        let device = MockDoorBird(server: server)
        box.set(device)
        return device
    }

    func stop() {
        ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(server.port)")
        server.stop()
    }

    private func handle(_ request: MockRequest) -> MockResponse {
        let authorization = request.head.headers["Authorization"]
        guard !rejectAll.value, isDigestAuthorization(authorization, username: "ghikzi0001") else {
            if authorization != nil { loginAttempts.update { $0 += 1 } }
            return status423.value && authorization != nil ? .status(423) : .digestChallenge()
        }
        switch request.path {
        case "/bha-api/info.cgi":
            return .json((try? fixtureText("doorbird/info.json")) ?? "{}")
        case "/bha-api/image.cgi":
            return imageStatus.value == 200 ? .full(status: 200, headers: [("Content-Type", "image/jpeg")], body: Self.jpeg) : .status(imageStatus.value)
        case "/bha-api/monitor.cgi":
            monitorConnections.update { $0 += 1 }
            monitorTargets.update { $0.append(request.head.target) }
            return .stream(status: 200, headers: [("Content-Type", "multipart/x-mixed-replace; boundary=--ioboundary")]) { [monitorBody] writer in
                await writer.write(monitorBody.value)
                try? await Task.sleep(for: .seconds(30))
            }
        default:
            return .status(404)
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct DoorBirdDriverTests {
    private let credentials = HTTPCredentials(username: "ghikzi0001", password: "pa55")
    private let info = RTSPSessionInfo(tracks: [], videoFormat: VideoFormat(codec: .h264, width: 1280, height: 720, parameterSets: []),
                                       audioFormat: AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))

    private func timing(session: Duration = .seconds(60)) -> DoorBirdEventTiming {
        var timing = DoorBirdEventTiming()
        timing.motionHold = .milliseconds(300)
        timing.maximumSession = session
        timing.policy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(20), maximum: .milliseconds(50), jitter: 0), healthyAfter: .milliseconds(30))
        return timing
    }

    private func driver(_ device: MockDoorBird, factory: FakeRTSPFactory? = nil, timing: DoorBirdEventTiming? = nil) -> DoorBirdDriver {
        DoorBirdDriver(endpoint: device.endpoint, credentials: credentials, mainStreamURL: nil, transport: PlatformNetworkTransport(),
                       rtspFactory: (factory ?? FakeRTSPFactory(FakeRTSPSession(info: info))).factory, timing: timing ?? self.timing())
    }

    @Test func probePrefersTheHDStreamAndDescribesTheDevice() async throws {
        let device = try await MockDoorBird.start()
        defer { device.stop() }
        let factory = FakeRTSPFactory(FakeRTSPSession(info: info))
        let result = try await driver(device, factory: factory).probe()
        #expect(result.vendor == .doorbird && result.manufacturer == "DoorBird" && result.model == "DoorBird D2101V")
        #expect(result.serialNumber == "1CCAE3700000" && result.firmware == "000125")
        #expect(result.mainStream?.url.absoluteString == "rtsp://127.0.0.1:554/mpeg/720p/media.amp")
        #expect(result.capabilities.isDoorbell && result.capabilities.events == [.motion, .doorbell] && result.capabilities.snapshotAPI)
        #expect(!result.capabilities.twoWayAudio)
        #expect(factory.configurations.value.count == 1 && factory.configurations.value[0].credentials == credentials)
    }

    @Test func probeFallsBackToTheDefaultStreamOnOlderFirmware() async throws {
        let device = try await MockDoorBird.start()
        defer { device.stop() }
        let factory = FakeRTSPFactory(makeFor: { [info] configuration in
            configuration.url.path.contains("720p") ? FakeRTSPSession(info: nil, error: RTSPError.notFound) : FakeRTSPSession(info: info)
        })
        let result = try await driver(device, factory: factory).probe()
        #expect(result.mainStream?.url.path == "/mpeg/media.amp")
        #expect(factory.configurations.value.map(\.url.path) == ["/mpeg/720p/media.amp", "/mpeg/media.amp"])
        // Neither works: the last failure is the answer.
        let none = FakeRTSPFactory(FakeRTSPSession(info: nil, error: RTSPError.timeout))
        await #expect(throws: RTSPError.timeout) { try await driver(device, factory: none).probe() }
    }

    @Test func aWrongPasswordStopsAtTheFirstRequestAndTheGuardHoldsTheRest() async throws {
        let device = try await MockDoorBird.start()
        defer { device.stop() }
        device.rejectAll.set(true)
        let bad = driver(device)
        await #expect(throws: CameraAdapterError.unauthorized) { try await bad.probe() }
        let attempts = device.loginAttempts.value
        await #expect(throws: CameraAdapterError.self) { try await bad.probe() }
        await #expect(throws: CameraAdapterError.self) { _ = try await bad.snapshot() }
        let source = try #require(bad.makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.authenticationFailed) })
        await source.stop()
        #expect(device.loginAttempts.value == attempts && device.monitorConnections.value == 0)
    }

    @Test func aBlockedAddressIsLockedOutNotRetried() async throws {
        let device = try await MockDoorBird.start()
        defer { device.stop() }
        device.status423.set(true)
        device.rejectAll.set(true)
        let blocked = driver(device)
        do {
            _ = try await blocked.probe()
            Issue.record("probe passed")
        } catch CameraAdapterError.lockedOut(let until) {
            #expect(until > Date())
        } catch CameraAdapterError.unauthorized {
            // The first answer to the Digest retry; either way no further attempt follows.
        }
        let attempts = device.loginAttempts.value
        await #expect(throws: CameraAdapterError.self) { try await blocked.probe() }
        #expect(device.loginAttempts.value == attempts)
    }

    @Test func snapshotAnd204WithoutPermission() async throws {
        let device = try await MockDoorBird.start()
        defer { device.stop() }
        #expect(try await driver(device).snapshot() == MockDoorBird.jpeg)
        device.imageStatus.set(204)
        await #expect(throws: CameraAdapterError.self) { _ = try await driver(device).snapshot() }
    }

    @Test func monitorEventsRingAndMotion() async throws {
        let device = try await MockDoorBird.start()
        defer { device.stop() }
        device.monitorBody.set(try fixture("doorbird/monitor.txt"))
        let source = try #require(driver(device).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.doorbellPressed) && $0.contains(.motion(true)) && $0.contains(.motion(false)) })
        await source.stop()
        #expect(recorder.values.first == .eventChannel(connected: true))
        #expect(recorder.values.filter { $0 == .doorbellPressed }.count == 1)
        #expect(device.monitorTargets.value.first == "/bha-api/monitor.cgi?ring=doorbell,motionsensor")
    }

    @Test func theMonitorIsRestartedBeforeItCanGoStale() async throws {
        let device = try await MockDoorBird.start()
        defer { device.stop() }
        let source = try #require(driver(device, timing: timing(session: .milliseconds(150))).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await eventually(timeout: .seconds(5)) { device.monitorConnections.value >= 3 })
        await source.stop()
        // A planned restart is not a failure: no authentication problem, no unreliable-channel report.
        #expect(!recorder.values.contains(.authenticationFailed))
        #expect(!recorder.values.contains { if case .eventChannelUnreliable = $0 { true } else { false } })
    }
}
#endif
