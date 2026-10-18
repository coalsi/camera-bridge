// A loopback fake camera of the IPCamera Web family (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// The IPCamera Web family's API (docs/integrations/ipcamera-web.md): the cipher and hash against values computed outside Camera Bridge, the
/// query as the camera's own page sends it, the page check that comes before any sign-in, the sign-in and its answer codes (those of the
/// camera's page), one new sign-in when the session is not valid, the latch after a refusal and when it gives the sign-in a new try, and
/// that nothing secret is logged. Against `FakeIPCamWebCamera` only.
@Suite(.timeLimit(.minutes(1))) struct IPCamWebTests {
    final class Capture: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
        var text: String { entries.value.map(\.message).joined(separator: "\n") }
        func text(of cameraID: UUID) -> String { entries.value.filter { $0.cameraID == cameraID }.map(\.message).joined(separator: "\n") }
    }

    private func client(_ camera: FakeIPCamWebCamera, credentials: HTTPCredentials? = nil, cameraID: UUID? = nil) -> IPCamWebClient {
        IPCamWebClient(endpoint: camera.endpoint, credentials: credentials ?? camera.credentials, cameraID: cameraID, timeout: .seconds(5))
    }

    private func bytes(hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count - 1, by: 2).compactMap { UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16) }
    }

    // MARK: The cipher and the hash

    /// RC4 against the published test vectors (Wikipedia's RC4 article) and the sign-in's own values (Python's hashlib and an RC4
    /// written apart; OpenSSL's `rc4-40` agrees).
    @Test func rc4AndTheSignInValueMatchValuesComputedElsewhere() {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(IPCamWebRC4.apply(key: Array("Key".utf8), to: Array("Plaintext".utf8))) == "bbf316e8d940af0ad3")
        #expect(hex(IPCamWebRC4.apply(key: Array("Wiki".utf8), to: Array("pedia".utf8))) == "1021bf0420")
        #expect(hex(IPCamWebRC4.apply(key: Array("Secret".utf8), to: Array("Attack at dawn".utf8))) == "45a01f645fc35b383552544b9bf5")
        #expect(WyzeMD5.hex("admin:pa55word") == "8c7796aa1c0c8a48b36c8c1c445b2040")
        #expect(IPCamWebClient.encrypted(username: "admin", password: "pa55word") == FakeIPCamWebCamera.encrypted)
        #expect(IPCamWebClient.encrypted(username: "admin", password: "") == "6e798ad26672b5a491c78bf9681445a134b0246c9fc091647b4b5b1601c211d0")
        #expect(IPCamWebClient.encrypted(username: "admin", password: #"p@ss"w\d!"#)
            == "6e0bffd36772c3a6e3c5818a6f1443d037b85716e8c690110d4b5f1270c015a1")
    }

    /// The page signs in with `RC4Hex(md5(user + ":" + password))`, and its `md5-min.js` gives the hash in UPPERCASE hex
    /// (`rstr2hex(…).toUpperCase()`). Decrypted, the sign-in value is that, never the lowercase hex: a camera can't match the lowercase one,
    /// whatever the password (Camera Bridge sent that one through build 0.1.110, and the owner's camera refused every sign-in).
    @Test func theSignInValueIsTheUppercaseMD5() {
        for (username, password) in [("admin", "pa55word"), ("admin", ""), ("viewer", "Grüße 1")] {
            let value = IPCamWebClient.encrypted(username: username, password: password)
            let decrypted = String(decoding: IPCamWebRC4.apply(key: IPCamWebClient.signInKey, to: bytes(hex: value)), as: UTF8.self)
            #expect(decrypted == WyzeMD5.hex(username + ":" + password).uppercased())
            #expect(decrypted.count == 32 && decrypted.allSatisfy { $0.isNumber || ("A"..."F").contains($0) }, "uppercase hex digits only")
        }
        let page = String(decoding: IPCamWebRC4.apply(key: Array("pwnsd".utf8), to: bytes(hex: FakeIPCamWebCamera.encrypted)), as: UTF8.self)
        #expect(page == "8C7796AA1C0C8A48B36C8C1C445B2040", "the value computed outside Camera Bridge holds the uppercase hash too")
    }

    /// The page appends the XML to the URL as it is (`AjaxSubmitEx`), and the browser percent-encodes only what a URL's query can't hold (the
    /// WHATWG URL standard's special-query set: controls, space, `"`, `#`, `'`, `<`, `>` and what is not ASCII): `=`, `/`, `?` and `:` stay.
    /// Camera Bridge sends those same bytes, and also encodes what would change the query's meaning (`&`, `+`, `%`) and what a URL can't
    /// carry raw (`[`, `\`, `]`, `^`, `` ` ``, `{`, `|`, `}`), so the camera reads the XML exactly.
    @Test func queryValuesAreEncodedAsTheCamerasPageSendsThem() {
        let xml = "<?xml version='1.0'?><root><mobile on='0'></mobile></root>"
        let encoded = IPCamWebClient.percentEncoded(xml)
        #expect(encoded == "%3C?xml%20version=%271.0%27?%3E%3Croot%3E%3Cmobile%20on=%270%27%3E%3C/mobile%3E%3C/root%3E")
        #expect(encoded.removingPercentEncoding == xml)
        #expect(IPCamWebClient.percentEncoded(#"<rtsp port="554" url='rtsp://h:1/a?b'/>"#) == "%3Crtsp%20port=%22554%22%20url=%27rtsp://h:1/a?b%27/%3E")
        #expect(IPCamWebClient.percentEncoded("a&b=c+d%e#f") == "a%26b=c%2Bd%25e%23f", "what would change the query's meaning")
        #expect(IPCamWebClient.percentEncoded("é\t[\\]^`{|}") == "%C3%A9%09%5B%5C%5D%5E%60%7B%7C%7D")
        #expect(IPCamWebClient.percentEncoded("AZaz09-._~!$()*,;:@/?=") == "AZaz09-._~!$()*,;:@/?=", "what a query holds as it is")
    }

    // MARK: Which cameras are asked

    @Test func theFamilysPageAndScriptAreLoadedWithoutCredentialsFirst() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        #expect(try await client(camera).showsItsPage())
        #expect(camera.server.requests.map(\.path) == ["/", "/js/script/land.js"])
        #expect(camera.server.requests.allSatisfy { $0.head.headers["Authorization"] == nil && $0.head.target.contains("auth=") == false })
        #expect(IPCamWebLatch.shared.isFamily(IPCamWebLatch.key(camera.endpoint)))
        #expect(try await client(camera).showsItsPage(), "remembered for the address")
        #expect(camera.server.requests.count == 2)
    }

    @Test func anotherCamerasWebServerIsNeverSentTheSignIn() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.notThisFamily)
        let web = client(camera)
        #expect(try await web.showsItsPage() == false)
        #expect(camera.server.requests.map(\.path) == ["/"], "its script is not even loaded")
        await #expect(throws: (any Error).self) { _ = try await web.read("mobile") }
        #expect(camera.signIns.isEmpty, "the sign-in value goes only to a camera of the family")
    }

    @Test func aWebServerThatDoesNotAnswerIsNotKnownYet() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.starting)
        await #expect(throws: IPCamWebNoAnswer.self) { _ = try await client(camera).showsItsPage() }
        camera.mode.set(.normal)
        #expect(try await client(camera).showsItsPage(), "asked again")
    }

    // MARK: Signing in

    @Test func oneSignInServesEveryCallAndItsURLsAreThePages() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let web = client(camera)
        #expect(try await web.read("mobile")?.contains(#"on="1""#) == true)
        #expect(try await web.read("rtsp")?.contains(#"authorized="0""#) == true)
        #expect(try await web.read("upnp") == nil, "532229: the camera has no such option")
        #expect(camera.signIns.count == 1 && camera.rejectedSignIns.value == 0)
        let signIn = try #require(camera.signIns.first)
        let guid = try #require(signIn.query("guid"))
        #expect(Int64(guid) != nil)
        #expect(signIn.head.target == "/cgi/auth.cgi?act=auth&auth=123456&data=%3C?xml%20version=%271.0%27?%3E%3Croot%3E%3Cmode%3E1%3C/mode%3E"
                + "%3Cencrypt%3E\(FakeIPCamWebCamera.encrypted)%3C/encrypt%3E%3C/root%3E&guid=\(guid)", "the page's URL, byte for byte")
        let reads = camera.server.requests.filter { $0.path == "/cgi/network.cgi" }
        #expect(reads.count == 3 && reads.allSatisfy { $0.query("auth") == "SESSION-1" && $0.query("guid").flatMap { Int64($0) } != nil })
        let read = try #require(reads.first)
        #expect(read.head.target == "/cgi/network.cgi?get=mobile&auth=SESSION-1&guid=\(read.query("guid") ?? "")")
    }

    /// 532379: the camera signed in and gave a session, but calls the password insecure (its page then asks for a new one). The session
    /// is used; the camera's wish is said once in the log and kept for the address, so the security check can say it.
    @Test func aSignInWhosePasswordTheCameraCallsInsecureCountsAndIsSaidOnce() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let id = UUID()
        camera.signInCode.set(532379)
        let web = client(camera, cameraID: id)
        #expect(try await web.read("mobile") != nil)
        #expect(web.asksForStrongerPassword)
        #expect(try await client(camera, cameraID: id).read("rtsp") != nil, "another client of the address signs in too")
        #expect(camera.signIns.count == 2 && !IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
        #expect(capture.entries.value.filter { $0.cameraID == id && $0.message.contains("stronger password") }.count == 1, "said once")
        camera.signInCode.set(0)
        _ = try await client(camera, cameraID: id).read("mobile")
        #expect(!web.asksForStrongerPassword, "a sign-in answered 0 takes it back")
    }

    @Test func anInvalidSessionSignsInAgainOnce() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let web = client(camera)
        _ = try await web.read("mobile")
        camera.expireSessions.set(1)
        #expect(try await web.read("ddns") != nil)
        #expect(camera.signIns.count == 2, "one new sign-in, then the call again")
        camera.expireSessions.set(5)
        await #expect(throws: IPCamWebCameraError(code: 532227)) { _ = try await web.read("ddns") }
        #expect(camera.signIns.count == 3, "never more than one new sign-in per call")
        #expect(!IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)), "a session the camera forgot is not a refusal")
    }

    /// Every sign-in answer but 0 and 532379 is a refusal, as on the camera's page ("Login Failed!"): 532227 too (at a call, a session to
    /// renew) and 532374 ("No Privilege", which the calls after it name: `IPCamWebUnavailable.noPrivilege`). The code is logged, and nothing
    /// more is sent.
    @Test(arguments: [FakeIPCamWebCamera.wrongPasswordCode, 532227, 532374])
    func aSignInAnsweredWithAnyOtherCodeIsARefusal(code: Int) async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        camera.signInCode.set(code)
        let id = UUID(), web = client(camera, cameraID: id)
        await #expect(throws: (any Error).self) { _ = try await web.read("mobile") }
        #expect(IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
        #expect(capture.text(of: id).contains("code \(code)"), "the camera's code is logged")
        let why = code == IPCamWebCameraError.noPrivilege ? IPCamWebUnavailable.noPrivilege : .paused
        await #expect(throws: why) { _ = try await web.read("rtsp") }
        #expect(IPCamWebLatch.shared.refusal(IPCamWebLatch.key(camera.endpoint)) == why)
        #expect(camera.signIns.count == 1)
    }

    /// 532374 ("No Privilege"): the account Camera Bridge signs in with may not do this. At a write it is a change the account may not make
    /// (`CameraAdapterError.notPermitted`, the sign-in worked: no wrong password, nothing latched), at the sign-in a refusal like any other,
    /// said as such.
    @Test func noPrivilegeIsSaidAsSuch() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let web = client(camera)
        camera.writeCode.set(532374)
        await #expect(throws: CameraAdapterError.notPermitted("set mobile")) { try await web.write("mobile", element: "<mobile on='0'></mobile>") }
        #expect(CameraAdapterError.refusalWords(CameraAdapterError.notPermitted("set mobile")) == CameraAdapterError.notPermittedReason)
        #expect(IPCamWebCameraError(code: 532374).errorDescription?.contains("no privilege") == true)
        #expect(try await web.read("mobile") != nil, "the session still serves")
        #expect(camera.signIns.count == 1 && !IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))

        camera.signInCode.set(532374)
        let refused = await #expect(throws: IPCamWebCameraError.self) { _ = try await client(camera).read("mobile") }
        #expect(refused?.code == 532374 && IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
    }

    /// A refused sign-in stops this API only. It used to pause ONVIF's logins too (one account behind both), but the family's ONVIF and RTSP
    /// may ask no password at all (the owner's camera's don't): the pause then stopped the camera's events and snapshots for 2 minutes at every
    /// start, for nothing. ONVIF's own refusals still pause ONVIF, and its pause still stops this sign-in (`anONVIFPauseStillStopsTheWebSignIn`).
    @Test func aRefusedSignInIsNeverRepeatedAndLeavesONVIFAlone() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop(); for key in IPCamWebClient.loginKeys(camera.endpoint) { ONVIFLoginGuard.shared.clear(host: key) } }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let wrong = HTTPCredentials(username: "admin", password: "wrong"), id = UUID()
        await #expect(throws: CameraAdapterError.unauthorized) { _ = try await client(camera, credentials: wrong, cameraID: id).read("mobile") }
        #expect(camera.signIns.count == 1)
        #expect(IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
        #expect(IPCamWebClient.loginKeys(camera.endpoint).allSatisfy { ONVIFLoginGuard.shared.blockedUntil(host: $0) == nil }, "ONVIF's logins go on")
        await #expect(throws: (any Error).self) { _ = try await client(camera, cameraID: id).read("mobile") }
        #expect(camera.signIns.count == 1, "nothing more until the latch gives the sign-in a new try")
        #expect(capture.entries.value.filter { $0.cameraID == id && $0.message.contains("refused") }.count == 1, "said once")
        #expect(capture.text(of: id).contains("code \(FakeIPCamWebCamera.wrongPasswordCode)"), "with the camera's code")
    }

    /// The same account is behind ONVIF and this API: while ONVIF's logins are paused or locked, the web sign-in is not tried either.
    @Test func anONVIFPauseStillStopsTheWebSignIn() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop(); for key in IPCamWebClient.loginKeys(camera.endpoint) { ONVIFLoginGuard.shared.clear(host: key) } }
        let onvif = try #require(IPCamWebClient.loginKeys(camera.endpoint).last)
        ONVIFLoginGuard.shared.recordRejection(host: onvif)
        let paused = await #expect(throws: CameraAdapterError.self) { _ = try await client(camera).read("mobile") }
        if case .loginsPaused = paused {} else { Issue.record("Camera Bridge's own pause is said as such, not \(String(describing: paused))") }
        ONVIFLoginGuard.shared.clear(host: onvif)
        ONVIFLoginGuard.shared.recordLockout(host: onvif)
        let locked = await #expect(throws: CameraAdapterError.self) { _ = try await client(camera).read("mobile") }
        if case .lockedOut = locked {} else { Issue.record("the camera's own lock is said as such, not \(String(describing: locked))") }
        #expect(camera.signIns.isEmpty, "a paused or locked login is never tried")
        #expect(!IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
    }

    /// The camera's page reads the sign-in answer's code with `hXmlVal({t:'code'})`, whose default is 0 (`land.js`, `common.js`): an
    /// answer of the camera's (`<root>…</root>`) without `<code>`, or with an empty one, signs in as 0 does. A code that is not a number is
    /// unreadable (nil). The owner's camera ("Patio New", N801B) answered build 0.1.111's sign-in without a `<code>`, and the bridge stopped
    /// the API for it.
    @Test func theSignInsCodeIsReadAsTheCamerasPageReadsIt() {
        #expect(IPCamWebClient.signInCode(in: #"<?xml version="1.0" encoding="UTF-8"?><root><authid>S</authid><level>0</level></root>"#) == 0)
        #expect(IPCamWebClient.signInCode(in: "<root><code></code><authid>S</authid></root>") == 0)
        #expect(IPCamWebClient.signInCode(in: "<root><code/><authid>S</authid></root>") == 0)
        #expect(IPCamWebClient.signInCode(in: "<root><code>0</code><authid>S</authid></root>") == 0)
        #expect(IPCamWebClient.signInCode(in: "<root><code>532379</code><authid>S</authid></root>") == 532379)
        #expect(IPCamWebClient.signInCode(in: "<root><code> 531201 </code><error>user or password error</error></root>") == 531201)
        #expect(IPCamWebClient.signInCode(in: "<root><codec>1</codec><authid>S</authid></root>") == 0, "another element is not the code")
        #expect(IPCamWebClient.signInCode(in: "<root><code>failed</code></root>") == nil)
    }

    /// An answer of the camera's without `<code>` is signed in: its session serves every call, nothing is latched, and the log says nothing
    /// about a code (build 0.1.111 logged "answered Camera Bridge's sign-in without a code" and stopped the API). A wrong password is still
    /// refused with its code.
    @Test func aSignInAnswerWithoutACodeSignsIn() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        camera.mode.set(.signInWithoutCode)
        let id = UUID(), web = client(camera, cameraID: id)
        try await web.signIn()
        #expect(try await web.read("mobile")?.contains(#"on="1""#) == true)
        try await web.write("mobile", element: "<mobile on='0'></mobile>")
        #expect(camera.signIns.count == 1 && camera.rejectedSignIns.value == 0)
        let calls = camera.server.requests.filter { $0.path == "/cgi/network.cgi" }
        #expect(calls.count == 2 && calls.allSatisfy { $0.query("auth") == "SESSION-1" }, "the session the sign-in gave")
        #expect(camera.options.value["mobile"]?.contains(#"on="0""#) == true)
        #expect(!IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)) && !web.asksForStrongerPassword)
        for words in ["code", "refused", "stops asking"] { #expect(!capture.text(of: id).contains(words), "nothing said about a code") }

        let wrong = HTTPCredentials(username: "admin", password: "wrong")
        await #expect(throws: CameraAdapterError.unauthorized) { try await client(camera, credentials: wrong, cameraID: id).signIn() }
        #expect(capture.text(of: id).contains("code \(FakeIPCamWebCamera.wrongPasswordCode)"))
    }

    /// Signed in (code 0, or no code) without an `authid`: no session (`IPCamWebUnavailable.noSession`), and no call is made. Not a refusal:
    /// nothing is latched.
    @Test(arguments: [false, true])
    func aSignInWithoutASessionGivesNone(withoutCode: Bool) async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        if withoutCode { camera.mode.set(.signInWithoutCode) }
        camera.signInGivesSession.set(false)
        let web = client(camera)
        await #expect(throws: IPCamWebUnavailable.noSession) { try await web.signIn() }
        await #expect(throws: IPCamWebUnavailable.noSession) { _ = try await web.read("mobile") }
        #expect(camera.signIns.count == 2 && camera.calls.value.isEmpty)
        #expect(!IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
    }

    /// An answer that is not the camera's XML (no `<root>`: a web page, as a server in front of the camera could answer) is not the camera
    /// refusing the password: `invalidResponse`, and only this API stops (so the sign-in value is not sent again with every read). The log
    /// says what came back, not that a code is missing.
    @Test func aSignInAnswerThatIsNotTheCamerasXMLIsNotAPasswordRefusal() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        camera.mode.set(.signInAnsweredWithAPage)
        let id = UUID(), web = client(camera, cameraID: id)
        let error = await #expect(throws: CameraAdapterError.self) { _ = try await web.read("mobile") }
        #expect(error.map { if case .invalidResponse = $0 { true } else { false } } == true)
        #expect(IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
        #expect(IPCamWebClient.loginKeys(camera.endpoint).allSatisfy { ONVIFLoginGuard.shared.blockedUntil(host: $0) == nil })
        #expect(capture.text(of: id).contains("other than its XML"))
        #expect(!capture.text(of: id).contains("without a code") && !capture.text(of: id).contains("refused"))
        _ = try? await web.read("rtsp")
        #expect(camera.signIns.count == 1)
    }

    /// A call's answer without `<code>` is done, as on the camera's page: the family's reads never carry one, and a write answered
    /// `<root></root>` is taken.
    @Test func aCallAnsweredWithoutACodeIsDone() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        camera.writesWithoutCode.set(true)
        let web = client(camera)
        let read = try #require(try await web.read("rtsp"))
        #expect(IPCamWebClient.text("code", in: read) == nil && read.contains(#"authorized="0""#), "a read answered without a code")
        try await web.write("mobile", element: "<mobile on='0'></mobile>")
        #expect(camera.writes("mobile").count == 1 && camera.options.value["mobile"]?.contains(#"on="0""#) == true)
        #expect(camera.signIns.count == 1 && !IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
    }

    // MARK: When a refused sign-in gets a new try

    /// The camera's start in the bridge (`ONVIFDriver.makeNightVision`) gives a refused sign-in a new try only with other credentials (or
    /// 30 minutes later): a boot or a setup run that restarts the camera never resends the password the camera refused.
    @Test func aRefusedPasswordIsNotSentAgainWhenTheCameraStartsAgain() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let wrong = HTTPCredentials(username: "admin", password: "wrong")
        func start(_ credentials: HTTPCredentials) {
            _ = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil, transport: UnusedTransport())
                .makeNightVision()
        }
        await #expect(throws: CameraAdapterError.unauthorized) { _ = try await client(camera, credentials: wrong).read("mobile") }
        start(wrong)
        await #expect(throws: IPCamWebUnavailable.paused) { _ = try await client(camera, credentials: wrong).read("mobile") }
        #expect(camera.signIns.count == 1, "the same password: not sent again")
        start(camera.credentials)
        #expect(try await client(camera).read("mobile") != nil, "new credentials get a new try")
        #expect(camera.signIns.count == 2)
    }

    @Test func aRefusalHoldsThroughStartsForThirtyMinutesWithTheSameCredentials() {
        let latch = IPCamWebLatch(), key = "http://192.0.2.10:80", refusedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let wrong = HTTPCredentials(username: "admin", password: "wrong")
        #expect(latch.trip(key, credentials: wrong, now: refusedAt))
        #expect(!latch.trip(key, credentials: wrong, now: refusedAt), "said once")
        latch.cameraStarted(key, credentials: wrong, now: refusedAt.addingTimeInterval(29 * 60))
        #expect(latch.isTripped(key))
        latch.cameraStarted(key, credentials: wrong, now: refusedAt.addingTimeInterval(30 * 60))
        #expect(!latch.isTripped(key), "30 minutes later, a start tries again")

        for other in [HTTPCredentials(username: "admin", password: "right"), HTTPCredentials(username: "Admin", password: "wrong")] {
            latch.trip(key, credentials: wrong, now: refusedAt)
            latch.cameraStarted(key, credentials: other, now: refusedAt)
            #expect(!latch.isTripped(key), "other credentials: at the next start")
        }
        latch.trip(key, credentials: nil, now: refusedAt)
        latch.cameraStarted(key, credentials: nil, now: refusedAt)
        #expect(latch.isTripped(key))
    }

    /// The credentials are kept only as the SHA-256 of "username:password" (the value computed with `shasum -a 256`), in memory.
    @Test func theLatchKeepsOnlyTheCredentialsHash() {
        func hex(_ bytes: [UInt8]?) -> String? { bytes.map { $0.map { String(format: "%02x", $0) }.joined() } }
        #expect(hex(IPCamWebLatch.fingerprint(HTTPCredentials(username: "admin", password: "wrong")))
            == "1d892498c605302751fbaed83a4b222c860defe6e2c4852f5d5ef596847b139f")
        #expect(IPCamWebLatch.fingerprint(nil) == nil)
    }

    // MARK: Writes and secrets

    @Test func writesCarryTheElementAsTheCameraDecodesIt() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        try await client(camera).write("mobile", element: "<mobile on='0'></mobile>")
        #expect(camera.writes("mobile") == ["<?xml version='1.0'?><root><mobile on='0'></mobile></root>"])
        #expect(camera.options.value["mobile"]?.contains(#"on="0""#) == true)
        let write = try #require(camera.server.requests.last { $0.query("set") == "mobile" })
        #expect(write.head.target == "/cgi/network.cgi?set=mobile&auth=SESSION-1&data=%3C?xml%20version=%271.0%27?%3E%3Croot%3E"
                + "%3Cmobile%20on=%270%27%3E%3C/mobile%3E%3C/root%3E&guid=\(write.query("guid") ?? "")", "as the page's browser sends it")
    }

    @Test func nothingSecretIsLogged() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let id = UUID(), web = client(camera, cameraID: id)
        for what in ["mobile", "ddns", "rtsp", "onvif"] { _ = try await web.read(what) }
        try await web.write("mobile", element: "<mobile on='0'></mobile>")
        // A refused sign-in says the camera's code, never what was sent or answered.
        let wrong = HTTPCredentials(username: "admin", password: "wrong-pa55")
        _ = try? await client(camera, credentials: wrong, cameraID: id).read("mobile")
        #expect(capture.text(of: id).contains("code \(FakeIPCamWebCamera.wrongPasswordCode)"))
        for secret in [FakeIPCamWebCamera.password, FakeIPCamWebCamera.encrypted, "SESSION-1", FakeIPCamWebCamera.cuid, FakeIPCamWebCamera.ddnsSecret,
                       WyzeMD5.hex("admin:pa55word"), WyzeMD5.hex("admin:pa55word").uppercased(), wrong.password,
                       IPCamWebClient.encrypted(username: "admin", password: wrong.password), WyzeMD5.hex("admin:wrong-pa55").uppercased()] {
            #expect(!capture.text.contains(secret), "never logged")
        }
        for request in ["auth.cgi", "guid=", "<encrypt>", "user or password error"] {
            #expect(!capture.text(of: id).contains(request), "neither the URL nor the answer")
        }
    }
}
#endif
