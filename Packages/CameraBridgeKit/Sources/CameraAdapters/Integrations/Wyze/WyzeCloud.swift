import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one JSON POST to Wyze. Replaced in tests.
public protocol WyzeTransport: Sendable {
    func post(_ url: URL, headers: [String: String], json: Data) async throws -> (status: Int, body: Data)
}

/// The live transport: `AuthenticatingHTTPClient` without credentials, certificate checks on, 30 s per round trip, answers up to 4 MiB.
/// Errors are thrown without the request address (it can hold a session ID).
public struct URLSessionWyzeTransport: WyzeTransport {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    public func post(_ url: URL, headers: [String: String], json: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = json
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: timeout, allowSelfSignedTLS: false, maximumBodySize: 4 << 20)
        defer { client.invalidate() }
        do {
            let (data, response) = try await client.data(for: request)
            return (response.statusCode, data)
        } catch {
            throw URLFreeErrors.sanitized(error, request: "Wyze request")
        }
    }
}

/// The Wyze cloud, for the Wyze plugin: sign in (with two-step verification), keep the session fresh, list the cameras. Only what
/// the plugin needs to reach a camera locally (RTSP, or go2rtc's local connection); streaming never goes through the cloud.
///
/// Endpoints (the same calls go2rtc's `pkg/wyze/cloud.go` (MIT), wyze-sdk (`wyze_sdk/service/auth_service.py`,
/// `api_service.py`) and wyzeapy (`wyze_auth_lib.py`, used by Home Assistant) make):
///
/// 1. `POST https://auth-prod.api.wyze.com/api/user/login`, headers `Keyid`, `Apikey` (the person's own key pair from
///    developer-api-console.wyze.com), body `{"email","password"}` with the password MD5-hashed three times (hex). Answers
///    `access_token`, `refresh_token`, `user_id`; or, with two-step verification on, an empty `access_token` and `mfa_options`
///    (`TotpVerificationCode`, `PrimaryPhone`, `Email`), `mfa_details.totp_apps[0].app_id`, `sms_session_id`, `email_session_id`.
/// 2. A texted code: `POST https://auth-prod.api.wyze.com/user/login/sendSmsCode?mfaPhoneType=Primary&sessionId=<sms_session_id>&userId=<user_id>`
///    with body `{}`; answers `session_id`. An e-mailed code: `POST …/user/login/sendEmailCode?sessionId=<email_session_id>&userId=<user_id>`,
///    answers `session_id` (the same shape; no open-source client documents it, see the README). An authenticator app needs no call.
/// 3. `POST https://auth-prod.api.wyze.com/user/login` (no `/api`), headers `X-API-Key` (the Wyze app's key, as wyzeapy and wyze-sdk
///    send for this step), `Phone-Id`, body `{"email","password","mfa_type","verification_id","verification_code"}`: `verification_id`
///    is the authenticator app's `app_id`, or the `session_id` from step 2. Answers as step 1.
/// 4. Refresh: `POST https://api.wyzecam.com/app/user/refresh_token`, the common app payload (`access_token`, `app_name`, `app_ver`,
///    `app_version`, `phone_id`, `phone_system_type`, `sc`, `sv`, `ts`) plus `refresh_token`; answers `data.access_token`,
///    `data.refresh_token`.
/// 5. Devices: `POST https://api.wyzecam.com/app/v2/home_page/get_object_list`, the common payload; answers `data.device_list`.
///
/// Errors: `code` (string, `"1"` is success) or `errorCode` (number) with `msg` / `description` (`WyzeCloud.failure`). Nothing secret
/// (password, hash, tokens, keys, `enr`) is ever put in an error or logged.
public actor WyzeCloud {
    static let authBase = "https://auth-prod.api.wyze.com"
    static let apiBase = "https://api.wyzecam.com"
    /// The app identity of the common payload (go2rtc's values; wyzeapy's `sc`/`sv`).
    static let appName = "com.hualai.WyzeCam"
    static let appVersion = "2.50.0"
    static let sc = "9f275790cab94a72bd206c8876429f3c"
    static let sv = "9d74946e652647e9b6c9d59326aef104"
    /// The `X-API-Key` the Wyze app sends for the second sign-in step (wyzeapy's `const.API_KEY`); not a secret of the person.
    static let appAPIKey = "WMXHYf79Nr5gIlt3r0r7p9Tcw5bvs6BB4U8O8nGJ"
    static let appInfo = "wyze_android_2.19.14"
    static let userAgent = "CameraBridge"

    private let transport: any WyzeTransport
    let now: @Sendable () -> Date
    /// A random phone ID for this client (go2rtc and wyzeapy make one per run too).
    let phoneID: String

    public init(transport: some WyzeTransport = URLSessionWyzeTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
        self.phoneID = UUID().uuidString.lowercased()
    }

    /// Wyze's password hash: MD5 three times, as lowercase hex, of the password without surrounding white space (go2rtc, wyze-sdk).
    static func passwordHash(_ password: String) -> String {
        var encoded = password.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 { encoded = WyzeMD5.hex(encoded) }
        return encoded
    }

    // MARK: Sign-in

    public func signIn(email: String, password: String, keys: WyzeAPIKeys) async throws -> WyzeSignIn {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = WyzeAPIKeys(keyID: keys.keyID.trimmingCharacters(in: .whitespacesAndNewlines),
                               apiKey: keys.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !email.isEmpty, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WyzeError.wrongPassword }
        guard !keys.keyID.isEmpty, !keys.apiKey.isEmpty else { throw WyzeError.badAPIKey }
        let hash = Self.passwordHash(password)
        let headers = ["Content-Type": "application/json", "Keyid": keys.keyID, "Apikey": keys.apiKey, "User-Agent": Self.userAgent]
        let json = try await post(Self.authBase + "/api/user/login", headers: headers, body: ["email": .string(email), "password": .string(hash)],
                                  context: .login, secrets: [password, hash, keys.keyID, keys.apiKey])
        if let session = session(from: json, email: email, keys: keys, userID: nil) { return .signedIn(session) }
        guard case .array(let options)? = json["mfa_options"], !options.isEmpty else { throw WyzeError.unreadableAnswer }
        let kinds = options.compactMap { $0.string.flatMap(WyzeVerification.Kind.init(wyzeName:)) }
        guard !kinds.isEmpty else { throw WyzeError.server("two-step verification of a kind Camera Bridge does not know") }
        let verification = WyzeVerification(kinds: kinds, email: email, passwordHash: hash, keys: keys, userID: Self.text(json["user_id"]),
                                            smsSessionID: Self.text(json["sms_session_id"]), emailSessionID: Self.text(json["email_session_id"]),
                                            totpAppID: Self.text(json["mfa_details"]?["totp_apps"]?[0]?["app_id"]), phoneID: phoneID)
        return .needsVerification(verification)
    }

    /// For a texted or e-mailed code: asks Wyze to send it, and returns the verification to finish with. An authenticator app's code
    /// needs nothing sent (returned unchanged).
    public func sendCode(_ verification: WyzeVerification, kind: WyzeVerification.Kind) async throws -> WyzeVerification {
        guard verification.kinds.contains(kind) else { throw WyzeError.server("the account does not use that kind of two-step verification") }
        var result = verification
        let path: String
        var query: [URLQueryItem] = []
        switch kind {
        case .authenticatorApp:
            return verification
        case .textMessage:
            guard let session = verification.smsSessionID, let user = verification.userID else { throw WyzeError.unreadableAnswer }
            path = "/user/login/sendSmsCode"
            query = [URLQueryItem(name: "mfaPhoneType", value: "Primary"), URLQueryItem(name: "sessionId", value: session),
                     URLQueryItem(name: "userId", value: user)]
        case .email:
            guard let session = verification.emailSessionID, let user = verification.userID else { throw WyzeError.unreadableAnswer }
            path = "/user/login/sendEmailCode"
            query = [URLQueryItem(name: "sessionId", value: session), URLQueryItem(name: "userId", value: user)]
        }
        var components = URLComponents(string: Self.authBase + path)
        components?.queryItems = query
        guard let address = components?.string else { throw WyzeError.unreadableAnswer }
        // Both header sets: wyzeapy sends the person's key pair here, wyze-sdk the app's key and phone ID.
        let headers = verificationHeaders(verification).merging(["Keyid": verification.keys.keyID, "Apikey": verification.keys.apiKey]) { $1 }
        let json = try await post(address, headers: headers, body: [:], context: .sendCode, secrets: secrets(of: verification))
        guard let id = Self.text(json["session_id"]) ?? Self.text(json["data"]?["session_id"]) else { throw WyzeError.unreadableAnswer }
        switch kind {
        case .textMessage: result.textVerificationID = id
        case .email: result.emailVerificationID = id
        case .authenticatorApp: break
        }
        return result
    }

    /// The second sign-in step with the code the person entered (spaces and dashes are ignored).
    public func verify(_ verification: WyzeVerification, kind: WyzeVerification.Kind, code: String) async throws -> WyzeSession {
        let digits = code.filter { !$0.isWhitespace && $0 != "-" }
        guard !digits.isEmpty, digits.count <= 12, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw WyzeError.verificationFailed }
        guard verification.kinds.contains(kind) else { throw WyzeError.server("the account does not use that kind of two-step verification") }
        let verificationID: String
        switch kind {
        case .authenticatorApp:
            guard let id = verification.totpAppID else { throw WyzeError.unreadableAnswer }
            verificationID = id
        case .textMessage:
            guard let id = verification.textVerificationID else { throw WyzeError.codeNotRequested }
            verificationID = id
        case .email:
            guard let id = verification.emailVerificationID else { throw WyzeError.codeNotRequested }
            verificationID = id
        }
        let body: [String: JSONValue] = ["email": .string(verification.email), "password": .string(verification.passwordHash),
                                         "mfa_type": .string(kind.wyzeName), "verification_id": .string(verificationID),
                                         "verification_code": .string(digits)]
        let json = try await post(Self.authBase + "/user/login", headers: verificationHeaders(verification), body: body, context: .verification,
                                  secrets: secrets(of: verification) + [digits])
        guard let session = session(from: json, email: verification.email, keys: verification.keys, userID: verification.userID) else {
            throw WyzeError.verificationFailed
        }
        return session
    }

    // MARK: Session

    /// A new access token (and refresh token). `signInExpired` when Wyze no longer accepts the refresh token.
    public func refresh(_ session: WyzeSession) async throws -> WyzeSession {
        var body = commonPayload(accessToken: session.accessToken, phoneID: session.phoneID)
        body["refresh_token"] = .string(session.refreshToken)
        let json = try await post(Self.apiBase + "/app/user/refresh_token", headers: Self.apiHeaders, body: body, context: .refresh,
                                  secrets: [session.accessToken, session.refreshToken, session.keys.apiKey, session.keys.keyID])
        guard let access = Self.text(json["data"]?["access_token"]), let refresh = Self.text(json["data"]?["refresh_token"]) else {
            throw WyzeError.unreadableAnswer
        }
        var renewed = session
        renewed.accessToken = access
        renewed.refreshToken = refresh
        if let user = Self.text(json["data"]?["user_id"]) { renewed.userID = user }
        renewed.obtained = now()
        return renewed
    }

    /// Every camera on the account (product type `Camera`), Gwell models included (marked `unsupported`). `accessTokenExpired` when the
    /// session needs `refresh` first.
    public func devices(_ session: WyzeSession) async throws -> [WyzeDevice] {
        let json = try await post(Self.apiBase + "/app/v2/home_page/get_object_list", headers: Self.apiHeaders,
                                  body: commonPayload(accessToken: session.accessToken, phoneID: session.phoneID), context: .api,
                                  secrets: [session.accessToken, session.refreshToken, session.keys.apiKey, session.keys.keyID])
        guard let data = json["data"] else { throw WyzeError.unreadableAnswer }
        return Self.parseDevices(data)
    }

    static func parseDevices(_ data: JSONValue) -> [WyzeDevice] {
        guard case .array(let list)? = data["device_list"] else { return [] }
        return list.compactMap { device in
            guard device["product_type"]?.string == "Camera", let mac = text(device["mac"]), let model = text(device["product_model"]) else { return nil }
            let params = device["device_params"]
            let ip = text(params?["ip"]).flatMap { address in
                address.utf8.count <= 64 && address.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == ":") }) ? address : nil
            }
            return WyzeDevice(mac: mac, nickname: text(device["nickname"]) ?? WyzeModels.name(for: model), productModel: model,
                              firmware: text(device["firmware_ver"]) ?? "", ip: ip, p2pID: text(params?["p2p_id"]), enr: text(device["enr"]),
                              dtls: params?["dtls"]?.double == 1, online: device["conn_state"]?.double == 1)
        }
    }

    // MARK: Plumbing

    /// The transport's POST, for calls that must sign the exact bytes they send (`gwellAccess`).
    func transportPost(_ url: URL, headers: [String: String], json: Data) async throws -> (status: Int, body: Data) {
        try await transport.post(url, headers: headers, json: json)
    }

    enum Context { case login, sendCode, verification, refresh, api }

    private static let apiHeaders = ["Content-Type": "application/json", "User-Agent": userAgent]

    private func verificationHeaders(_ verification: WyzeVerification) -> [String: String] {
        ["Content-Type": "application/json", "X-API-Key": Self.appAPIKey, "Phone-Id": verification.phoneID, "User-Agent": Self.appInfo]
    }

    private func secrets(of verification: WyzeVerification) -> [String] {
        [verification.passwordHash, verification.keys.apiKey, verification.keys.keyID, verification.totpAppID, verification.smsSessionID,
         verification.emailSessionID, verification.textVerificationID, verification.emailVerificationID, verification.userID].compactMap { $0 }
    }

    private func commonPayload(accessToken: String, phoneID sessionPhoneID: String? = nil) -> [String: JSONValue] {
        ["access_token": .string(accessToken), "app_name": .string(Self.appName), "app_ver": .string(Self.appName + "___" + Self.appVersion),
         "app_version": .string(Self.appVersion), "phone_id": .string(sessionPhoneID ?? phoneID), "phone_system_type": .number(1), "sc": .string(Self.sc),
         "sv": .string(Self.sv), "ts": .number((now().timeIntervalSince1970 * 1000).rounded())]
    }

    private func session(from json: JSONValue, email: String, keys: WyzeAPIKeys, userID: String?) -> WyzeSession? {
        guard let access = Self.text(json["access_token"]), let refresh = Self.text(json["refresh_token"]) else { return nil }
        return WyzeSession(email: email, keys: keys, accessToken: access, refreshToken: refresh, userID: Self.text(json["user_id"]) ?? userID,
                           obtained: now(), phoneID: phoneID)
    }

    private func post(_ address: String, headers: [String: String], body: [String: JSONValue], context: Context,
                      secrets: [String]) async throws -> JSONValue {
        guard let url = URL(string: address) else { throw WyzeError.unreadableAnswer }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(body))
        let status: Int
        let answer: Data
        do {
            (status, answer) = try await transport.post(url, headers: headers, json: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WyzeError {
            throw error
        } catch {
            throw WyzeError.network(Self.scrub(URLFreeErrors.describe(error), secrets: secrets))
        }
        return try Self.check(status: status, body: answer, context: context, secrets: secrets)
    }

    /// The answer as JSON, or the error it reports.
    static func check(status: Int, body: Data, context: Context, secrets: [String]) throws -> JSONValue {
        let json = try? JSONValue.parse(body)
        let code = json.flatMap { text($0["code"]) }
        let errorCode = json.flatMap { text($0["errorCode"]) }
        let message = json.flatMap { text($0["msg"]) ?? text($0["description"]) ?? text($0["message"]) } ?? ""
        let failedCode: String? = if let code, code != "1", code != "0" { code } else if code == nil, let errorCode, errorCode != "0" { errorCode } else { nil }
        if failedCode != nil || !(200..<300).contains(status) {
            throw failure(code: failedCode, message: message, status: status, context: context, secrets: secrets)
        }
        guard let json, case .object = json else { throw WyzeError.unreadableAnswer }
        return json
    }

    /// Wyze's error codes and messages (wyze-sdk `WyzeResponse.validate`, wyzeapy `ResponseCodes`, jfarmer08/wyze-api, go2rtc):
    /// `1000` with "Invalid User Name or Password." / `UserNameOrPasswordError` (wrong password), "Too many failed attempts" (rate
    /// limited), `UserIsLocked`, "Invalid credentials, please check username, password, keyid or apikey"; `1001` / `1004` (bad
    /// parameters); `2001` / `AccessTokenError` (expired access token); `3044` (rate limited). HTTP 401/403 at login: the key pair.
    static func failure(code: String?, message: String, status: Int, context: Context, secrets: [String]) -> WyzeError {
        let lower = message.lowercased()
        if code == "3044" || status == 429 || lower.contains("too many") || lower.contains("rate limit") { return .rateLimited }
        if lower.contains("userislocked") || lower.contains("locked") { return .accountLocked }
        let tokenError = code == "2001" || code == "2002" || lower.contains("accesstoken") || lower.contains("access token")
            || lower.contains("refreshtoken") || lower.contains("refresh token")
        switch context {
        case .refresh:
            if tokenError || code == "1001" || status == 401 || status == 403 { return .signInExpired }
        case .api:
            if tokenError || status == 401 { return .accessTokenExpired }
        case .verification:
            if !lower.contains("keyid") && !lower.contains("apikey") { return .verificationFailed }
        case .login, .sendCode:
            break
        }
        if lower.contains("usernameorpassworderror") || lower.contains("invalid user name or password") || lower.contains("password is incorrect") {
            return .wrongPassword
        }
        if lower.contains("keyid") || lower.contains("apikey") || lower.contains("api key") || lower.contains("api_key") {
            return lower.contains("password") ? .credentialsRejected : .badAPIKey
        }
        if context == .login, status == 401 || status == 403 { return .badAPIKey }
        let shown = scrub(Redact.cameraText(Redact.string(message), limit: 100), secrets: secrets)
        switch (shown.isEmpty, code) {
        case (false, let code?): return .server("\(shown), code \(Redact.cameraText(code, limit: 12))")
        case (false, nil): return .server(shown)
        case (true, let code?): return .server("code \(Redact.cameraText(code, limit: 12))")
        case (true, nil): return .server("HTTP \(status)")
        }
    }

    /// `text` with every secret (at least 4 characters long) masked.
    static func scrub(_ text: String, secrets: [String]) -> String {
        secrets.filter { $0.count >= 4 }.reduce(text) { $0.replacingOccurrences(of: $1, with: "***") }
    }

    /// A non-empty string (or integral number) value.
    static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
