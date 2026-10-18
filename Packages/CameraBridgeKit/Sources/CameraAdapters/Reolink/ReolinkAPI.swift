import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reolink HTTP API (Camera HTTP API User Guide v8): `POST /api.cgi?cmd=<Cmd>&token=<t>` with
/// `[{"cmd":…,"action":0,"param":…}]`. Logs in with `cmd=Login` (the password travels in the POST body, never in a
/// URL), reuses the token and refreshes it a minute before its lease (3600 s) ends, and logs in again when the camera
/// answers "please login first" (-6) or "error token" (-21).
///
/// Cameras allow only a few API sessions, and every login holds one for its whole lease, so one `ReolinkAPI` (one
/// token) serves a driver's probe, snapshots and event polling, and one serves a whole setup run or security check
/// (`CameraSettingsService.reolink()`); concurrent callers share one in-flight login; `logout()` ends the session.
///
/// Answers, as the v8 error table (§4.1) and reolink_aio read them: a command succeeded when `code` is 0 and, for a
/// setting, `value.rspCode` is 200 (any other `rspCode` is a refusal); the camera's `detail` is kept with a refusal
/// (`answer(_:param:action:)`). Wrong credentials: -7, -27, -501, -502, or a detail saying "password wrong" (`.unauthorized`).
/// The camera's own lock: -503 "login deny", -506 "login locked", or a detail saying "locked" (`.lockedOut`; no login for
/// 30 minutes). After -5 "max session", -105 "Frequent logins", -500 (too many addresses) or -507 (too many logins) no
/// login is attempted for `sessionLimitCooldown` (every attempt would fail and could only prolong the lockout or the
/// throttling). -12, -13 and -17 (a camera that did not get the command: a Wi-Fi or battery camera waking up) are asked
/// once more after `transientRetryDelay`. A setting (`Set…`) refused with a credential code once the session's login
/// worked is one this account may not make (`.notPermitted`), not a wrong password.
///
/// A camera (a Wi-Fi doorbell above all) serves only a few HTTP connections at a time, so requests to one camera go
/// through one gate, one at a time, whichever `ReolinkAPI` (the driver's, a settings change's) sends them
/// (`CameraHTTPGates`). With a `CameraReachability` attached nothing is sent while the camera is known to be unreachable
/// (`CameraOfflineError`), and what each request shows (an answer, or silence) is reported to it.
actor ReolinkAPI {
    static let reloginCodes: Set<Int> = [-6, -21]
    /// Answers about the user name or password: -7 "login failed", -27 "invalid user", -501 "the user does not exist", -502 "password err".
    static let credentialCodes: Set<Int> = [-7, -27, -501, -502]
    /// The camera's own lock of its logins: -503 "login deny", -506 "login locked".
    static let lockoutCodes: Set<Int> = [-503, -506]
    /// How long no login is sent after the camera locked its logins (every attempt could prolong the lock).
    static let lockoutPause: TimeInterval = 30 * 60
    /// Answers about the camera itself, which no retry changes: -9 "not support", -26 "ability error" (Reolink HTTP API v8).
    static let unsupportedCodes: Set<Int> = [-9, -26]
    static let sessionLimitCode = -5
    static let frequentLoginsCode = -105
    /// Login answers after which logins pause for `sessionLimitCooldown`: -5 "max session", -105 "Frequent logins, please try again later!",
    /// -500 "the number of IP addresses reaches the upper limit", -507 "the number of logins reached the upper limit".
    static let loginCooldownCodes: Set<Int> = [sessionLimitCode, frequentLoginsCode, -500, -507]
    /// Answers of a camera that did not get the command (-12 "get config failed", -13 "set config failed", -17 "rcv failed"): asked once
    /// more, as reolink_aio does for battery and Wi-Fi cameras.
    static let transientCodes: Set<Int> = [-12, -13, -17]

    let endpoint: CameraEndpoint
    let channel: Int
    let cameraID: UUID?
    private let credentials: HTTPCredentials?
    private let http: AuthenticatingHTTPClient
    private let now: @Sendable () -> Date
    private let sessionLimitCooldown: TimeInterval
    private let transientRetryDelay: Duration
    private var token: String?
    private var refreshAt = Date.distantPast
    private var loginTask: Task<String, any Error>?
    /// Until when no login is attempted, the camera's answer that started the pause, and whether it is the camera's own lock.
    private var loginBlocked: (until: Date, code: Int, locked: Bool)?
    private let log: Log
    /// Shared by every `ReolinkAPI` of this camera's address: one request at a time.
    private let gate: AsyncSerialLock
    nonisolated let reachability: CameraReachability?

    /// `cameraID`: the camera this session serves (its log lines are tagged with it).
    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, channel: Int = 0, timeout: Duration = .seconds(10),
         sessionLimitCooldown: TimeInterval = 300, transientRetryDelay: Duration = .seconds(1), cameraID: UUID? = nil,
         reachability: CameraReachability? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.channel = channel
        self.cameraID = cameraID
        self.reachability = reachability
        self.gate = CameraHTTPGates.gate(for: endpoint)
        self.http = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        self.sessionLimitCooldown = sessionLimitCooldown
        self.transientRetryDelay = transientRetryDelay
        self.now = now
        self.log = Log(category: "reolink", cameraID: cameraID)
    }

    /// One request: never while the camera is known to be unreachable, never alongside another to the same camera, and
    /// what it showed goes to the reachability.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if reachability?.isOffline == true { throw CameraOfflineError() }
        let http = http
        let reachability = reachability
        let result: Result<(Data, HTTPURLResponse), any Error>? = await gate.withLockUnlessCancelled {
            if reachability?.isOffline == true { return .failure(CameraOfflineError()) }
            do {
                return .success(try await CameraHTTP.send(http, request))
            } catch {
                return .failure(error)
            }
        }
        guard let result else { throw CancellationError() }
        if let reachability {
            switch result {
            case .success:
                reachability.reportReachable()
            case .failure(let error):
                reachability.report(adapterError: error)
            }
        }
        return try result.get()
    }

    private func apiURL(_ cmd: String, path: String = "/api.cgi", token: String?, extra: [URLQueryItem] = []) throws -> URL {
        var query = [URLQueryItem(name: "cmd", value: cmd)] + extra
        if let token { query.append(URLQueryItem(name: "token", value: token)) }
        guard let url = endpoint.httpURL(path: path, query: query) else { throw CameraAdapterError.invalidResponse("invalid camera address") }
        return url
    }

    /// Logs in (joining a login already in flight) and returns the new token.
    @discardableResult
    func login() async throws -> String {
        if let loginTask { return try await loginTask.value }
        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { if loginTask == task { loginTask = nil } }
        return try await task.value
    }

    /// The current token, logging in when there is none or its lease is about to end.
    func validToken() async throws -> String {
        if let token, now() < refreshAt { return token }
        return try await login()
    }

    private func performLogin() async throws -> String {
        guard let credentials else { throw CameraAdapterError.unauthorized }
        if let loginBlocked, now() < loginBlocked.until {
            throw loginBlocked.locked ? CameraAdapterError.lockedOut(until: loginBlocked.until)
                : CameraAdapterError.apiError(command: "Login", code: loginBlocked.code)
        }
        let body = JSONValue.array([.object([
            "cmd": .string("Login"),
            "param": .object(["User": .object(["Version": .string("0"), "userName": .string(credentials.username),
                                               "password": .string(credentials.password)])]),
        ])])
        let request = CameraHTTP.request(try apiURL("Login", token: nil), method: "POST", body: try JSONEncoder().encode(body),
                                         contentType: "application/json")
        let (data, _) = try await send(request)
        switch try Self.parse(data, command: "Login") {
        case .refused(let code, let detail) where Self.isLockout(code, detail: detail):
            let until = now().addingTimeInterval(Self.lockoutPause)
            loginBlocked = (until, code, true)
            log.warning("Reolink \(endpoint.host): the camera locked its logins (error \(code)); next login attempt in \(Int(Self.lockoutPause / 60)) min")
            throw CameraAdapterError.lockedOut(until: until)
        case .refused(let code, let detail) where Self.isCredentialRefusal(code, detail: detail):
            throw CameraAdapterError.unauthorized
        case .refused(let code, _) where Self.loginCooldownCodes.contains(code):
            loginBlocked = (now().addingTimeInterval(sessionLimitCooldown), code, false)
            let reason = code == Self.sessionLimitCode ? "reached its maximum number of API sessions"
                : code == -500 ? "takes no more addresses for now" : "refuses logins for now (too many logins)"
            log.warning("Reolink \(endpoint.host): the camera \(reason); next login attempt in \(Int(sessionLimitCooldown)) s")
            throw CameraAdapterError.apiError(command: "Login", code: code)
        case .refused(let code, _):
            throw CameraAdapterError.apiError(command: "Login", code: code)
        case .value(let value, _):
            guard let name = value["Token"]?["name"]?.string, !name.isEmpty else { throw CameraAdapterError.invalidResponse("login without token") }
            let lease = TimeInterval(min(86_400, max(10, value["Token"]?["leaseTime"]?.int ?? 3600)))
            token = name
            refreshAt = now().addingTimeInterval(lease - min(60, lease / 2))
            loginBlocked = nil
            log.debug("logged in (lease \(Int(lease)) s)")
            return name
        }
    }

    /// A login answer saying the user name or password is wrong: a credential code, or reolink_aio's "password wrong" and "login failed".
    static func isCredentialRefusal(_ code: Int, detail: String?) -> Bool {
        if credentialCodes.contains(code) { return true }
        let words = detail?.lowercased() ?? ""
        return words.contains("password wrong") || words.contains("login failed") || words.contains("invalid user")
    }

    /// A login answer saying the camera locked its logins: a lockout code, or a detail such as "Login has been locked".
    static func isLockout(_ code: Int, detail: String?) -> Bool {
        lockoutCodes.contains(code) || detail?.lowercased().contains("locked") == true
    }

    /// Forgets `rejected` (the camera no longer accepts it); a newer token obtained meanwhile is kept.
    func invalidateToken(_ rejected: String) {
        if token == rejected { token = nil }
    }

    /// Ends the API session (best effort) so it does not hold one of the camera's few sessions until its lease ends.
    func logout() async {
        guard let current = token else { return }
        if reachability?.isOffline == true { token = nil; refreshAt = .distantPast; return }   // the session is gone with the camera
        token = nil
        refreshAt = .distantPast
        let body = JSONValue.array([.object(["cmd": .string("Logout"), "action": .number(0), "param": .object([:])])])
        guard let url = try? apiURL("Logout", token: current), let data = try? JSONEncoder().encode(body) else { return }
        _ = try? await send(CameraHTTP.request(url, method: "POST", body: data, contentType: "application/json"))
        log.debug("logged out")
    }

    /// Runs one command and returns its `value`. Throws `.apiError` for other error codes (`answer` keeps the camera's detail).
    func command(_ cmd: String, param: JSONValue? = nil, action: Int = 0) async throws -> JSONValue {
        switch try await answer(cmd, param: param, action: action) {
        case .value(let value, _): return value
        case .refused(let code, _): throw CameraAdapterError.apiError(command: cmd, code: code)
        }
    }

    /// One command's answer: its value (with the whole element, whose `range` action 1 asks for), or the camera's refusal with its code and
    /// detail, returned so a setting's words can say it. Logs in again once after -6 or -21, and asks once more after -12, -13 or -17.
    /// Throws `.unauthorized` for wrong credentials, `.notPermitted(cmd)` for a setting the account may not make (a credential answer to a
    /// `Set…` once the session's login worked), and transport failures.
    func answer(_ cmd: String, param: JSONValue? = nil, action: Int = 0) async throws -> Answer {
        var relogged = false
        var retried = false
        while true {
            let token = try await validToken()
            var entry: [String: JSONValue] = ["cmd": .string(cmd), "action": .number(Double(action))]
            if let param { entry["param"] = param }
            let request = CameraHTTP.request(try apiURL(cmd, token: token), method: "POST",
                                             body: try JSONEncoder().encode(JSONValue.array([.object(entry)])), contentType: "application/json")
            let (data, _) = try await send(request)
            let answer = try Self.parse(data, command: cmd)
            guard case .refused(let code, let detail) = answer else { return answer }
            if Self.reloginCodes.contains(code), !relogged {
                relogged = true
                invalidateToken(token)
                continue
            }
            if Self.credentialCodes.contains(code) {
                guard cmd.hasPrefix("Set") else { throw CameraAdapterError.unauthorized }
                log.info("Reolink \(cmd): the camera does not let this account make the change (error \(code))")
                throw CameraAdapterError.notPermitted(cmd)
            }
            if Self.transientCodes.contains(code), !retried {
                retried = true
                log.debug("Reolink \(cmd): error \(code) (the camera did not get it); asking once more")
                try await Task.sleep(for: transientRetryDelay)
                continue
            }
            if cmd.hasPrefix("Set") { log.info("Reolink \(cmd): the camera refused it (error \(code)\(detail.map { ": \($0)" } ?? ""))") }
            return answer
        }
    }

    /// `GET /cgi-bin/api.cgi?cmd=Snap&channel=<n>&rs=<random>&token=…` → JPEG.
    func snapshot() async throws -> Data {
        for attempt in 0..<2 {
            let token = try await validToken()
            let random = String(UInt64.random(in: 0...UInt64.max), radix: 36)
            let url = try apiURL("Snap", path: "/cgi-bin/api.cgi", token: token,
                                 extra: [URLQueryItem(name: "channel", value: String(channel)), URLQueryItem(name: "rs", value: random)])
            let (data, response) = try await send(CameraHTTP.request(url))
            let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if type.contains("image") || CameraHTTP.looksLikeJPEG(data) { return data }
            if case .refused(let code, _)? = try? Self.parse(data, command: "Snap") {
                if Self.reloginCodes.contains(code) && attempt == 0 { invalidateToken(token); continue }
                throw CameraAdapterError.apiError(command: "Snap", code: code)
            }
            throw CameraAdapterError.invalidResponse("snapshot is not an image")
        }
        throw CameraAdapterError.unauthorized
    }

    /// One command's answer as `parse` reads it.
    enum Answer: Sendable, Equatable {
        /// `value` (else `initial`), and the whole element (`range` is there for action 1).
        case value(JSONValue, element: JSONValue)
        /// The camera's `rspCode` and `detail` (cut, control characters removed: camera text).
        case refused(code: Int, detail: String?)
    }

    enum CommandResult: Sendable {
        case success(JSONValue)
        case failure(Int)
    }

    /// The first element of a response array (or a bare object): its value when `code` is 0 and, for a setting, `value.rspCode` is 200
    /// (the guide's success; reolink_aio's `send_setting` checks it too); else `error.rspCode` (or `value.rspCode`) with the detail.
    static func parse(_ data: Data, command: String) throws -> Answer {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw CameraAdapterError.invalidResponse("\(command): not JSON") }
        guard let first = json[0] ?? (json.object != nil ? json : nil) else { throw CameraAdapterError.invalidResponse("\(command): empty") }
        func detail(_ value: JSONValue?) -> String? { value?.string.map { Redact.cameraText($0, limit: 80) } }
        if let code = first["code"]?.int, code != 0 || first["error"] != nil {
            return .refused(code: first["error"]?["rspCode"]?.int ?? -code, detail: detail(first["error"]?["detail"]))
        }
        if let error = first["error"] { return .refused(code: error["rspCode"]?.int ?? -1, detail: detail(error["detail"])) }
        let value = first["value"] ?? first["initial"] ?? .null
        if let code = value["rspCode"]?.int, code != 200 { return .refused(code: code, detail: detail(value["detail"])) }
        return .value(value, element: first)
    }

    /// `parse` without the detail.
    static func firstResponse(_ data: Data, command: String) throws -> CommandResult {
        switch try parse(data, command: command) {
        case .value(let value, _): .success(value)
        case .refused(let code, _): .failure(code)
        }
    }
}
