import TestSupport
@testable import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

/// A Reolink camera behind a Wi-Fi link that drops (the doorbell of 2026-10-02): its API is asked one request at a time,
/// nothing is sent while the camera answers nothing, the event channel waits instead of failing on its own clock, and a
/// clock overlay it cannot switch off is reported once as unsupported.
@Suite(.timeLimit(.minutes(1))) struct ReolinkOfflineTests {
    private let credentials = HTTPCredentials(username: "admin", password: "secret")

    /// A transport whose probes connect only to the ports in `open`.
    final class ProbeTransport: NetworkTransport {
        final class Connection: TCPConnection {
            let id = UUID()
            let localAddress = "127.0.0.1"
            let remoteAddress = "127.0.0.1"
            let isIPv6 = false
            func receive(maximumLength: Int) async throws -> Data? { nil }
            func send(_ data: Data) async throws {}
            func close() {}
        }

        let open = Box<Set<UInt16>>([])
        func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener { throw TransportError.failed("unused") }
        func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
            guard open.value.contains(port) else { throw TransportError.connectionRefused }
            return Connection()
        }
    }

    private func reachability(_ transport: ProbeTransport, camera: MockReolinkCamera) -> CameraReachability {
        var timing = CameraReachability.Timing()
        timing.probeInitial = .milliseconds(40)
        timing.probeMaximum = .milliseconds(80)
        timing.probeJitter = 0
        timing.probeTimeout = .milliseconds(100)
        return CameraReachability(host: "127.0.0.1", ports: [UInt16(camera.server.port)], transport: transport, timing: timing,
                                  log: Log(category: "ReolinkOfflineTest"))
    }

    @Test func requestsToOneCameraAreSentOneAtATimeWhicheverSessionSendsThem() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        camera.requestDelay.set(.milliseconds(40))
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try await api.command("GetDevInfo") } }
            for _ in 0..<4 { group.addTask { _ = try await api.command("GetEnc", param: .object(["channel": .number(0)])) } }
            group.addTask { _ = try await api.snapshot() }
            try await group.waitForAll()
        }
        // Whichever session sends them (the driver's, a settings change's), one camera address has one gate.
        #expect(CameraHTTPGates.gate(for: camera.endpoint) === CameraHTTPGates.gate(for: camera.endpoint))
        #expect(CameraHTTPGates.gate(for: camera.endpoint) !== CameraHTTPGates.gate(for: CameraEndpoint(host: "192.0.2.77")))
        #expect(camera.requests.value >= 10)
        #expect(camera.maxInFlight.value == 1, "\(camera.maxInFlight.value) requests were in flight at once")
    }

    @Test func nothingIsSentToACameraThatAnswersNothingAndTheApiWorksAgainOnceItAnswers() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let transport = ProbeTransport()
        let reachability = reachability(transport, camera: camera)
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials, reachability: reachability)
        _ = try await api.command("GetDevInfo")

        // The gateway answers 503 for everything (the application behind it is down): three in a row, nothing listening.
        camera.failingRequests.set(1_000)
        for _ in 0..<3 {
            await #expect(throws: CameraAdapterError.httpStatus(503)) { _ = try await api.command("GetDevInfo") }
        }
        await reachability.settled()
        #expect(reachability.isOffline)

        let before = camera.requests.value
        for _ in 0..<5 {
            await #expect(throws: CameraOfflineError.self) { _ = try await api.command("GetDevInfo") }
        }
        await #expect(throws: CameraOfflineError.self) { _ = try await api.snapshot() }
        #expect(camera.requests.value == before, "no request reached the camera while it was offline")

        camera.failingRequests.set(0)
        transport.open.set([UInt16(camera.server.port)])
        await reachability.waitUntilReachable()
        _ = try await api.command("GetDevInfo")
        reachability.reset()
    }

    @Test func gatewayErrorsFromACameraWhoseOtherPortsAnswerDoNotTakeItOffline() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let transport = ProbeTransport()
        transport.open.set([UInt16(camera.server.port)])   // the camera's TCP stack answers: it is up, an application is not
        let reachability = reachability(transport, camera: camera)
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials, reachability: reachability)
        camera.failingRequests.set(3)
        for _ in 0..<3 {
            await #expect(throws: CameraAdapterError.httpStatus(503)) { _ = try await api.command("GetDevInfo") }
        }
        await reachability.settled()
        #expect(reachability.phase == .reachable)
    }

    @Test func theEventChannelOfAnOfflineCameraSendsNothingAndStartsAtOnceWhenItIsBack() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let transport = ProbeTransport()
        let reachability = reachability(transport, camera: camera)
        for _ in 0..<3 { reachability.reportUnreachable() }
        await reachability.settled()
        #expect(reachability.isOffline)

        var timing = ReolinkEventTiming()
        timing.pollInterval = .milliseconds(30)
        timing.useONVIFEvents = false
        let driver = ReolinkDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil, transport: UnusedTransport(),
                                   timing: timing, reachability: reachability)
        let source = try #require(driver.makeEventSource())
        let stream = source.events()
        let connected = Box(false)
        let reader = Task {
            for await event in stream where event == .eventChannel(connected: true) { connected.set(true) }
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(camera.requests.value == 0, "no login, no poll while the camera answers nothing")
        #expect(!connected.value)

        transport.open.set([UInt16(camera.server.port)])
        #expect(await eventually(timeout: .seconds(5)) { connected.value }, "the channel connects as soon as the probe finds the camera")
        await source.stop()
        reader.cancel()
        reachability.reset()
    }

    // MARK: Clock overlay on a doorbell that cannot switch it off

    @Test func anAbilityErrorFromSetOsdIsNotSupportedAndNothingIsRetried() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        camera.setOsdError.set(-26)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .reolink)

        let change = try await service.hideCameraClock()

        // (No ONVIF service answers in this test: the Reolink attempt is the one under test.)
        let attempt = try #require(change.failures.first)
        #expect(!change.succeeded && attempt.method == .reolinkAPI)
        guard case .unsupported = attempt.failure else {
            Issue.record("SetOsd error -26 should read as unsupported, got \(attempt.failure)")
            return
        }
        #expect(camera.setOsdBodies.value.count == 1, "one SetOsd, no retry")
        #expect(camera.commands.value.filter { $0 == "GetOsd" }.count == 1, "one GetOsd (read once, change only osdTime.enable, write)")
    }

    @Test func theWholeOsdAsReadGoesBackWithOnlyTheTimeSwitchedOff() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let before = try JSONValue.parse(Data(try #require(camera.osd.value).utf8))
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .reolink)

        let change = try await service.hideCameraClock()

        #expect(change.succeeded)
        let sent = try #require(camera.setOsdBodies.value.first)
        let osd = try #require(try JSONValue.parse(Data(sent.utf8))[0]?["param"]?["Osd"])
        #expect(osd["osdTime"]?["enable"]?.int == 0)
        // Everything else exactly as GetOsd returned it.
        for key in ["bgcolor", "channel", "osdChannel", "watermark"] {
            #expect(osd[key] == before[key], "\(key) is sent back unchanged")
        }
        #expect(osd["osdTime"]?["pos"] == before["osdTime"]?["pos"])
        #expect(camera.commands.value.filter { $0 == "GetOsd" }.count == 2, "one read to change it, one to check that it stuck")
    }

    @Test func aBareSenderFaultFromONVIFReadsAsNotSupportedToo() async throws {
        let reolink = try await MockReolinkCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { reolink.stop(); onvif.stop() }
        reolink.setOsdError.set(-26)
        onvif.osdMode.set(.bareSenderFault)
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(reolink.server.port), onvifPort: Int(onvif.server.port))
        let service = CameraSettingsService(endpoint: endpoint, credentials: credentials, vendor: .reolink)

        let change = try await service.hideCameraClock()

        #expect(!change.succeeded)
        #expect(change.failures.map(\.method) == [.reolinkAPI, .onvifMinimal])
        #expect(change.isUnsupported, "Reolink: SetOsd error -26; ONVIF: Sender is the camera saying it cannot, not a failure to try again")
        #expect(change.summary == "not supported by this camera")
    }
}
