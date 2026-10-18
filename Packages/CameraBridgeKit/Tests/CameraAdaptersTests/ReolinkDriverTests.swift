// Loopback mock Reolink camera (PlatformApple transport): macOS only.
#if os(macOS) || os(Linux)
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

    // MARK: Errors, as the HTTP API v8 error table has them

    /// What the next logins answer, in order (`rspCode`, `detail`); an empty queue: the usual check of the user name and password.
    let loginErrors = Box<[(code: Int, detail: String)]>([])
    /// What the next calls of a command answer instead of its value, in order (`code` 1 with `error.rspCode`).
    let errorQueue = Box<[String: [Int]]>([:])
    /// A `Set…` answered `code` 0 with this `value.rspCode` (and the detail "set config failed") instead of 200.
    let setRspCodes = Box<[String: Int]>([:])
    /// Every command's request body as sent, parsed (Login's password included: tests never print it), in order.
    let bodies = Box<[(cmd: String, body: JSONValue)]>([])

    // MARK: Settings (each `Get…` answers what the camera keeps, each `Set…` changes it)

    /// `GetAbility` permits and versions that differ from the fixture's (module → permit, ver). Device-wide modules `ntp`, `time`, `upnp`,
    /// `p2p`, `localLink`, `ddns`, and the channel's `enc` and `osd`, are permit 6 (read and write), version 1 unless set here; a module set
    /// to nil is left out of the answer.
    let abilities = Box<[String: (permit: Int, ver: Int)?]>([:])
    /// `GetNtp`'s `Ntp`.
    let ntp = Box(#"{"enable":1,"interval":1440,"port":123,"server":"pool.ntp.org"}"#)
    let upnp = Box(#"{"enable":1}"#)
    /// The camera's UID (made up): Reolink's cloud knows the camera by it. Never logged, kept or sent back.
    static let uid = "95270000TESTUID0"
    let p2p = Box(#"{"enable":1,"uid":"\#(MockReolinkCamera.uid)"}"#)
    /// `GetLocalLink`'s `LocalLink` as the owner's Wi-Fi doorbell would have it (documentation addresses, a documentation MAC).
    static let localLink = #"{"activeLink":"Wi-Fi","dns":{"auto":1,"dns1":"192.168.77.1","dns2":"192.168.77.1"},"mac":"00:00:5e:00:53:31","#
        + #""static":{"gateway":"192.168.77.1","ip":"192.168.77.31","mask":"255.255.255.0"},"type":"DHCP"}"#
    let localLink = Box(MockReolinkCamera.localLink)
    /// After a `SetLocalLink` it takes, the camera restarts its network: this many requests answer HTTP 503, and its session is gone.
    let restartAfterLinkWrite = Box(0)
    /// `GetTime`: `Time.timeZone` as the camera keeps it, whether it counts it east of UTC (the guide's range, -46800…43200, says west, as
    /// POSIX does), and `Dst` (the US rule, off). `Time`'s clock is the real time in that zone (daylight saving added while `dstNow`).
    let timeZone = Box(25200)
    let timeZoneCountsEast = Box(false)
    static let dst = #"{"enable":0,"endHour":2,"endMin":0,"endMon":11,"endSec":0,"endWeek":1,"endWeekday":0,"offset":1,"startHour":2,"#
        + #""startMin":0,"startMon":3,"startSec":0,"startWeek":2,"startWeekday":0}"#
    let dst = Box(MockReolinkCamera.dst)
    let dstNow = Box(false)
    /// `GetEnc`'s `Enc` (`SetEnc` changes it) and, with action 1, the `range` (the sizes, frame rates and bit rates the camera takes).
    let enc = Box(MockReolinkCamera.doorbellEnc)
    let encRange = Box(MockReolinkCamera.doorbellRange)
    /// The doorbell's `Enc`, from `Fixtures/reolink/GetEnc.json`.
    static let doorbellEnc: String = {
        guard let value = try? JSONValue.parse(try fixture("reolink/GetEnc.json"))[0]?["value"]?["Enc"],
              let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }()
    static let doorbellRange = #"[{"audio":"boolean","chnBit":1,"mainStream":{"bitRate":[1024,1536,2048,3072,4096,5120,6144],"#
        + #""default":{"bitRate":3072,"frameRate":15,"gop":2},"frameRate":[20,18,16,15,12,10,8,6,4,2],"gop":{"max":4,"min":1},"height":1920,"#
        + #""profile":["Base","Main","High"],"size":"2560*1920","vType":"h264","width":2560},"subStream":{"bitRate":[64,128,160,192,256,384,512],"#
        + #""default":{"bitRate":256,"frameRate":15,"gop":4},"frameRate":[15,10,7,4],"gop":{"max":4,"min":1},"height":480,"#
        + #""profile":["Base","Main","High"],"size":"640*480","vType":"h264","width":640}}]"#

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
        if let parsed = try? JSONValue.parse(request.body) { bodies.update { $0.append((cmd, parsed)) } }
        if cmd == "Login" {
            if loginDelay.value > .zero { try? await Task.sleep(for: loginDelay.value) }
            if sessionLimit.value { return error("Login", -5, "max session") }
            if frequentLogins.value { return error("Login", -105, "Frequent logins, please try again later!") }
            if let answer = loginErrors.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return error("Login", answer.code, answer.detail) }
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
        if let code = errorQueue.update({ queue -> Int? in
            guard var codes = queue[cmd], !codes.isEmpty else { return nil }
            let code = codes.removeFirst()
            queue[cmd] = codes
            return code
        }) {
            return error(cmd, code, "error \(code)")
        }
        if let code = setRspCodes.value[cmd] { return value(cmd, #"{"detail":"set config failed","rspCode":\#(code)}"#) }
        if let answer = settingsAnswer(cmd, body: body) { return answer }
        let s = state.value
        switch cmd {
        case "GetDevInfo": return .json((try? fixtureText("reolink/GetDevInfo-doorbell.json")) ?? "")
        case "GetAbility": return .json(abilityAnswer())
        case "GetEnc":
            guard body[0]?["action"]?.int == 1 else { return value(cmd, #"{"Enc":\#(enc.value)}"#) }
            return .json(#"[{"cmd":"GetEnc","code":0,"initial":{"Enc":\#(enc.value)},"range":{"Enc":\#(encRange.value)},"value":{"Enc":\#(enc.value)}}]"#)
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

    /// `Set…` commands sent, with their `param` as sent.
    var sets: [(cmd: String, param: JSONValue)] {
        bodies.value.filter { $0.cmd.hasPrefix("Set") }.map { ($0.cmd, $0.body[0]?["param"] ?? .null) }
    }

    private static func text(_ value: JSONValue) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private static func object(_ text: String) -> [String: JSONValue] {
        (try? JSONValue.parse(Data(text.utf8)))?.object ?? [:]
    }

    /// The fixture's `GetAbility` with the settings modules (and `abilities`' overrides) added.
    private func abilityAnswer() -> String {
        guard var root = try? JSONValue.parse(try fixture("reolink/GetAbility.json")).array?.first?.object,
              var value = root["value"]?.object, var ability = value["Ability"]?.object,
              var channels = ability["abilityChn"]?.array, var channel = channels.first?.object else { return "[]" }
        func entry(_ permit: Int, _ ver: Int) -> JSONValue { .object(["permit": .number(Double(permit)), "ver": .number(Double(ver))]) }
        let overrides = abilities.value
        for module in ["ntp", "time", "upnp", "p2p", "localLink", "ddns"] {
            switch overrides[module] {
            case .some(.some(let set)): ability[module] = entry(set.permit, set.ver)
            case .some(.none): ability[module] = nil
            case .none: ability[module] = entry(6, 1)
            }
        }
        for module in ["enc", "osd"] {
            switch overrides[module] {
            case .some(.some(let set)): channel[module] = entry(set.permit, set.ver)
            case .some(.none): channel[module] = nil
            case .none: channel[module] = entry(6, 1)
            }
        }
        channels[0] = .object(channel)
        ability["abilityChn"] = .array(channels)
        value["Ability"] = .object(ability)
        root["value"] = .object(value)
        return Self.text(.array([.object(root)]))
    }

    /// The settings commands; nil for any other.
    private func settingsAnswer(_ cmd: String, body: JSONValue) -> MockResponse? {
        let param = body[0]?["param"]
        func answer(_ key: String, _ stored: String) -> MockResponse { value(cmd, #"{"\#(key)":\#(stored)}"#) }
        /// `stored` with the keys of `sent` written over it (as the camera keeps a partial `Set…`).
        func merged(_ stored: String, _ sent: JSONValue?) -> String {
            var object = Self.object(stored)
            for (key, item) in sent?.object ?? [:] { object[key] = item }
            return Self.text(.object(object))
        }
        let ok = value(cmd, #"{"rspCode":200}"#)
        switch cmd {
        case "GetNtp": return answer("Ntp", ntp.value)
        case "SetNtp": ntp.set(merged(ntp.value, param?["Ntp"])); return ok
        case "GetUpnp": return answer("Upnp", upnp.value)
        case "SetUpnp": upnp.set(merged(upnp.value, param?["Upnp"])); return ok
        case "GetP2p": return answer("P2p", p2p.value)
        case "SetP2p": p2p.set(merged(p2p.value, param?["P2p"])); return ok
        case "GetLocalLink": return answer("LocalLink", localLink.value)
        case "SetLocalLink":
            guard let sent = param?["LocalLink"] else { return error(cmd, -4, "param error") }
            localLink.set(Self.text(sent))
            if restartAfterLinkWrite.value > 0 {
                failingRequests.set(restartAfterLinkWrite.value)
                validToken.set(nil)
            }
            return ok
        case "GetTime":
            let raw = timeZone.value
            var east = timeZoneCountsEast.value ? raw : -raw
            if dstNow.value { east += (Self.object(dst.value)["offset"]?.int ?? 1) * 3600 }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let local = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date().addingTimeInterval(TimeInterval(east)))
            let time = #"{"day":\#(local.day ?? 1),"hour":\#(local.hour ?? 0),"hourFmt":0,"min":\#(local.minute ?? 0),"mon":\#(local.month ?? 1),"#
                + #""sec":\#(local.second ?? 0),"timeFmt":"MM/DD/YYYY","timeZone":\#(raw),"year":\#(local.year ?? 2026)}"#
            return value(cmd, #"{"Dst":\#(dst.value),"Time":\#(time)}"#)
        case "SetTime":
            if let sent = param?["Dst"] { dst.set(merged(dst.value, sent)) }
            if let zone = param?["Time"]?["timeZone"]?.int { timeZone.set(zone) }
            return ok
        case "SetEnc":
            guard let sent = param?["Enc"]?.object else { return error(cmd, -4, "param error") }
            var stored = Self.object(enc.value)
            let ranges = (try? JSONValue.parse(Data(encRange.value.utf8)))?.array ?? []
            for key in ["mainStream", "subStream"] {
                guard let stream = sent[key]?.object, var kept = stored[key]?.object else { continue }
                let size = stream["size"]?.string ?? kept["size"]?.string
                guard let range = ranges.compactMap({ $0[key]?.object }).first(where: { $0["size"]?.string == size }) else {
                    return error(cmd, -13, "set config failed")
                }
                // A value the camera does not offer is refused, as `-13` "set config failed".
                for (field, list) in [("bitRate", "bitRate"), ("frameRate", "frameRate")] {
                    if let wanted = stream[field], range[list]?.array?.contains(wanted) == false { return error(cmd, -13, "set config failed") }
                }
                if let gop = stream["gop"]?.int, let low = range["gop"]?["min"]?.int, let high = range["gop"]?["max"]?.int, !(low...high).contains(gop) {
                    return error(cmd, -13, "set config failed")
                }
                for field in ["size", "frameRate", "bitRate", "gop", "profile"] { if let item = stream[field] { kept[field] = item } }
                for field in ["width", "height", "vType"] { kept[field] = range[field] }
                stored[key] = .object(kept)
            }
            enc.set(Self.text(.object(stored)))
            return ok
        default:
            return nil
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

    private func loginsSent(_ camera: MockReolinkCamera) -> Int { camera.commands.value.filter { $0 == "Login" }.count }

    /// The HTTP API v8 error table (§4.1), as reolink_aio reads it too: -501 "the user does not exist" and -502 "password err" are wrong
    /// credentials, as is an answer whose detail says "password wrong"; -503 "login deny" and -506 "login locked" are the camera's own lock
    /// (no login is sent before it ends, 30 minutes); -500 and -507 (too many addresses, too many logins) pause logins like -5 and -105.
    @Test func loginAnswersAreReadAsTheV8ErrorTableSays() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        func api() -> ReolinkAPI { ReolinkAPI(endpoint: camera.endpoint, credentials: credentials, sessionLimitCooldown: 300, now: { clock.value }) }

        for answer in [(-501, "The user does not exist"), (-502, "Password err"), (-1, "password wrong")] {
            camera.loginErrors.set([answer])
            await #expect(throws: CameraAdapterError.unauthorized, "\(answer)") { _ = try await api().command("GetDevInfo") }
        }
        for code in [-503, -506] {
            camera.loginErrors.set([(code, code == -503 ? "Login deny" : "Login locked")])
            let locked = api()
            let before = loginsSent(camera)
            let lockedOut = CameraAdapterError.lockedOut(until: clock.value.addingTimeInterval(30 * 60))
            await #expect(throws: lockedOut, "\(code)") { _ = try await locked.command("GetDevInfo") }
            await #expect(throws: lockedOut, "no login while the camera's lock lasts") { _ = try await locked.snapshot() }
            #expect(loginsSent(camera) == before + 1)
        }
        for code in [-500, -507] {
            camera.loginErrors.set([(code, "reach the upper limit")])
            let paused = api()
            let before = loginsSent(camera)
            await #expect(throws: CameraAdapterError.apiError(command: "Login", code: code)) { _ = try await paused.command("GetDevInfo") }
            await #expect(throws: CameraAdapterError.apiError(command: "Login", code: code)) { _ = try await paused.command("GetDevInfo") }
            #expect(loginsSent(camera) == before + 1, "no second login during the pause")
            clock.set(clock.value.addingTimeInterval(301))
            _ = try await paused.command("GetDevInfo")
        }
    }

    /// A setting answered `code` 0 with a `value.rspCode` other than 200 did not take (the guide's success is `rspCode` 200; reolink_aio's
    /// `send_setting` checks it): an API error, not a success.
    @Test func aSettingAnsweredWithAnotherResponseCodeIsRefused() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        camera.setRspCodes.set(["SetUpnp": -13])
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials)
        await #expect(throws: CameraAdapterError.apiError(command: "SetUpnp", code: -13)) {
            _ = try await api.command("SetUpnp", param: .object(["Upnp": .object(["enable": .number(0)])]))
        }
        _ = try await api.command("GetDevInfo")   // a value without `rspCode` is a value
    }

    /// A refusal keeps the camera's own detail (cut to a short line, control characters removed), so a step can say it.
    @Test func aRefusalKeepsTheCamerasDetail() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        camera.setRspCodes.set(["SetUpnp": -4])
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials)
        #expect(try await api.answer("SetUpnp", param: .object(["Upnp": .object(["enable": .number(0)])]))
                == .refused(code: -4, detail: "set config failed"))
        camera.errorQueue.set(["GetUpnp": [-9]])
        #expect(try await api.answer("GetUpnp") == .refused(code: -9, detail: "error -9"))
        guard case .value(let value, let element) = try await api.answer("GetEnc", param: .object(["channel": .number(0)]), action: 1) else {
            Issue.record("GetEnc did not answer")
            return
        }
        #expect(value["Enc"]?["mainStream"]?["size"] == .string("2560*1920") && element["range"]?["Enc"]?.array?.count == 1)
    }

    /// -12, -13 and -17 (the camera did not get the command: a Wi-Fi or battery camera waking up) are asked once more after a short wait, as
    /// reolink_aio does; a second such answer is the camera's, and other codes are not asked again.
    @Test func aCommandTheCameraDidNotGetIsAskedOnceMore() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials, transientRetryDelay: .milliseconds(10))
        func sent() -> Int { camera.commands.value.filter { $0 == "GetDevInfo" }.count }
        camera.errorQueue.set(["GetDevInfo": [-13]])
        _ = try await api.command("GetDevInfo")
        #expect(sent() == 2)
        camera.errorQueue.set(["GetDevInfo": [-17, -12]])
        await #expect(throws: CameraAdapterError.apiError(command: "GetDevInfo", code: -12)) { _ = try await api.command("GetDevInfo") }
        #expect(sent() == 4, "once more, not again and again")
        camera.errorQueue.set(["GetDevInfo": [-4]])
        await #expect(throws: CameraAdapterError.apiError(command: "GetDevInfo", code: -4)) { _ = try await api.command("GetDevInfo") }
        #expect(sent() == 5, "a parameter error is the camera's answer")
    }

    /// A setting refused with a credential code once the session's login worked is a change this account may not make (a camera answers so
    /// to an account that is not an administrator), not a wrong password: `.notPermitted`, and no new login. A read refused so is a wrong
    /// password, as before.
    @Test func aSettingRefusedForTheAccountIsNotAWrongPassword() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let api = ReolinkAPI(endpoint: camera.endpoint, credentials: credentials)
        camera.errorQueue.set(["SetOsd": [-27]])
        await #expect(throws: CameraAdapterError.notPermitted("SetOsd")) { _ = try await api.command("SetOsd", param: .object(["Osd": .object([:])])) }
        #expect(CameraAdapterError.notPermitted("SetOsd").isLoginRefusal == false)
        camera.errorQueue.set(["GetOsd": [-27]])
        await #expect(throws: CameraAdapterError.unauthorized) { _ = try await api.command("GetOsd", param: .object(["channel": .number(0)])) }
        #expect(loginsSent(camera) == 1)
    }

    /// Review finding (round two audit): the encoder's frame rate is `frameRate` (GetEnc, SetEnc); `frame` is no field of Reolink's.
    @Test func theEncoderFrameRateIsFrameRate() {
        let values = CameraSettingsService.reolinkValues(["frameRate": .number(25), "gop": .number(2), "vType": .string("h264")])
        #expect(values.frameRate == 25 && values.govLength == 50 && values.codec == "H264")
        #expect(CameraSettingsService.reolinkValues(["frame": .number(25)]).frameRate == nil)
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
