// Loopback mock Reolink camera (PlatformApple transport): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import MediaCore
import RTSP
import TestSupport
import Testing
@testable import CameraAdapters

/// Loopback Reolink HTTP API (`/api.cgi` JSON commands with a login token, `/cgi-bin/api.cgi?cmd=Snap`).
final class MockReolinkCamera: Sendable {
    struct EventState: Sendable {
        var md = 0, people = 0, vehicle = 0, dogCat = 0, package = 0, visitor = 0
    }

    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08, 0xFF, 0xD9])

    let server: MockHTTPServer
    let logins = Box(0)
    let commands = Box<[String]>([])
    let validToken = Box<String?>(nil)
    let state = Box(EventState())
    /// Polls (`GetEvents` / `GetMdState`) still to answer HTTP 503.
    let failingPolls = Box(0)
    /// Requests of any kind still to answer HTTP 503 (the camera is down: Wi-Fi drop, reboot, firmware update).
    let failingRequests = Box(0)
    /// `rspCode`s the next `GetEvents` calls answer with, in order.
    let getEventsErrors = Box<[Int]>([])
    /// Logins answer -5 "max session number" while set.
    let sessionLimit = Box(false)
    /// Logins answer -105 "Frequent logins, please try again later!" while set.
    let frequentLogins = Box(false)
    let loginDelay = Box<Duration>(.zero)
    /// Tokens ended with `Logout`.
    let logouts = Box<[String]>([])
    /// `GetNetPort`'s `NetPort` value (`onvifEnable`, `onvifPort`, …); nil answers -9 "not support".
    let netPort = Box<String?>(nil)
    /// `GetOsd`'s `Osd` value (nil answers -9 "not support"); `SetOsd` replaces it and is recorded in `setOsdBodies`.
    let osd = Box<String?>(#"{"bgcolor":0,"channel":0,"osdChannel":{"enable":1,"name":"Camera1","pos":"Lower Right"},"osdTime":{"enable":1,"pos":"Top Center"},"watermark":1}"#)
    let setOsdBodies = Box<[String]>([])
    /// `SetOsd` answers success but keeps the old value.
    let ignoreSetOsd = Box(false)
    /// `SetOsd` answers this `rspCode` (e.g. -26 "ability error" on a doorbell that cannot switch its clock off).
    let setOsdError = Box<Int?>(nil)
    /// Every request waits this long before it is answered (to see how many are in flight at once).
    let requestDelay = Box<Duration>(.zero)
    let inFlight = Box(0)
    let maxInFlight = Box(0)
    let requests = Box(0)
    /// Older firmware: GetEvents answers "not support".
    let legacy: Bool
    let leaseTime: Int

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)) }

    private init(server: MockHTTPServer, legacy: Bool, leaseTime: Int) {
        self.server = server
        self.legacy = legacy
        self.leaseTime = leaseTime
    }

    static func start(legacy: Bool = false, leaseTime: Int = 3600) async throws -> MockReolinkCamera {
        let holder = Box<MockReolinkCamera?>(nil)
        let server = try await MockHTTPServer.start { request in
            guard let camera = holder.value else { return .status(503) }
            return await camera.handle(request)
        }
        let camera = MockReolinkCamera(server: server, legacy: legacy, leaseTime: leaseTime)
        holder.set(camera)
        return camera
    }

    func stop() { server.stop() }

    private func error(_ cmd: String, _ code: Int, _ detail: String) -> MockResponse {
        .json(#"[{"cmd":"\#(cmd)","code":1,"error":{"detail":"\#(detail)","rspCode":\#(code)}}]"#)
    }

    private func value(_ cmd: String, _ value: String) -> MockResponse {
        .json(#"[{"cmd":"\#(cmd)","code":0,"value":\#(value)}]"#)
    }

    private func handle(_ request: MockRequest) async -> MockResponse {
        let cmd = request.query("cmd") ?? ""
        commands.update { $0.append(cmd) }
        requests.update { $0 += 1 }
        let concurrent = inFlight.update { count -> Int in count += 1; return count }
        maxInFlight.update { $0 = max($0, concurrent) }
        defer { inFlight.update { $0 -= 1 } }
        if requestDelay.value > .zero { try? await Task.sleep(for: requestDelay.value) }
        if failingRequests.update({ count -> Bool in
            defer { count = max(0, count - 1) }
            return count > 0
        }) {
            return .status(503)
        }
        if cmd == "Login" {
            if loginDelay.value > .zero { try? await Task.sleep(for: loginDelay.value) }
            if sessionLimit.value { return error("Login", -5, "max session") }
            if frequentLogins.value { return error("Login", -105, "Frequent logins, please try again later!") }
            guard let body = try? JSONValue.parse(request.body), body[0]?["cmd"]?.string == "Login",
                  let user = body[0]?["param"]?["User"], user["userName"]?.string == "admin", user["password"]?.string == "secret" else {
                return error("Login", -7, "login failed")
            }
            let token = "tok\(logins.update { $0 += 1; return $0 })"
            validToken.set(token)
            return value("Login", #"{"Token":{"leaseTime":\#(leaseTime),"name":"\#(token)"}}"#)
        }
        guard let token = request.query("token"), token == validToken.value else { return error(cmd, -6, "please login first") }
        if cmd == "Logout" {
            logouts.update { $0.append(token) }
            validToken.set(nil)
            return value(cmd, #"{"rspCode":200}"#)
        }
        if cmd == "GetEvents" || cmd == "GetMdState", failingPolls.update({ count -> Bool in
            defer { count = max(0, count - 1) }
            return count > 0
        }) {
            return .status(503)
        }
        if request.path == "/cgi-bin/api.cgi", cmd == "Snap" {
            guard request.query("channel") == "0", request.query("rs") != nil else { return .status(400) }
            return .full(status: 200, headers: [("Content-Type", "image/jpeg")], body: Self.jpeg)
        }
        guard request.path == "/api.cgi", request.method == "POST",
              let body = try? JSONValue.parse(request.body), body[0]?["cmd"]?.string == cmd else { return error(cmd, -4, "param error") }
        let s = state.value
        switch cmd {
        case "GetDevInfo": return .json((try? fixtureText("reolink/GetDevInfo-doorbell.json")) ?? "")
        case "GetAbility": return .json((try? fixtureText("reolink/GetAbility.json")) ?? "")
        case "GetEnc": return .json((try? fixtureText("reolink/GetEnc.json")) ?? "")
        case "GetOsd":
            guard let osd = osd.value else { return error(cmd, -9, "not support") }
            return value(cmd, #"{"Osd":\#(osd)}"#)
        case "SetOsd":
            setOsdBodies.update { $0.append(request.bodyText) }
            if let code = setOsdError.value { return error(cmd, code, "error \(code)") }
            if !ignoreSetOsd.value, let stored = body[0]?["param"]?["Osd"], let data = try? JSONEncoder().encode(stored) {
                osd.set(String(decoding: data, as: UTF8.self))
            }
            return value(cmd, #"{"rspCode":200}"#)
        case "GetNetPort":
            guard let netPort = netPort.value else { return error(cmd, -9, "not support") }
            return value(cmd, #"{"NetPort":\#(netPort)}"#)
        case "GetEvents":
            if legacy { return error(cmd, -9, "not support") }
            if let code = getEventsErrors.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return error(cmd, code, "error \(code)") }
            return value(cmd, """
            {"channel":0,"ai":{"dog_cat":{"alarm_state":\(s.dogCat),"support":1},"face":{"alarm_state":0,"support":0},\
            "people":{"alarm_state":\(s.people),"support":1},"vehicle":{"alarm_state":\(s.vehicle),"support":1},\
            "package":{"alarm_state":\(s.package),"support":1}},"md":{"alarm_state":\(s.md),"support":1},\
            "visitor":{"alarm_state":\(s.visitor),"support":1}}
            """)
        case "GetMdState": return value(cmd, #"{"state":\#(s.md)}"#)
        case "GetAiState":
            return value(cmd, """
            {"channel":0,"dog_cat":{"alarm_state":\(s.dogCat),"support":1},"people":{"alarm_state":\(s.people),"support":1},\
            "vehicle":{"alarm_state":\(s.vehicle),"support":1}}
            """)
        default: return error(cmd, -9, "not support")
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ReolinkDriverTests {
    private let credentials = HTTPCredentials(username: "admin", password: "secret")

    private func timing(ringDedupe: Duration = .seconds(3)) -> ReolinkEventTiming {
        var timing = ReolinkEventTiming()
        timing.pollInterval = .milliseconds(30)
        timing.ringDedupe = ringDedupe
        timing.policy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(20), maximum: .milliseconds(50), jitter: 0),
                                        healthyAfter: .seconds(30), minimumDelayAfterFailure: .zero)
        timing.onvif.pullTimeout = "PT1S"
        timing.onvif.minimumPullInterval = .milliseconds(20)
        timing.onvif.policy = timing.policy
        return timing
    }

    private func backchannel(_ offers: Bool) -> FakeRTSPFactory {
        FakeRTSPFactory(FakeRTSPSession(info: RTSPSessionInfo(tracks: [], backchannelFormat: offers ? RTSPBackchannelTalkbackSink.defaultFormat : nil)))
    }

    private func driver(_ camera: MockReolinkCamera, endpoint: CameraEndpoint? = nil, credentials: HTTPCredentials? = nil,
                        timing: ReolinkEventTiming = ReolinkEventTiming(), rtsp: FakeRTSPFactory? = nil) -> ReolinkDriver {
        ReolinkDriver(endpoint: endpoint ?? camera.endpoint, credentials: credentials ?? self.credentials, mainStreamURL: nil, subStreamURL: nil,
                      transport: UnusedTransport(), rtspFactory: (rtsp ?? backchannel(false)).factory, timing: timing)
    }

    @Test func loginTokenIsReusedRefreshedBeforeExpiryAndRenewedOnRejection() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials, now: { clock.value })
        _ = try await api.command("GetDevInfo")
        _ = try await api.command("GetEnc", param: .object(["channel": .number(0)]))
        #expect(camera.logins.value == 1)
        clock.set(clock.value.addingTimeInterval(3_550))   // within a minute of the 3600 s lease
        _ = try await api.command("GetDevInfo")
        #expect(camera.logins.value == 2)
        camera.validToken.set("revoked")                   // camera restarted: "please login first"
        _ = try await api.command("GetDevInfo")
        #expect(camera.logins.value == 3)
        #expect(camera.server.requests.allSatisfy { $0.query("password") == nil && $0.query("user") == nil })
    }

    @Test func concurrentCallersShareOneLogin() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        camera.loginDelay.set(.milliseconds(150))
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await api.command("GetDevInfo") } }
            group.addTask { _ = try await api.snapshot() }
            try await group.waitForAll()
        }
        #expect(camera.logins.value == 1)
        #expect(camera.commands.value.filter { $0 == "Login" }.count == 1)
    }

    @Test func sessionLimitPausesLoginAttempts() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        camera.sessionLimit.set(true)
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials, sessionLimitCooldown: 300, now: { clock.value })
        let limit = CameraAdapterError.apiError(command: "Login", code: -5)
        await #expect(throws: limit) { _ = try await api.command("GetDevInfo") }
        await #expect(throws: limit) { _ = try await api.command("GetDevInfo") }   // no new attempt during the cooldown
        await #expect(throws: limit) { _ = try await api.snapshot() }
        #expect(camera.commands.value.filter { $0 == "Login" }.count == 1)
        camera.sessionLimit.set(false)
        clock.set(clock.value.addingTimeInterval(301))
        _ = try await api.command("GetDevInfo")
        #expect(camera.commands.value.filter { $0 == "Login" }.count == 2)
    }

    /// Review finding (W4 round 4): -105 "Frequent logins, please try again later!" (API v8 error table) got no cooldown:
    /// the event source's reconnects and the snapshot path logged in again on every call while the camera asked them
    /// to back off. It pauses logins like -5.
    @Test func frequentLoginsPauseLoginAttempts() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        camera.frequentLogins.set(true)
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials, sessionLimitCooldown: 300, now: { clock.value })
        let throttled = CameraAdapterError.apiError(command: "Login", code: -105)
        await #expect(throws: throttled) { _ = try await api.command("GetDevInfo") }
        for _ in 0..<3 {
            await #expect(throws: throttled) { _ = try await api.command("GetDevInfo") }   // no new attempt during the cooldown
        }
        await #expect(throws: throttled) { _ = try await api.snapshot() }
        #expect(camera.commands.value.filter { $0 == "Login" }.count == 1)
        camera.frequentLogins.set(false)
        clock.set(clock.value.addingTimeInterval(299))
        await #expect(throws: throttled) { _ = try await api.command("GetDevInfo") }
        #expect(camera.commands.value.filter { $0 == "Login" }.count == 1)
        clock.set(clock.value.addingTimeInterval(2))
        _ = try await api.command("GetDevInfo")
        #expect(camera.commands.value.filter { $0 == "Login" }.count == 2)
    }

    /// Review finding (W4 round 4): the Add Camera wizard and the Connection sheet probe through a throwaway driver
    /// (`BridgeEngine.probeOnce`), which logged in and was dropped: each check held one of the camera's few API sessions
    /// for the whole lease (3600 s). `close()` logs the driver's session out; the driver stays usable.
    @Test func closingAProbedDriverLogsItsSessionOut() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        for attempt in 1...3 {
            let driver = CameraDrivers.make(vendor: .reolink, endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil,
                                            subStreamURL: nil, transport: UnusedTransport())
            _ = try await driver.probe()
            await driver.close()
            #expect(camera.logins.value == attempt)
            #expect(camera.logouts.value.count == attempt, "one Logout per probe")
            #expect(camera.validToken.value == nil)
        }
        #expect(camera.logouts.value == ["tok1", "tok2", "tok3"])
        // A closed driver logs in again when it is used.
        let driver = driver(camera)
        _ = try await driver.probe()
        await driver.close()
        _ = try await driver.snapshot()
        #expect(camera.logins.value == 5)
        await driver.close()
        #expect(camera.logouts.value.count == 5)
    }

    @Test func eventSourceReusesTheDriverSessionReleasesLevelStatesAndLogsOut() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        var pollingOnly = timing()
        pollingOnly.useONVIFEvents = false
        let driver = driver(camera, timing: pollingOnly)
        _ = try await driver.probe()
        #expect(camera.logins.value == 1)
        let source = try #require(driver.makeEventSource())
        let recorder = Recorder(source.events())
        camera.state.update { $0.md = 1 }
        #expect(await recorder.wait { $0.contains(.motion(true)) })
        camera.failingPolls.set(3)                                            // the doorbell's Wi-Fi drops: polls fail, the session ends
        #expect(await recorder.wait { $0.filter { $0 == .eventChannel(connected: true) }.count >= 2 && $0.filter { $0 == .motion(true) }.count >= 2 })
        let events = recorder.values
        let drop = try #require(events.firstIndex(of: .eventChannel(connected: false)))
        let released = try #require(events.firstIndex(of: .motion(false)))
        #expect(released < drop, "motion must not stay on while the channel is down")
        #expect(events[(drop + 1)...].contains(.motion(true)), "the reconnected poll re-asserts motion")
        #expect(camera.logins.value == 1, "probe, snapshots and reconnects share one API session")
        _ = try await driver.snapshot()
        #expect(camera.logins.value == 1)
        await source.stop()
        #expect(camera.logouts.value == ["tok1"])
    }

    /// A session that starts while the camera is still down (the token is cached, so nothing else fails first) must not
    /// latch legacy polling, which never reports the visitor button, nor claim the channel is connected.
    @Test func sessionStartedDuringAnOutageStillRingsAfterRecovery() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        var pollingOnly = timing()
        pollingOnly.useONVIFEvents = false
        let source = try #require(driver(camera, timing: pollingOnly).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.eventChannel(connected: true)) })
        camera.failingRequests.set(10)   // 3 failed polls end the session; the reconnects' GetEvents fail too
        #expect(await recorder.wait { $0.filter { $0 == .eventChannel(connected: true) }.count >= 2 })
        #expect(camera.failingRequests.value == 0)
        camera.state.update { $0.visitor = 1 }
        #expect(await recorder.wait { $0.contains(.doorbellPressed) }, "a press after the camera came back rings")
        let channel = recorder.values.compactMap { event -> Bool? in
            if case .eventChannel(let connected) = event { return connected }
            return nil
        }
        #expect(channel == [true, false, true], "no 'connected' while every request failed")
        #expect(!camera.commands.value.contains("GetMdState"), "a transport failure is not 'GetEvents not supported'")
        await source.stop()
    }

    /// A transient API error at session start (-17 "rcv failed") is retried, not taken for "GetEvents not supported";
    /// an answer about the request itself (-4 "param error") selects legacy polling at once.
    @Test func onlyRequestErrorsSelectLegacyPolling() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        var pollingOnly = timing()
        pollingOnly.useONVIFEvents = false
        camera.getEventsErrors.set([-17])
        let source = try #require(driver(camera, timing: pollingOnly).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.eventChannel(connected: true)) })
        camera.state.update { $0.visitor = 1 }
        #expect(await recorder.wait { $0.contains(.doorbellPressed) })
        #expect(!camera.commands.value.contains("GetMdState"))
        await source.stop()

        camera.getEventsErrors.set([-4])
        let legacySource = try #require(driver(camera, timing: pollingOnly).makeEventSource())
        let legacyRecorder = Recorder(legacySource.events())
        #expect(await legacyRecorder.wait { $0.contains(.eventChannel(connected: true)) })
        #expect(await eventually { camera.commands.value.contains("GetMdState") })
        await legacySource.stop()
    }

    /// The ONVIF side channel (doorbell `Visitor`) is set up again by the first session that reaches the camera.
    @Test func onvifSideChannelComesBackAfterAnOutageAtSessionStart() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let onvif = try await MockONVIFCamera.start()
        defer { onvif.stop() }
        var endpoint = camera.endpoint
        endpoint.onvifPort = Int(onvif.server.port)
        let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
        let source = try #require(driver(camera, endpoint: endpoint, credentials: credentials, timing: timing()).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await eventually { onvif.actions.value.contains("CreatePullPointSubscription") })
        #expect(await recorder.wait { $0.contains(.eventChannel(connected: true)) })
        camera.failingRequests.set(6)   // 3 polls, then (old behaviour) GetEvents, GetDevInfo and GetAbility of the reconnect
        #expect(await eventually { onvif.actions.value.filter { $0 == "CreatePullPointSubscription" }.count >= 2 },
                "the reconnected session subscribes to ONVIF events again")
        onvif.pullQueue.update { $0.append("Pull-MyRuleDetector.xml") }   // a Visitor press, seen only over ONVIF
        #expect(await recorder.wait { $0.contains(.doorbellPressed) })
        await source.stop()
    }

    /// `supportOnvifEnable` only says ONVIF can be switched; `GetNetPort.onvifEnable` says whether it is on. A doorbell
    /// with ONVIF off gets no side channel (no PullPoint attempt every minute for the whole session); rings still come
    /// from polling.
    @Test func noONVIFSideChannelWhileONVIFIsSwitchedOff() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let onvif = try await MockONVIFCamera.start(pulls: ["Pull-MyRuleDetector.xml"])
        defer { onvif.stop() }
        camera.netPort.set(#"{"httpEnable":1,"httpPort":80,"onvifEnable":0,"onvifPort":\#(onvif.server.port),"rtspEnable":1,"rtspPort":554}"#)
        var endpoint = camera.endpoint
        endpoint.onvifPort = Int(onvif.server.port)
        let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
        let source = try #require(driver(camera, endpoint: endpoint, credentials: credentials, timing: timing()).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.eventChannel(connected: true)) })
        #expect(camera.commands.value.contains("GetNetPort"))
        camera.state.update { $0.visitor = 1 }   // the press, seen by polling
        #expect(await recorder.wait { $0.contains(.doorbellPressed) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(onvif.actions.value.isEmpty, "ONVIF is off: nothing to subscribe to")
        await source.stop()
    }

    /// With ONVIF on, the side channel uses the port the camera reports (not a guessed 8000) when none is configured.
    @Test func onvifSideChannelUsesTheReportedONVIFPort() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let onvif = try await MockONVIFCamera.start(pulls: ["Pull-MyRuleDetector.xml"])
        defer { onvif.stop() }
        camera.netPort.set(#"{"httpEnable":1,"httpPort":80,"onvifEnable":1,"onvifPort":\#(onvif.server.port),"rtspEnable":1,"rtspPort":554}"#)
        #expect(camera.endpoint.onvifPort == nil)
        let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
        let source = try #require(driver(camera, credentials: credentials, timing: timing()).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.doorbellPressed) }, "Visitor over ONVIF on the reported port")
        #expect(onvif.actions.value.contains("CreatePullPointSubscription"))
        await source.stop()
    }

    @Test func onvifStateFromNetPort() throws {
        let on = try JSONValue.parse(Data(#"{"NetPort":{"onvifEnable":1,"onvifPort":8001}}"#.utf8))
        #expect(ReolinkDriver.onvifNetPort(on) == ReolinkDriver.ONVIFNetPort(enabled: true, port: 8001))
        let off = try JSONValue.parse(Data(#"{"NetPort":{"onvifEnable":0,"onvifPort":8000}}"#.utf8))
        #expect(ReolinkDriver.onvifNetPort(off) == ReolinkDriver.ONVIFNetPort(enabled: false, port: 8000))
        let unreported = try JSONValue.parse(Data(#"{"NetPort":{"httpPort":80}}"#.utf8))
        #expect(ReolinkDriver.onvifNetPort(unreported) == ReolinkDriver.ONVIFNetPort(enabled: nil, port: nil))
        let badPort = try JSONValue.parse(Data(#"{"NetPort":{"onvifEnable":1,"onvifPort":70000}}"#.utf8))
        #expect(ReolinkDriver.onvifNetPort(badPort) == ReolinkDriver.ONVIFNetPort(enabled: true, port: nil))
    }

    /// Level states the ONVIF side channel turned on end when its subscription fails, although polling keeps the
    /// session (and the event channel) up.
    @Test func sideChannelLevelStatesEndWhenItsSubscriptionFails() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let onvif = try await MockONVIFCamera.start(pulls: ["Pull-PeopleDetect.xml"])
        defer { onvif.stop() }
        var endpoint = camera.endpoint
        endpoint.onvifPort = Int(onvif.server.port)
        let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
        let source = try #require(driver(camera, endpoint: endpoint, credentials: credentials, timing: timing()).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.object(.person, true)) && $0.contains(.motion(true)) })
        onvif.failPulls.set(true)
        #expect(await recorder.wait { $0.contains(.object(.person, false)) && $0.contains(.motion(false)) },
                "PeopleDetect must not stay on after its subscription broke")
        #expect(!recorder.values.contains(.eventChannel(connected: false)), "polling still runs")
        // A later real motion is a new rising edge (HKSV is triggered again).
        camera.state.update { $0.md = 1 }
        #expect(await recorder.wait { $0.filter { $0 == .motion(true) }.count >= 2 })
        await source.stop()
    }

    /// Review finding (W4 round 2): the side channel's wait after rejected credentials (`delayAfterUnauthorized`, so the
    /// camera's login lockout is never tripped) never ran in a test; a mutant without it (an ONVIF login at every
    /// backoff step) passed every suite.
    @Test func sideChannelWaitsAfterRejectedCredentials() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let onvif = try await MockONVIFCamera.start()
        defer { onvif.stop() }
        onvif.rejectCredentials.set(true)
        var endpoint = camera.endpoint
        endpoint.onvifPort = Int(onvif.server.port)
        let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
        var slow = timing()   // backoff 20–50 ms
        slow.onvif.policy.delayAfterUnauthorized = .seconds(600)
        let source = try #require(driver(camera, endpoint: endpoint, credentials: credentials, timing: slow).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.eventChannel(connected: true)) }, "polling works")
        let authenticated = { onvif.actions.value.filter { $0 != "GetSystemDateAndTime" }.count }
        #expect(await eventually { authenticated() >= 1 })
        try await Task.sleep(for: .milliseconds(150))   // the first attempt ends
        let attempts = authenticated()
        try await Task.sleep(for: .milliseconds(600))
        #expect(authenticated() == attempts, "no ONVIF login before the unauthorized delay (\(attempts) → \(authenticated()))")
        #expect(!recorder.values.contains(.eventChannel(connected: false)), "polling still runs")
        await source.stop()
    }

    @Test func badPasswordIsUnauthorized() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let bad = driver(camera, credentials: HTTPCredentials(username: "admin", password: "nope"))
        await #expect(throws: CameraAdapterError.unauthorized) { try await bad.probe() }
    }

    @Test func eventSourceReportsRejectedCredentials() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        var slow = timing()
        slow.policy.delayAfterUnauthorized = .seconds(600)
        let bad = driver(camera, credentials: HTTPCredentials(username: "admin", password: "nope"), timing: slow)
        let source = try #require(bad.makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.authenticationFailed) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.values == [.authenticationFailed], "no channel, and no quick retry")
        #expect(camera.commands.value.filter { $0 == "Login" }.count == 1)
        await source.stop()
    }

    @Test func probeDetectsDoorbellStreamsAndEvents() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let rtsp = backchannel(true)
        let result = try await driver(camera, rtsp: rtsp).probe()
        #expect(result.vendor == .reolink)
        #expect(result.manufacturer == "Reolink")
        #expect(result.model == "Reolink Video Doorbell WiFi")
        #expect(result.serialNumber == "00000000ABCD")
        #expect(result.firmware == "v3.0.0.4867_2505072124")
        let main = try #require(result.mainStream)
        #expect(main.url.absoluteString == "rtsp://127.0.0.1:554/h264Preview_01_main")
        #expect(main.videoCodec == .h264 && main.width == 2560 && main.height == 1920 && main.fps == 15 && main.audioCodec == .aac)
        let sub = try #require(result.subStream)
        #expect(sub.url.absoluteString == "rtsp://127.0.0.1:554/h264Preview_01_sub")
        #expect(sub.width == 640 && sub.height == 480)
        #expect(result.capabilities.isDoorbell)
        #expect(result.capabilities.events == [.motion, .person, .vehicle, .animal, .package, .doorbell])
        #expect(result.capabilities.snapshotAPI)
        #expect(result.capabilities.twoWayAudio)
        #expect(rtsp.configurations.value.first?.requestBackchannel == true)
        #expect(Set(camera.commands.value).isSuperset(of: ["Login", "GetDevInfo", "GetAbility", "GetEnc", "GetEvents"]))
    }

    @Test func snapshotUsesSnapWithToken() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        #expect(try await driver(camera).snapshot() == MockReolinkCamera.jpeg)
    }

    @Test func pollingMapsMotionObjectsAndDedupesRings() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        var pollingOnly = timing(ringDedupe: .milliseconds(400))
        pollingOnly.useONVIFEvents = false
        let source = try #require(driver(camera, timing: pollingOnly).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.eventChannel(connected: true)) })
        camera.state.update { $0.md = 1; $0.people = 1 }
        #expect(await recorder.wait { $0.contains(.motion(true)) && $0.contains(.object(.person, true)) })
        camera.state.update { $0.visitor = 1 }
        #expect(await recorder.wait { $0.contains(.doorbellPressed) })
        camera.state.update { $0.visitor = 0 }
        try await Task.sleep(for: .milliseconds(80))
        camera.state.update { $0.visitor = 1 }                     // second press inside the dedupe window
        try await Task.sleep(for: .milliseconds(80))
        #expect(recorder.values.filter { $0 == .doorbellPressed }.count == 1)
        camera.state.update { $0.visitor = 0 }
        try await Task.sleep(for: .milliseconds(450))
        camera.state.update { $0.visitor = 1; $0.md = 0; $0.people = 0 }
        #expect(await recorder.wait { $0.filter { $0 == .doorbellPressed }.count == 2 })
        #expect(await recorder.wait { $0.contains(.motion(false)) && $0.contains(.object(.person, false)) })
        await source.stop()
    }

    @Test func legacyFirmwarePollsMdAndAiState() async throws {
        let camera = try await MockReolinkCamera.start(legacy: true)
        defer { camera.stop() }
        var pollingOnly = timing()
        pollingOnly.useONVIFEvents = false
        let source = try #require(driver(camera, timing: pollingOnly).makeEventSource())
        let recorder = Recorder(source.events())
        camera.state.update { $0.dogCat = 1 }
        #expect(await recorder.wait { $0.contains(.object(.animal, true)) && $0.contains(.motion(true)) })
        await source.stop()
        #expect(camera.commands.value.contains("GetMdState"))
        #expect(camera.commands.value.contains("GetAiState"))
    }

    @Test func onvifVisitorAndPollingRingOnce() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let onvif = try await MockONVIFCamera.start(pulls: ["Pull-MyRuleDetector.xml"])
        defer { onvif.stop() }
        var endpoint = camera.endpoint
        endpoint.onvifPort = Int(onvif.server.port)
        let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)
        let source = try #require(driver(camera, endpoint: endpoint, credentials: credentials, timing: timing(ringDedupe: .seconds(3)))
            .makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.doorbellPressed) })      // from ONVIF Visitor
        #expect(onvif.actions.value.contains("CreatePullPointSubscription"))
        camera.state.update { $0.visitor = 1 }                               // the same press seen by polling
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.values.filter { $0 == .doorbellPressed }.count == 1)
        await source.stop()
        #expect(await eventually { onvif.actions.value.contains("Unsubscribe") })
    }
}
#endif
