// A loopback fake camera of the IPCamera Web family (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// The IPCamera Web family's API (docs/integrations/ipcamera-web.md): the cipher and hash against values computed outside Camera Bridge, the
/// page check that comes before any sign-in, the sign-in and its session, one new sign-in when the session expired, the latch after a
/// refusal, and that nothing secret is logged. Against `FakeIPCamWebCamera` only.
@Suite(.timeLimit(.minutes(1))) struct IPCamWebTests {
    final class Capture: LogSink {
        let entries = Box<[LogEntry]>([])
        func record(_ entry: LogEntry) { entries.update { $0.append(entry) } }
        var text: String { entries.value.map(\.message).joined(separator: "\n") }
    }

    private func client(_ camera: FakeIPCamWebCamera, credentials: HTTPCredentials? = nil, cameraID: UUID? = nil) -> IPCamWebClient {
        IPCamWebClient(endpoint: camera.endpoint, credentials: credentials ?? camera.credentials, cameraID: cameraID, timeout: .seconds(5))
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
        #expect(IPCamWebClient.encrypted(username: "admin", password: "") == "6e598af2667295a491c78bf9483445a134b0246c9fc0b1445b4b5b1601c211f0")
        #expect(IPCamWebClient.encrypted(username: "admin", password: #"p@ss"w\d!"#)
            == "6e0bdff36772c3a6c3c581aa4f3443f037b87736c8c6b0110d4b5f1250c015a1")
    }

    @Test func queryValuesAreFullyEncoded() {
        let xml = "<?xml version='1.0'?><root><mobile on='0'></mobile></root>"
        let encoded = IPCamWebClient.percentEncoded(xml)
        #expect(encoded == "%3C%3Fxml%20version%3D%271.0%27%3F%3E%3Croot%3E%3Cmobile%20on%3D%270%27%3E%3C%2Fmobile%3E%3C%2Froot%3E")
        #expect(encoded.removingPercentEncoding == xml)
        #expect(IPCamWebClient.percentEncoded("a&b=c+d") == "a%26b%3Dc%2Bd")
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

    @Test func oneSignInServesEveryCallAndItsValuesAreThePages() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let web = client(camera)
        #expect(try await web.read("mobile")?.contains(#"on="1""#) == true)
        #expect(try await web.read("rtsp")?.contains(#"authorized="0""#) == true)
        #expect(try await web.read("upnp") == nil, "532229: the camera has no such option")
        #expect(camera.signIns.count == 1 && camera.rejectedSignIns.value == 0)
        let signIn = try #require(camera.signIns.first)
        #expect(signIn.query("act") == "auth" && signIn.query("auth") == "123456")
        #expect(signIn.head.target.hasPrefix("/cgi/auth.cgi?act=auth&auth=123456&data=%3C%3Fxml%20version%3D%271.0%27%3F%3E"))
        let reads = camera.server.requests.filter { $0.path == "/cgi/network.cgi" }
        #expect(reads.count == 3 && reads.allSatisfy { $0.query("auth") == "SESSION-1" && $0.query("guid").flatMap { Int64($0) } != nil })
        #expect(reads.first?.head.target.hasPrefix("/cgi/network.cgi?get=mobile&auth=SESSION-1&guid=") == true)
    }

    @Test func aSignInAnsweredAsAlreadySignedInCounts() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        camera.signInCode.set(531355)
        #expect(try await client(camera).read("mobile") != nil)
    }

    @Test func anExpiredSessionSignsInAgainOnce() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let web = client(camera)
        _ = try await web.read("mobile")
        camera.expireSessions.set(1)
        #expect(try await web.read("ddns") != nil)
        #expect(camera.signIns.count == 2, "one new sign-in, then the call again")
        camera.expireSessions.set(5)
        await #expect(throws: IPCamWebCameraError(code: 531203)) { _ = try await web.read("ddns") }
        #expect(camera.signIns.count == 3, "never more than one new sign-in per call")
    }

    @Test func aRefusedSignInIsNeverRepeatedAndPausesTheCamerasLogins() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop(); for key in IPCamWebClient.loginKeys(camera.endpoint) { ONVIFLoginGuard.shared.clear(host: key) } }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let wrong = HTTPCredentials(username: "admin", password: "wrong"), id = UUID()
        await #expect(throws: CameraAdapterError.unauthorized) { _ = try await client(camera, credentials: wrong, cameraID: id).read("mobile") }
        #expect(camera.signIns.count == 1)
        #expect(IPCamWebLatch.shared.isTripped(IPCamWebLatch.key(camera.endpoint)))
        #expect(IPCamWebClient.loginKeys(camera.endpoint).contains { ONVIFLoginGuard.shared.blockedUntil(host: $0) != nil }, "ONVIF's logins pause too")
        await #expect(throws: (any Error).self) { _ = try await client(camera, cameraID: id).read("mobile") }
        #expect(camera.signIns.count == 1, "nothing more until the camera starts again in the bridge")
        #expect(capture.entries.value.filter { $0.cameraID == id && $0.message.contains("refused") }.count == 1, "said once")
    }

    @Test func writesCarryTheElementAsTheCameraDecodesIt() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        try await client(camera).write("mobile", element: "<mobile on='0'></mobile>")
        #expect(camera.writes("mobile") == ["<?xml version='1.0'?><root><mobile on='0'></mobile></root>"])
        #expect(camera.options.value["mobile"]?.contains(#"on="0""#) == true)
    }

    @Test func nothingSecretIsLogged() async throws {
        let camera = try await FakeIPCamWebCamera.start()
        defer { camera.stop() }
        let capture = Capture()
        let token = LogHub.addSink(capture)
        defer { LogHub.removeSink(token) }
        let web = client(camera)
        for what in ["mobile", "ddns", "rtsp", "onvif"] { _ = try await web.read(what) }
        try await web.write("mobile", element: "<mobile on='0'></mobile>")
        for secret in [FakeIPCamWebCamera.password, FakeIPCamWebCamera.encrypted, "SESSION-1", FakeIPCamWebCamera.cuid, FakeIPCamWebCamera.ddnsSecret,
                       WyzeMD5.hex("admin:pa55word")] {
            #expect(!capture.text.contains(secret), "never logged")
        }
    }
}
#endif
