import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// A recorded Wyze cloud: answers by request path, records every request.
private final class FakeWyze: WyzeTransport, Sendable {
    struct Request: Sendable {
        var url: URL
        var headers: [String: String]
        var body: [String: Any] {
            (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        }
        var json: Data
    }

    let requests = Box<[Request]>([])
    let answers: [String: (String, Int)]
    let failure: (any Error & Sendable)?

    init(_ answers: [String: (String, Int)], failure: (any Error & Sendable)? = nil) {
        self.answers = answers
        self.failure = failure
    }

    func post(_ url: URL, headers: [String: String], json: Data) async throws -> (status: Int, body: Data) {
        requests.update { $0.append(Request(url: url, headers: headers, json: json)) }
        if let failure { throw failure }
        guard let (body, status) = answers[url.path] else { return (404, Data()) }
        return (status, Data(body.utf8))
    }
}

private struct Failing: Error, CustomStringConvertible {
    var description: String
}

@Suite(.timeLimit(.minutes(1))) struct WyzeCloudTests {
    static let keys = WyzeAPIKeys(keyID: "KEYID-1234-abcd", apiKey: "APIKEY-SECRET-0123456789")
    static let password = "hunter2-Password!"
    static let fixed = Date(timeIntervalSince1970: 1_791_000_000)

    static let loginOK = #"{"access_token":"ACCESS-TOKEN-AAAA","refresh_token":"REFRESH-TOKEN-RRRR","user_id":"user-42","mfa_options":null,"mfa_details":null,"sms_session_id":null,"email_session_id":null}"#
    static let wrongPassword = #"{"errorCode":1000,"description":"Invalid User Name or Password."}"#
    static let mfa = #"""
    {"access_token":"","refresh_token":"","user_id":"user-42","mfa_options":["TotpVerificationCode","PrimaryPhone","Email"],
     "mfa_details":{"totp_apps":[{"app_id":"TOTP-APP-ID-9999","app_name":"Authenticator"}],"phone_numbers":["+1 *** *** 12"]},
     "sms_session_id":"SMS-SESSION-5555","email_session_id":"EMAIL-SESSION-6666"}
    """#
    static let devices = #"""
    {"code":"1","msg":"","data":{"device_list":[
      {"mac":"D03F27A1B2C3","enr":"ENR+/SECRET==","nickname":"Front Yard","product_model":"HL_CAM4","product_type":"Camera",
       "firmware_ver":"4.52.17.19","conn_state":1,"device_params":{"p2p_id":"P2PUID1234567890ABCD","p2p_type":4,"ip":"192.168.1.40","dtls":1}},
      {"mac":"2CAA8E000001","enr":"ENR-V3","nickname":"Garage","product_model":"WYZE_CAKP2JFUS","product_type":"Camera",
       "firmware_ver":"4.36.11.8391","conn_state":1,"device_params":{"p2p_id":"P2PUIDV3000000000000","ip":"192.168.1.41","dtls":1}},
      {"mac":"GW0000000001","enr":"","nickname":"Living Room","product_model":"HL_PAN4","product_type":"Camera",
       "firmware_ver":"1.0.32","conn_state":1,"device_params":{}},
      {"mac":"2CAA8E000002","enr":"ENR-OFF","nickname":"Porch","product_model":"HL_CAM4","product_type":"Camera",
       "firmware_ver":"4.52.9.5332","conn_state":0,"device_params":{"p2p_id":"P2PUIDOFF00000000000","ip":"192.168.1.42","dtls":1}},
      {"mac":"7C78B2000003","nickname":"Lamp","product_model":"WLPP1CFH","product_type":"Plug","firmware_ver":"1.2.0.3","conn_state":1,
       "device_params":{"ip":"192.168.1.50"}}
    ]}}
    """#

    static func integer(_ value: Any?) -> Int64? {
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Int64 { return value }
        return (value as? NSNumber)?.int64Value
    }

    private func cloud(_ fake: FakeWyze) -> WyzeCloud { WyzeCloud(transport: fake, now: { Self.fixed }) }

    @Test func md5MatchesRFC1321() {
        #expect(WyzeMD5.hex("") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(WyzeMD5.hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(WyzeMD5.hex("message digest") == "f96b697d7cb7938d525a2f31aaf161d0")
        #expect(WyzeMD5.hex(String(repeating: "1234567890", count: 8)) == "57edf4a22be3c955ac49da2e2107b67a")
        #expect(WyzeMD5.hex("The quick brown fox jumps over the lazy dog") == "9e107d9d372bb6826bd81d3542a419d6")
        // 55, 56 and 64 bytes: the padding edge cases.
        #expect(WyzeMD5.hex(String(repeating: "a", count: 55)) == "ef1772b6dff9a122358552954ad0df65")
        #expect(WyzeMD5.hex(String(repeating: "a", count: 56)) == "3b0c8ac703f828b04c6c197006d17218")
        #expect(WyzeMD5.hex(String(repeating: "a", count: 64)) == "014842d480b571495a4a0363793f7367")
        // Three rounds, as Wyze takes the password.
        #expect(WyzeCloud.passwordHash(" abc ") == WyzeMD5.hex(WyzeMD5.hex(WyzeMD5.hex("abc"))))
    }

    @Test func signInSendsTheKeysAndTheHashedPassword() async throws {
        let fake = FakeWyze(["/api/user/login": (Self.loginOK, 200)])
        let result = try await cloud(fake).signIn(email: " me@example.com ", password: Self.password, keys: Self.keys)
        guard case .signedIn(let session) = result else { Issue.record("expected a session"); return }
        #expect(session.phoneID?.isEmpty == false, "the session keeps the phone ID it signed in with")
        var expected = WyzeSession(email: "me@example.com", keys: Self.keys, accessToken: "ACCESS-TOKEN-AAAA", refreshToken: "REFRESH-TOKEN-RRRR",
                                   userID: "user-42", obtained: Self.fixed)
        expected.phoneID = session.phoneID
        #expect(session == expected)
        let request = try #require(fake.requests.value.first)
        #expect(request.url.absoluteString == "https://auth-prod.api.wyze.com/api/user/login")
        #expect(request.headers["Keyid"] == Self.keys.keyID && request.headers["Apikey"] == Self.keys.apiKey)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.body["email"] as? String == "me@example.com")
        #expect(request.body["password"] as? String == WyzeCloud.passwordHash(Self.password))
        #expect(!String(decoding: request.json, as: UTF8.self).contains(Self.password))
        #expect(!"\(session)".contains("ACCESS-TOKEN") && !String(reflecting: session).contains("REFRESH-TOKEN"))
    }

    @Test func wrongPasswordAndBadKeys() async throws {
        let wrong = FakeWyze(["/api/user/login": (Self.wrongPassword, 400)])
        await #expect(throws: WyzeError.wrongPassword) { try await cloud(wrong).signIn(email: "me@example.com", password: "x", keys: Self.keys) }
        let locked = FakeWyze(["/api/user/login": (#"{"errorCode":1000,"description":"UserIsLocked"}"#, 400)])
        await #expect(throws: WyzeError.accountLocked) { try await cloud(locked).signIn(email: "me@example.com", password: "x", keys: Self.keys) }
        let tooMany = FakeWyze(["/api/user/login": (#"{"errorCode":1000,"description":"Too many failed attempts, please try again later."}"#, 400)])
        await #expect(throws: WyzeError.rateLimited) { try await cloud(tooMany).signIn(email: "me@example.com", password: "x", keys: Self.keys) }
        let either = FakeWyze(["/api/user/login": (#"{"errorCode":1000,"description":"Invalid credentials, please check username, password, keyid or apikey"}"#, 400)])
        await #expect(throws: WyzeError.credentialsRejected) { try await cloud(either).signIn(email: "me@example.com", password: "x", keys: Self.keys) }
        let badKey = FakeWyze(["/api/user/login": (#"{"message":"Forbidden"}"#, 403)])
        await #expect(throws: WyzeError.badAPIKey) { try await cloud(badKey).signIn(email: "me@example.com", password: "x", keys: Self.keys) }
        let missingKey = FakeWyze([:])
        await #expect(throws: WyzeError.badAPIKey) {
            try await cloud(missingKey).signIn(email: "me@example.com", password: "x", keys: WyzeAPIKeys(keyID: " ", apiKey: "k"))
        }
        #expect(missingKey.requests.value.isEmpty)
        let limited = FakeWyze(["/api/user/login": (#"{"code":"3044","msg":"Too many requests"}"#, 200)])
        await #expect(throws: WyzeError.rateLimited) { try await cloud(limited).signIn(email: "me@example.com", password: "x", keys: Self.keys) }
        let garbage = FakeWyze(["/api/user/login": ("<html>", 200)])
        await #expect(throws: WyzeError.unreadableAnswer) { try await cloud(garbage).signIn(email: "me@example.com", password: "x", keys: Self.keys) }
    }

    @Test func authenticatorAppVerification() async throws {
        let fake = FakeWyze(["/api/user/login": (Self.mfa, 200), "/user/login": (Self.loginOK, 200)])
        let wyze = cloud(fake)
        guard case .needsVerification(let verification) = try await wyze.signIn(email: "me@example.com", password: Self.password, keys: Self.keys) else {
            Issue.record("expected two-step verification"); return
        }
        #expect(verification.kinds == [.authenticatorApp, .textMessage, .email])
        #expect(verification.codeSent(for: .authenticatorApp) && !verification.codeSent(for: .textMessage))
        let shown = "\(verification) \(String(reflecting: verification))"
        for secret in [WyzeCloud.passwordHash(Self.password), Self.keys.apiKey, "TOTP-APP-ID", "SMS-SESSION"] { #expect(!shown.contains(secret)) }
        #expect(try await wyze.sendCode(verification, kind: .authenticatorApp) == verification)
        #expect(fake.requests.value.count == 1, "an authenticator code needs nothing sent")

        let session = try await wyze.verify(verification, kind: .authenticatorApp, code: "123 456")
        #expect(session.accessToken == "ACCESS-TOKEN-AAAA" && session.refreshToken == "REFRESH-TOKEN-RRRR" && session.email == "me@example.com")
        #expect(session.keys == Self.keys && session.userID == "user-42")
        let second = try #require(fake.requests.value.last)
        #expect(second.url.absoluteString == "https://auth-prod.api.wyze.com/user/login")
        #expect(second.headers["X-API-Key"] == WyzeCloud.appAPIKey && second.headers["Phone-Id"] == verification.phoneID)
        #expect(second.body["mfa_type"] as? String == "TotpVerificationCode")
        #expect(second.body["verification_id"] as? String == "TOTP-APP-ID-9999")
        #expect(second.body["verification_code"] as? String == "123456")
        #expect(second.body["password"] as? String == WyzeCloud.passwordHash(Self.password) && second.body["email"] as? String == "me@example.com")

        await #expect(throws: WyzeError.verificationFailed) { try await wyze.verify(verification, kind: .authenticatorApp, code: "abc") }
        let refused = FakeWyze(["/user/login": (#"{"errorCode":1000,"description":"VerificationCodeError"}"#, 400)])
        await #expect(throws: WyzeError.verificationFailed) {
            try await cloud(refused).verify(verification, kind: .authenticatorApp, code: "000000")
        }
    }

    @Test func textAndEmailCodesAreSentFirst() async throws {
        let fake = FakeWyze(["/api/user/login": (Self.mfa, 200), "/user/login/sendSmsCode": (#"{"session_id":"SMS-VERIFY-7777"}"#, 200),
                             "/user/login/sendEmailCode": (#"{"session_id":"EMAIL-VERIFY-8888"}"#, 200), "/user/login": (Self.loginOK, 200)])
        let wyze = cloud(fake)
        guard case .needsVerification(let verification) = try await wyze.signIn(email: "me@example.com", password: Self.password, keys: Self.keys) else {
            Issue.record("expected two-step verification"); return
        }
        await #expect(throws: WyzeError.codeNotRequested) { try await wyze.verify(verification, kind: .textMessage, code: "123456") }

        let texted = try await wyze.sendCode(verification, kind: .textMessage)
        #expect(texted.codeSent(for: .textMessage))
        let sms = try #require(fake.requests.value.last)
        let smsItems = Dictionary(uniqueKeysWithValues: (URLComponents(url: sms.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(sms.url.path == "/user/login/sendSmsCode" && sms.url.host == "auth-prod.api.wyze.com")
        #expect(smsItems == ["mfaPhoneType": "Primary", "sessionId": "SMS-SESSION-5555", "userId": "user-42"])
        #expect(String(decoding: sms.json, as: UTF8.self) == "{}")
        _ = try await wyze.verify(texted, kind: .textMessage, code: "654321")
        let smsLogin = try #require(fake.requests.value.last)
        #expect(smsLogin.body["mfa_type"] as? String == "PrimaryPhone" && smsLogin.body["verification_id"] as? String == "SMS-VERIFY-7777")

        let mailed = try await wyze.sendCode(verification, kind: .email)
        let email = try #require(fake.requests.value.last)
        let emailItems = Dictionary(uniqueKeysWithValues: (URLComponents(url: email.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(email.url.path == "/user/login/sendEmailCode" && emailItems == ["sessionId": "EMAIL-SESSION-6666", "userId": "user-42"])
        _ = try await wyze.verify(mailed, kind: .email, code: "111222")
        let emailLogin = try #require(fake.requests.value.last)
        #expect(emailLogin.body["mfa_type"] as? String == "Email" && emailLogin.body["verification_id"] as? String == "EMAIL-VERIFY-8888")
    }

    @Test func refreshKeepsTheAccountAndRenewsTheTokens() async throws {
        let session = WyzeSession(email: "me@example.com", keys: Self.keys, accessToken: "OLD-ACCESS-1111", refreshToken: "OLD-REFRESH-2222",
                                  userID: "user-42", obtained: Date(timeIntervalSince1970: 0))
        let fake = FakeWyze(["/app/user/refresh_token": (#"{"code":"1","msg":"","data":{"access_token":"NEW-ACCESS-3333","refresh_token":"NEW-REFRESH-4444"}}"#, 200)])
        let renewed = try await cloud(fake).refresh(session)
        #expect(renewed == WyzeSession(email: "me@example.com", keys: Self.keys, accessToken: "NEW-ACCESS-3333", refreshToken: "NEW-REFRESH-4444",
                                       userID: "user-42", obtained: Self.fixed))
        let request = try #require(fake.requests.value.first)
        #expect(request.url.absoluteString == "https://api.wyzecam.com/app/user/refresh_token")
        let body = request.body
        #expect(body["refresh_token"] as? String == "OLD-REFRESH-2222" && body["access_token"] as? String == "OLD-ACCESS-1111")
        for name in ["app_name", "app_ver", "app_version", "phone_id", "sc", "sv"] { #expect(body[name] is String, "\(name)") }
        #expect(Self.integer(body["ts"]) == 1_791_000_000_000 && Self.integer(body["phone_system_type"]) == 1)
        #expect(request.headers["Apikey"] == nil, "the key pair is only for the login")

        let expired = FakeWyze(["/app/user/refresh_token": (#"{"code":"2001","msg":"RefreshTokenError","data":{}}"#, 200)])
        await #expect(throws: WyzeError.signInExpired) { try await cloud(expired).refresh(session) }
    }

    @Test func devicesListsTheCamerasAndHowToReachThem() async throws {
        let session = WyzeSession(email: "me@example.com", keys: Self.keys, accessToken: "ACCESS-TOKEN-AAAA", refreshToken: "R", obtained: Self.fixed)
        let fake = FakeWyze(["/app/v2/home_page/get_object_list": (Self.devices, 200)])
        let devices = try await cloud(fake).devices(session)
        #expect(devices.map(\.mac) == ["D03F27A1B2C3", "2CAA8E000001", "GW0000000001", "2CAA8E000002"], "the plug is left out")
        let v4 = devices[0]
        #expect(v4 == WyzeDevice(mac: "D03F27A1B2C3", nickname: "Front Yard", productModel: "HL_CAM4", modelName: "Wyze Cam v4", firmware: "4.52.17.19",
                                 ip: "192.168.1.40", p2pID: "P2PUID1234567890ABCD", enr: "ENR+/SECRET==", dtls: true, online: true,
                                 connection: .rtspAndLocal))
        #expect(devices[1].modelName == "Wyze Cam v3" && devices[1].connection == .localOnly, "old v3 firmware: no RTSP")
        let pan = devices[2]
        #expect(pan.modelName == "Wyze Cam Pan v4" && pan.connection == .cloud && pan.ip == nil && pan.p2pID == nil && pan.enr == nil,
                "the Pan v4's video only comes through Wyze's cloud")
        #expect(!devices[3].online && devices[3].connection == .localOnly)
        #expect(!"\(v4)".contains("SECRET"))
        let request = try #require(fake.requests.value.first)
        #expect(request.url.absoluteString == "https://api.wyzecam.com/app/v2/home_page/get_object_list")
        #expect(request.body["access_token"] as? String == "ACCESS-TOKEN-AAAA")

        let expired = FakeWyze(["/app/v2/home_page/get_object_list": (#"{"code":"2001","msg":"AccessTokenError","data":{}}"#, 200)])
        await #expect(throws: WyzeError.accessTokenExpired) { try await cloud(expired).devices(session) }
    }

    @Test func networkFailuresAndServerMessagesHoldNoSecret() async throws {
        let session = WyzeSession(email: "me@example.com", keys: Self.keys, accessToken: "ACCESS-TOKEN-AAAA", refreshToken: "REFRESH-TOKEN-RRRR",
                                  obtained: Self.fixed)
        let down = FakeWyze([:], failure: Failing(description: "failed: access_token=ACCESS-TOKEN-AAAA refresh REFRESH-TOKEN-RRRR"))
        do {
            _ = try await cloud(down).devices(session)
            Issue.record("expected a failure")
        } catch let error as WyzeError {
            guard case .network = error else { Issue.record("expected .network, got \(error)"); return }
            #expect(!error.description.contains("ACCESS-TOKEN") && !error.description.contains("REFRESH-TOKEN"))
        }
        // A server message that echoes what was sent.
        let echo = FakeWyze(["/app/v2/home_page/get_object_list": (#"{"code":"1005","msg":"bad request ACCESS-TOKEN-AAAA REFRESH-TOKEN-RRRR"}"#, 200)])
        do {
            _ = try await cloud(echo).devices(session)
            Issue.record("expected a failure")
        } catch let error as WyzeError {
            #expect(error.description.contains("1005"))
            #expect(!error.description.contains("ACCESS-TOKEN") && !error.description.contains("REFRESH-TOKEN"), "\(error)")
        }
        let hash = WyzeCloud.passwordHash(Self.password)
        let all: [WyzeError] = [.wrongPassword, .badAPIKey, .credentialsRejected, .verificationFailed, .codeNotRequested, .rateLimited, .signInExpired,
                                .accessTokenExpired, .accountLocked, .unreadableAnswer,
                                WyzeCloud.failure(code: "9", message: "x \(hash) \(Self.keys.apiKey) ENR+/SECRET==", status: 200, context: .api,
                                                  secrets: [hash, Self.keys.apiKey, "ENR+/SECRET=="])]
        for error in all {
            for secret in [Self.password, hash, Self.keys.apiKey, Self.keys.keyID, "ENR+/SECRET==", "ACCESS-TOKEN"] {
                #expect(!error.description.contains(secret), "\(error)")
            }
            #expect(error.description.hasSuffix("."))
        }
    }

    @Test func firmwareWithRTSP() {
        #expect(WyzeFirmware.hasRTSP(model: "HL_CAM4", firmware: "4.52.17.19"))
        #expect(WyzeFirmware.hasRTSP(model: "HL_CAM4", firmware: "4.52.17.0"))
        #expect(WyzeFirmware.hasRTSP(model: "hl_cam4", firmware: "4.52.18"))
        #expect(WyzeFirmware.hasRTSP(model: "HL_CAM4", firmware: "4.53.0.1"))
        #expect(!WyzeFirmware.hasRTSP(model: "HL_CAM4", firmware: "4.52.9.5332"), "9 < 17 as numbers, not text")
        #expect(!WyzeFirmware.hasRTSP(model: "HL_CAM4", firmware: "4.52.16.9999"))
        #expect(WyzeFirmware.hasRTSP(model: "WYZE_CAKP2JFUS", firmware: "4.36.16.5654"))
        #expect(!WyzeFirmware.hasRTSP(model: "WYZE_CAKP2JFUS", firmware: "4.36.16.5653"))
        #expect(WyzeFirmware.hasRTSP(model: "WYZE_CAKP2JFUS", firmware: "4.36.100.1"))
        #expect(WyzeFirmware.hasRTSP(model: "HL_PAN3", firmware: "4.50.16.5654"))
        #expect(!WyzeFirmware.hasRTSP(model: "HL_PAN3", firmware: "4.50.4.9222"))
        #expect(!WyzeFirmware.hasRTSP(model: "HL_PAN4", firmware: "9.99.99.9999"), "unknown model")
        for broken in ["", "abc", "4.52.x.1", "4..52", " ", "4.52.17.19-beta", "99999999999.1"] {
            #expect(!WyzeFirmware.hasRTSP(model: "HL_CAM4", firmware: broken), "\(broken)")
        }
        #expect(WyzeFirmware.isAtLeast("4.52", "4.52.0.0") && !WyzeFirmware.isAtLeast("4.52", "4.52.0.1"))
        #expect(WyzeModels.connection(model: "GW_GC1", firmware: "4.52.17.19", p2pID: "p", enr: "e", dtls: true) == .gwell)
        #expect(WyzeModels.connection(model: "HL_PAN4", firmware: "4.70.7.4408", p2pID: nil, enr: nil, dtls: false) == .cloud)
        #expect(WyzeModels.connection(model: "HL_CAM4", firmware: "4.52.17.19", p2pID: "p", enr: "e", dtls: false) == .rtspOnly)
        #expect(WyzeModels.connection(model: "HL_CAM4", firmware: "4.52.9.1", p2pID: "p", enr: "e", dtls: false) == .unsupported)
        #expect(WyzeModels.name(for: "HL_DB2") == "Wyze Video Doorbell v2" && WyzeModels.name(for: "HL_CFL2") == "Wyze Cam Floodlight v2")
        #expect(WyzeModels.name(for: "GW_GC2") == "Wyze Cam OG Telephoto" && WyzeModels.name(for: "XYZ_NEW") == "XYZ_NEW")
    }

    @Test func wyzeSourceParsesBack() throws {
        let v4 = WyzeDevice(mac: "D03F27A1B2C3", nickname: "Front Yard", productModel: "HL_CAM4", firmware: "4.52.17.19", ip: "192.168.1.40",
                            p2pID: "P2PUID1234567890ABCD", enr: "ENR+/SECRET==", dtls: true, online: true)
        let hd = try Go2RTCSource.wyze(v4, host: "192.168.1.77", hd: true)
        #expect(hd.url == "wyze://192.168.1.77?dtls=true&enr=ENR%2B%2FSECRET%3D%3D&mac=D03F27A1B2C3&model=HL_CAM4&subtype=hd&uid=P2PUID1234567890ABCD")
        let parsed = try Go2RTCSource(parsing: hd.url)
        #expect(parsed == hd && parsed.service == .wyze && parsed.host == "192.168.1.77")
        #expect(parsed.parameterNames == ["dtls", "enr", "mac", "model", "subtype", "uid"])
        #expect(!hd.description.contains("SECRET"))
        #expect(try Go2RTCSource.wyze(v4, host: "cam.local", hd: false).url.contains("subtype=sd"))

        let pan = WyzeDevice(mac: "GW0000000001", nickname: "Living Room", productModel: "HL_PAN4", firmware: "1.0.32", dtls: false, online: true)
        #expect(throws: Go2RTCSource.Invalid.self) { try Go2RTCSource.wyze(pan, host: "192.168.1.9", hd: true) }
        var noKey = v4
        noKey.enr = nil
        #expect(throws: Go2RTCSource.Invalid.self) { try Go2RTCSource.wyze(noKey, host: "192.168.1.9", hd: true) }
        for host in ["", "a b", "x/y", "u@h", "h?x=1"] {
            #expect(throws: Go2RTCSource.Invalid.self, "\(host)") { try Go2RTCSource.wyze(v4, host: host, hd: true) }
        }
    }

    @Test func neighborTableFindsTheCamera() {
        let table = """
        IP address       HW type     Flags       HW address            Mask     Device
        192.168.1.1      0x1         0x2         a4:91:b1:00:11:22     *        enp1s0
        192.168.1.40     0x1         0x0         00:00:00:00:00:00     *        enp1s0
        192.168.1.33     0x1         0x0         d0:3f:27:a1:b2:c3     *        enp1s0
        192.168.1.41     0x1         0x2         D0:3F:27:A1:B2:C3     *        enp1s0
        192.168.1.42     0x1         0x2         2c:aa:8e:00:00:01     *        enp1s0
        fe80::1          0x1         0x2         2c:aa:8e:00:00:09     *        enp1s0
        """
        #expect(NeighborTable.ipv4(forMAC: "D03F27A1B2C3", in: table) == "192.168.1.41", "the incomplete entry is skipped")
        #expect(NeighborTable.ipv4(forMAC: "2c-aa-8e-00-00-01", in: table) == "192.168.1.42")
        #expect(NeighborTable.ipv4(forMAC: "2CAA8E000009", in: table) == nil)
        #expect(NeighborTable.ipv4(forMAC: "000000000000", in: table) == nil)
        #expect(NeighborTable.ipv4(forMAC: "not a mac", in: table) == nil)
        #expect(NeighborTable.ipv4(forMAC: "D03F27A1B2C3", in: "") == nil)
        #if os(Linux)
        #expect(NeighborTable.read() != nil)
        #else
        #expect(NeighborTable.read() == nil)
        #endif
    }
}
