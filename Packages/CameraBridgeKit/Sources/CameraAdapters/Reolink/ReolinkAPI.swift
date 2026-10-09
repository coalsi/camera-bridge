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
/// token) serves a driver's probe, snapshots and event polling; concurrent callers share one in-flight login;
/// `logout()` ends the session; and after "max session number reached" (-5) or "Frequent logins, please try again
/// later!" (-105, API v8 error table) no login is attempted for `sessionLimitCooldown` (every attempt would fail and
/// could only prolong the lockout or the throttling).
///
/// A camera (a Wi-Fi doorbell above all) serves only a few HTTP connections at a time, so requests to one camera go
/// through one gate, one at a time, whichever `ReolinkAPI` (the driver's, a settings change's) sends them
/// (`CameraHTTPGates`). With a `CameraReachability` attached nothing is sent while the camera is known to be unreachable
/// (`CameraOfflineError`), and what each request shows (an answer, or silence) is reported to it.
actor ReolinkAPI {
    static let reloginCodes: Set<Int> = [-6, -21]
    static let credentialCodes: Set<Int> = [-7, -27]
    /// Answers about the camera itself, which no retry changes: -9 "not support", -26 "ability error" (Reolink HTTP API v8).
    static let unsupportedCodes: Set<Int> = [-9, -26]
    static let sessionLimitCode = -5
    static let frequentLoginsCode = -105
    /// Login answers after which logins pause for `sessionLimitCooldown`.
    static let loginCooldownCodes: Set<Int> = [sessionLimitCode, frequentLoginsCode]

    let endpoint: CameraEndpoint
    let channel: Int
    let cameraID: UUID?
    private let credentials: HTTPCredentials?
    private let http: AuthenticatingHTTPClient
    private let now: @Sendable () -> Date
    private let sessionLimitCooldown: TimeInterval
    private var token: String?
    private var refreshAt = Date.distantPast
    private var loginTask: Task<String, any Error>?
    /// Until when no login is attempted, and the camera's answer that started the pause (-5 or -105).
    private var loginBlocked: (until: Date, code: Int)?
    private let log: Log
    /// Shared by every `ReolinkAPI` of this camera's address: one request at a time.
    private let gate: AsyncSerialLock
    nonisolated let reachability: CameraReachability?

    /// `cameraID`: the camera this session serves (its log lines are tagged with it).
    init(endpoint: CameraEndpoint, credentials: HTTPCredentials?, channel: Int = 0, timeout: Duration = .seconds(10),
         sessionLimitCooldown: TimeInterval = 300, cameraID: UUID? = nil, reachability: CameraReachability? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.channel = channel
        self.cameraID = cameraID
        self.reachability = reachability
        self.gate = CameraHTTPGates.gate(for: endpoint)
        self.http = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
        self.sessionLimitCooldown = sessionLimitCooldown
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
            throw CameraAdapterError.apiError(command: "Login", code: loginBlocked.code)
        }
        let body = JSONValue.array([.object([
            "cmd": .string("Login"),
            "param": .object(["User": .object(["Version": .string("0"), "userName": .string(credentials.username),
                                               "password": .string(credentials.password)])]),
        ])])
        let request = CameraHTTP.request(try apiURL("Login", token: nil), method: "POST", body: try JSONEncoder().encode(body),
                                         contentType: "application/json")
        let (data, _) = try await send(request)
        switch try Self.firstResponse(data, command: "Login") {
        case .failure(let code) where Self.credentialCodes.contains(code):
            throw CameraAdapterError.unauthorized
        case .failure(let code) where Self.loginCooldownCodes.contains(code):
            loginBlocked = (now().addingTimeInterval(sessionLimitCooldown), code)
            let reason = code == Self.sessionLimitCode ? "reached its maximum number of API sessions"
                : "refuses logins for now (too many logins)"
            log.warning("Reolink \(endpoint.host): the camera \(reason); next login attempt in \(Int(sessionLimitCooldown)) s")
            throw CameraAdapterError.apiError(command: "Login", code: code)
        case .failure(let code):
            throw CameraAdapterError.apiError(command: "Login", code: code)
        case .success(let value):
            guard let name = value["Token"]?["name"]?.string, !name.isEmpty else { throw CameraAdapterError.invalidResponse("login without token") }
            let lease = TimeInterval(min(86_400, max(10, value["Token"]?["leaseTime"]?.int ?? 3600)))
            token = name
            refreshAt = now().addingTimeInterval(lease - min(60, lease / 2))
            loginBlocked = nil
            log.debug("logged in (lease \(Int(lease)) s)")
            return name
        }
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

    /// Runs one command and returns its `value`. Throws `.apiError` for other error codes.
    func command(_ cmd: String, param: JSONValue? = nil, action: Int = 0) async throws -> JSONValue {
        for attempt in 0..<2 {
            let token = try await validToken()
            var entry: [String: JSONValue] = ["cmd": .string(cmd), "action": .number(Double(action))]
            if let param { entry["param"] = param }
            let request = CameraHTTP.request(try apiURL(cmd, token: token), method: "POST",
                                             body: try JSONEncoder().encode(JSONValue.array([.object(entry)])), contentType: "application/json")
            let (data, _) = try await send(request)
            switch try Self.firstResponse(data, command: cmd) {
            case .success(let value):
                return value
            case .failure(let code) where Self.reloginCodes.contains(code) && attempt == 0:
                invalidateToken(token)
            case .failure(let code) where Self.credentialCodes.contains(code):
                throw CameraAdapterError.unauthorized
            case .failure(let code):
                throw CameraAdapterError.apiError(command: cmd, code: code)
            }
        }
        throw CameraAdapterError.unauthorized
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
            if case .failure(let code)? = try? Self.firstResponse(data, command: "Snap") {
                if Self.reloginCodes.contains(code) && attempt == 0 { invalidateToken(token); continue }
                throw CameraAdapterError.apiError(command: "Snap", code: code)
            }
            throw CameraAdapterError.invalidResponse("snapshot is not an image")
        }
        throw CameraAdapterError.unauthorized
    }

    enum CommandResult: Sendable {
        case success(JSONValue)
        case failure(Int)
    }

    /// The first element of a response array (or a bare object): `value` on `code` 0, else `error.rspCode`.
    static func firstResponse(_ data: Data, command: String) throws -> CommandResult {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw CameraAdapterError.invalidResponse("\(command): not JSON") }
        guard let first = json[0] ?? (json.object != nil ? json : nil) else { throw CameraAdapterError.invalidResponse("\(command): empty") }
        if let code = first["code"]?.int, code != 0 || first["error"] != nil {
            return .failure(first["error"]?["rspCode"]?.int ?? -code)
        }
        if let error = first["error"] { return .failure(error["rspCode"]?.int ?? -1) }
        return .success(first["value"] ?? first["initial"] ?? .null)
    }
}
