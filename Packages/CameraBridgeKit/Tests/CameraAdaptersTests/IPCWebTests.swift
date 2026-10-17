// Pure parts, and a loopback fake IP camera web API (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// The IP camera web API: its sign-in tokens (DES), the request on the wire, editing the camera's XML in place, and night vision through
/// it, against fakes only (never a real camera).
@Suite(.timeLimit(.minutes(1))) struct IPCWebTests {
    // MARK: DES and the tokens

    @Test func desEncryptsTheClassicVector() {
        #expect(IPCWebDES.encrypt(0x0123_4567_89AB_CDEF, key: 0x1334_5779_9BBC_DFF1) == 0x85E8_1354_0F0A_B405)
        let bytes = IPCWebDES.encryptECB(key: [0x13, 0x34, 0x57, 0x79, 0x9B, 0xBC, 0xDF, 0xF1], [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
        #expect(bytes == [0x85, 0xE8, 0x13, 0x54, 0x0F, 0x0A, 0xB4, 0x05])
        #expect(IPCWebDES.encryptECB(key: Array("WebLogin".utf8), [1, 2, 3]) == nil, "only whole blocks")
    }

    @Test func tokensMatchTheCamerasOwnPage() {
        #expect(IPCWebToken.make("admin") == "52851dbd7918bbae")
        #expect(IPCWebToken.make("abcdefgh") == "4b24819b8505b9b5", "a whole block gets no padding block")
        #expect(IPCWebToken.make("abcdefghi") == "4b24819b8505b9b5e8b7e01c8a97a456")
        #expect(IPCWebToken.make(#"p@ss"w\d!"#) == "10801d9b763093d5f6232135ae2df415")
        #expect(IPCWebToken.make("") == "")
        #expect(IPCWebToken.make("pässwörd") != nil, "Latin-1 letters are one byte each")
        #expect(IPCWebToken.make("pass✓") == nil, "a character above U+00FF cannot be sent")
    }

    // MARK: The request

    @Test func theEnvelopeIsExact() {
        let text = IPCWebClient.envelope(user: "52851dbd7918bbae", password: "", body: "DayMode")
        #expect(text == "<?xml version=\"1.0\"?><soap:Envelope xmlns:soap=\"http://www.w3.org/2001/12/soap-envelope\"><soap:Header>\t"
                + "<userid>52851dbd7918bbae</userid>\t<passwd></passwd></soap:Header><soap:Body>DayMode</soap:Body></soap:Envelope>")
    }

    @Test func theRequestHasTheFormTypeAndTheEnvelope() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let client = IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials)
        let device = try #require(try await client.device())
        #expect(device.firmware == FakeIPCWebCamera.firmware)
        #expect(device.has("ircut_setting") && device.has("ircut_leddelay") && device.has("p2p_config") && !device.has(""))
        let page = try #require(camera.server.requests.first)
        #expect(page.method == "GET" && page.path == IPCWebClient.signInScript && page.body.isEmpty, "its sign-in script first, without the tokens")
        let first = try #require(camera.apiRequests.first)
        #expect(first.method == "POST" && first.path == "/getSystemVersionInfo")
        #expect(first.head.headers["Content-Type"] == "application/x-www-form-urlencoded", "exactly, with no charset")
        #expect(first.bodyText == IPCWebClient.envelope(user: "52851dbd7918bbae", password: "10801d9b763093d5f6232135ae2df415", body: ""))
        #expect(camera.rejectedRequests.value == 0)
        #expect(camera.server.requests.count == 3, "the page, the version, then the feature flags")
        _ = try await client.device()
        #expect(camera.server.requests.count == 3, "asked once")
        let other = IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials)
        _ = try await other.device()
        #expect(camera.pageLoads == 1, "the page is known for the address")
    }

    @Test func onlyTheFamilysPageGetsTheTokens() async throws {
        #expect(IPCWebClient.isFamilyPage(Data(FakeIPCWebCamera.page.utf8)))
        #expect(!IPCWebClient.isFamilyPage(Data("<html><head><title>IP Camera Web Login</title></head></html>".utf8)),
                "the title alone is not enough: the real page's title is empty")
        #expect(!IPCWebClient.isFamilyPage(Data("var key = des(\"WebLogin\", user, 1, 0);".utf8)), "both markers are needed")
        #expect(!IPCWebClient.isFamilyPage(Data("<html><head><title>Network Camera</title></head></html>".utf8)))

        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.notThisAPI)
        let client = IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials)
        #expect(try await client.device() == nil)
        #expect(camera.pageLoads == 1 && camera.apiRequests.isEmpty, "another camera's page: the tokens are never sent")
        _ = try await client.device()
        #expect(camera.pageLoads == 1, "asked once")

        // No web page at all (a port that refuses): no web API, nothing sent.
        let gone = try await FakeIPCWebCamera.start()
        let endpoint = gone.endpoint
        gone.stop()
        #expect(try await IPCWebClient(endpoint: endpoint, credentials: camera.credentials).device() == nil)
    }

    // MARK: The camera's XML, edited in place

    @Test func onlyTheNamedAttributeChanges() throws {
        let capture = FakeIPCWebCamera.capture()
        let edited = try #require(IPCWebXML.replacingAttributes(["IrcutMode": "3"], in: capture))
        #expect(edited == capture.replacingOccurrences(of: "IrcutMode=\"2\"", with: "IrcutMode=\"3\""))
        let lights = try #require(IPCWebXML.replacingAttributes(["led_mode": "1", "led_brightness_value": "0"], in: capture))
        #expect(lights == capture.replacingOccurrences(of: "led_mode=\"0\"", with: "led_mode=\"1\"")
            .replacingOccurrences(of: "led_brightness_value=\"100\"", with: "led_brightness_value=\"0\""))
        #expect(IPCWebXML.attribute("led_brightness_mode", of: lights) == "2", "a longer name ending the same is another attribute")
        #expect(IPCWebXML.attribute("Enable", of: capture) == nil, "a child's attribute is not the element's")
        #expect(IPCWebXML.replacingAttributes(["NoSuch": "1"], in: capture) == nil)
    }

    @Test func valuesAreEscapedAndReadBackUnescaped() throws {
        let element = #"<P2PConfig Enable='1' Type="10" Authcode="a&amp;b&#34;c&#x3C;"/>"#
        #expect(IPCWebXML.attribute("Enable", of: element) == "1")
        #expect(IPCWebXML.attribute("Authcode", of: element) == #"a&b"c<"#)
        let edited = try #require(IPCWebXML.replacingAttributes(["Authcode": #"x"<&'"#], in: element))
        #expect(edited == #"<P2PConfig Enable='1' Type="10" Authcode="x&quot;&lt;&amp;&apos;"/>"#)
        #expect(IPCWebXML.attribute("Authcode", of: edited) == #"x"<&'"#)
    }

    @Test func elementsAreFoundWhole() throws {
        let video = "<?xml version=\"1.0\"?><Video><CaptureMode A=\"1\"/><Capture A=\"x>y\"\nB=\"2\"><FishEyeCfg Enable=\"0\"/></Capture >"
            + "<Mask Enable=\"0\"/></Video>"
        #expect(IPCWebXML.element("Capture", in: video) == "<Capture A=\"x>y\"\nB=\"2\"><FishEyeCfg Enable=\"0\"/></Capture >")
        #expect(IPCWebXML.element("Mask", in: video) == "<Mask Enable=\"0\"/>")
        #expect(IPCWebXML.element("Overlay", in: video) == nil)
        #expect(IPCWebXML.element("Capture", in: "<Video><Capture A=\"1\"></Video>") == nil, "no end tag")
        let overlay = try #require(IPCWebXML.element("Overlay", in: FakeIPCWebCamera.overlay()))
        #expect(IPCWebXML.attribute("Enable", of: overlay) == "1" && IPCWebXML.attribute("Style", of: overlay) == "3")
    }

    // MARK: Night vision

    @Test func everyIRCutModeHasItsMeaning() {
        for automatic in [0, 1, 2] { #expect(IPCWebNightVision.mode(ircutMode: automatic, manualChoice: .on) == .auto) }
        #expect(IPCWebNightVision.mode(ircutMode: 3, manualChoice: nil) == nil, "manual: unknown until the bridge sets it")
        #expect(IPCWebNightVision.mode(ircutMode: 3, manualChoice: .off) == .off)
        #expect(IPCWebNightVision.mode(ircutMode: 6, manualChoice: nil) == .on)
        #expect(IPCWebNightVision.mode(ircutMode: 7, manualChoice: nil) == .off)
        #expect(IPCWebNightVision.mode(ircutMode: 5, manualChoice: .on) == nil)
        #expect(IPCWebNightVision.mode(ircutMode: nil, manualChoice: .on) == nil)
        #expect(IPCWebNightVision.lightOn(brightnessMode: 2, value: 100) == true)
        #expect(IPCWebNightVision.lightOn(brightnessMode: 1, value: 0) == false)
        #expect(IPCWebNightVision.lightOn(brightnessMode: 1, value: 50) == true)
        #expect(IPCWebNightVision.lightOn(brightnessMode: 3, value: 0) == true, "low power is on")
        #expect(IPCWebNightVision.lightOn(brightnessMode: nil, value: 0) == nil)
    }

    private func nightVision(_ camera: FakeIPCWebCamera, latch: IPCWebLatch = .shared) -> IPCWebNightVision {
        IPCWebNightVision(client: IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials, latch: latch), log: Log(category: "test"))
    }

    private func ircutMode(_ camera: FakeIPCWebCamera) -> Int? { IPCWebNightVision.int("IrcutMode", camera.state.value.capture) }

    @Test func nightVisionIsSetThroughTheCaptureSettings() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let control = nightVision(camera)
        #expect(try await control.capabilities() == NightVisionCapabilities(modes: [.auto, .on, .off], light: true))
        #expect(try await control.currentMode() == .auto)

        try await control.setMode(.on)
        #expect(camera.calls("setMediaVideoCaptureConfig") == ["<Video>" + FakeIPCWebCamera.capture(ircutMode: 3) + "</Video>"],
                "the Capture element as read, with only IrcutMode changed")
        #expect(camera.calls("setIRCutManual_DayNight") == ["NightMode"])
        #expect(try await control.currentMode() == .on)

        try await control.setMode(.off)
        #expect(camera.calls("setMediaVideoCaptureConfig").count == 1, "already manual")
        #expect(camera.calls("setIRCutManual_DayNight") == ["NightMode", "DayMode"])
        #expect(try await control.currentMode() == .off)

        try await control.setMode(.auto)
        #expect(ircutMode(camera) == 2, "the automatic mode it had")
        #expect(try await control.currentMode() == .auto)
        try await control.setMode(.auto)
        #expect(camera.calls("setMediaVideoCaptureConfig").count == 2, "already automatic: nothing written")
    }

    @Test func autoGoesBackToTheCamerasOwnAutomaticMode() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.state.update { $0.capture = FakeIPCWebCamera.capture(ircutMode: 1) }
        let control = nightVision(camera)
        try await control.setMode(.off)
        try await control.setMode(.auto)
        #expect(ircutMode(camera) == 1, "by the clock, as it was")

        let manual = try await FakeIPCWebCamera.start()
        defer { manual.stop() }
        manual.state.update { $0.capture = FakeIPCWebCamera.capture(ircutMode: 3) }
        let other = nightVision(manual)
        #expect(try await other.currentMode() == nil, "manual, and nothing says day or night")
        try await other.setMode(.auto)
        #expect(ircutMode(manual) == 2, "none seen in this run: the factory's light sensor")
    }

    @Test func manualLightModesReadAsOnAndOff() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.state.update { $0.capture = FakeIPCWebCamera.capture(ircutMode: 6) }
        let control = nightVision(camera)
        #expect(try await control.currentMode() == .on)
        camera.state.update { $0.capture = FakeIPCWebCamera.capture(ircutMode: 7) }
        #expect(try await control.currentMode() == .off)
        try await control.setMode(.on)
        #expect(ircutMode(camera) == 3 && camera.calls("setIRCutManual_DayNight") == ["NightMode"])
    }

    @Test func theIRLightsGoOffAndBackOn() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.state.update { $0.capture = FakeIPCWebCamera.capture(brightnessMode: 1, brightness: 50) }
        let control = nightVision(camera)
        #expect(try await control.currentLight() == true)
        try await control.setLight(false)
        #expect(camera.calls("setMediaVideoCaptureConfig") == ["<Video>" + FakeIPCWebCamera.capture(brightnessMode: 1, brightness: 0) + "</Video>"])
        #expect(try await control.currentLight() == false)
        try await control.setLight(true)
        #expect(camera.state.value.capture == FakeIPCWebCamera.capture(brightnessMode: 2, brightness: 50), "automatic, the manual brightness kept")
        try await control.setLight(true)
        #expect(camera.calls("setMediaVideoCaptureConfig").count == 2, "already on: nothing written")

        camera.state.update { $0.capture = FakeIPCWebCamera.capture(brightnessMode: 1, brightness: 0) }
        let fresh = nightVision(camera)
        try await fresh.setLight(true)
        #expect(camera.state.value.capture == FakeIPCWebCamera.capture(brightnessMode: 2, brightness: 100), "never left at 0")
    }

    @Test func aWriteTheCameraDoesNotKeepIsAnError() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let control = nightVision(camera)
        _ = try await control.capabilities()
        camera.mode.set(.ignoreWrites)
        await #expect(throws: CameraAdapterError.unsupported("the camera accepted night vision on but kept its old setting")) {
            try await control.setMode(.on)
        }
        #expect(camera.calls("setIRCutManual_DayNight").isEmpty, "not sent after a write that did not stick")
        await #expect(throws: CameraAdapterError.self) { try await control.setLight(false) }
    }

    @Test func changesThatOverlapRunOneAfterTheOther() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let control = nightVision(camera)
        _ = try await control.capabilities()
        for _ in 0..<5 {
            camera.state.update { $0.capture = FakeIPCWebCamera.capture() }
            async let mode: Void = control.setMode(.off)
            async let light: Void = control.setLight(false)
            _ = try await (mode, light)
            #expect(camera.state.value.capture == FakeIPCWebCamera.capture(ircutMode: 3, brightnessMode: 1, brightness: 0),
                    "neither change wrote back the other's old values")
            #expect(try await control.currentMode() == .off)
            #expect(try await control.currentLight() == false)
        }
    }

    @Test func aDayNightCommandThatFailsPutsTheOldModeBack() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let control = IPCWebNightVision(client: IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials, timeout: .seconds(1),
                                                             latch: IPCWebLatch()), log: Log(category: "test"))
        camera.state.update { $0.capture = FakeIPCWebCamera.capture(ircutMode: 1) }
        _ = try await control.capabilities()
        camera.dayNightDelay.set(.seconds(3))
        await #expect(throws: (any Error).self) { try await control.setMode(.off) }
        #expect(ircutMode(camera) == 1, "not left in manual mode: by the clock, as it was")
        #expect(try await control.currentMode() == .auto)
    }

    @Test func aRefusalStopsEveryFurtherRequest() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let latch = IPCWebLatch()
        let control = nightVision(camera, latch: latch)
        _ = try await control.capabilities()
        camera.mode.set(.refuseAll)
        await #expect(throws: CameraAdapterError.httpStatus(500)) { try await control.setMode(.on) }
        let sent = camera.server.requests.count
        camera.mode.set(.normal)
        await #expect(throws: CameraAdapterError.self) { try await control.setMode(.on) }
        await #expect(throws: CameraAdapterError.self) { try await control.currentMode() }
        #expect(camera.server.requests.count == sent, "nothing more is sent to a camera that refused")
        let other = IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials, latch: latch)
        await #expect(throws: IPCWebUnavailable.paused, "every client of the camera stops, and knows it is paused") { try await other.device() }
        #expect(camera.server.requests.count == sent)
        #expect(ONVIFLoginGuard.shared.blockedUntil(host: "127.0.0.1:\(camera.server.port)") == nil,
                "a refused request of a login that worked does not pause the camera's other logins")
        latch.reset(IPCWebLatch.key(camera.endpoint))
        #expect(try await other.device() != nil, "the camera's next start tries again")
    }

    @Test func aFamilyPageWithoutTheAPIIsPausedNotONVIF() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.pageOnly)
        let latch = IPCWebLatch()
        let client = IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials, latch: latch)
        await #expect(throws: IPCWebUnavailable.paused) { try await client.device() }
        await #expect(throws: IPCWebUnavailable.paused) { try await client.device() }
        #expect(camera.apiRequests.count == 1, "one refused call")
    }

    @Test func passwordErrorIsALoginRefusalThatPausesEveryLogin() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop(); camera.clearLoginPause() }
        camera.mode.set(.passwordError)
        let latch = IPCWebLatch()
        let control = nightVision(camera, latch: latch)
        await #expect(throws: CameraAdapterError.unauthorized) { try await control.capabilities() }
        #expect(latch.isTripped(IPCWebLatch.key(camera.endpoint)))
        #expect(camera.apiRequests.count == 1, "one refused login, never a second")
        #expect(ONVIFLoginGuard.shared.blockedUntil(host: "127.0.0.1:\(camera.server.port)") != nil, "ONVIF's logins pause too (one account)")

        // The camera's next start (the latch cleared) while the login is paused: nothing is sent.
        latch.reset(IPCWebLatch.key(camera.endpoint))
        camera.mode.set(.normal)
        let next = IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials, latch: latch)
        await #expect(throws: CameraAdapterError.self) { try await next.device() }
        #expect(camera.apiRequests.count == 1)
    }

    @Test func aLockedAccountIsALockout() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop(); camera.clearLoginPause() }
        camera.mode.set(.passwordLock)
        let client = IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials, latch: IPCWebLatch())
        do {
            _ = try await client.device()
            Issue.record("a locked account is an error")
        } catch let error as CameraAdapterError {
            guard case .lockedOut(let until) = error else { Issue.record("not a lockout: \(error)"); return }
            #expect(until.timeIntervalSinceNow > ONVIFLoginGuard.rejectionPause, "the long pause")
        }
    }

    @Test func aPausedLoginIsNeverTried() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop(); camera.clearLoginPause() }
        ONVIFLoginGuard.shared.recordRejection(host: "127.0.0.1:\(camera.server.port)")   // as ONVIF does after a wrong password
        let client = IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials, latch: IPCWebLatch())
        await #expect(throws: CameraAdapterError.self) { try await client.device() }
        #expect(camera.apiRequests.isEmpty, "no login while the camera's logins are paused")
    }

    @Test func aPasswordTheAPICannotTakeIsNeverSent() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        let client = IPCWebClient(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "pass✓"))
        await #expect(throws: IPCWebUnavailable.credentials, "a camera of the family: not taken for one without the API") { try await client.device() }
        #expect(camera.pageLoads == 1 && camera.apiRequests.isEmpty, "only its sign-in script, which needs no login")

        let other = try await MockONVIFCamera.start()
        defer { other.stop() }
        IPCWebLatch.shared.reset(IPCWebLatch.key(other.endpoint))
        #expect(try await IPCWebClient(endpoint: other.endpoint, credentials: HTTPCredentials(username: "admin", password: "pass✓")).device() == nil)
    }

    /// The bridge started while the camera was still starting: its web server answered 503 (or nothing in time) and its ONVIF failed too.
    /// Once both answer, the web API is used: a sign-in script that did not load is not taken as another camera's.
    @Test(arguments: [false, true]) func aCameraStillStartingGetsTheWebAPIOnceItAnswers(timesOut: Bool) async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        if timesOut { camera.pageDelay.set(.seconds(2)) } else { camera.mode.set(.starting) }
        let onvif = ScriptedONVIF()
        onvif.fails.set(true)
        let web = IPCWebNightVision(client: IPCWebClient(endpoint: camera.endpoint, credentials: camera.credentials, timeout: .seconds(1)),
                                    log: Log(category: "test"))
        let selector = NightVisionSelector(web: web, onvif: onvif)
        await #expect(throws: (any Error).self) { try await selector.capabilities() }

        camera.pageDelay.set(nil)
        camera.mode.set(.normal)
        onvif.fails.set(false)
        #expect(try await selector.capabilities() == NightVisionCapabilities(modes: [.auto, .on, .off], light: true))
        #expect(await selector.usesWebAPI)
        #expect(camera.pageLoads == 2, "the sign-in script that did not load is asked for again")
    }

    /// A camera whose sign-in script showed it is of the family never gets ONVIF's night vision (which it ignores): not while its web
    /// API is paused, and not while that API does not answer.
    @Test func aCameraOfTheFamilyNeverFallsBackToONVIF() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.mode.set(.pageOnly)   // the family's sign-in script, the API's calls refused: paused
        let onvif = ScriptedONVIF()
        let selector = NightVisionSelector(web: nightVision(camera), onvif: onvif)
        await #expect(throws: IPCWebUnavailable.paused) { try await selector.capabilities() }
        await #expect(throws: IPCWebUnavailable.paused, "still not ONVIF") { try await selector.capabilities() }
        await #expect(throws: (any Error).self) { try await selector.setMode(.off) }
        #expect(await selector.usesWebAPI == false && onvif.asked.value == 0)

        // Its page known for the address, and then its web API stops answering.
        let gone = try await FakeIPCWebCamera.start()
        let endpoint = gone.endpoint, credentials = gone.credentials
        #expect(try await IPCWebClient(endpoint: endpoint, credentials: credentials).device() != nil)
        gone.stop()
        defer { IPCWebLatch.shared.reset(IPCWebLatch.key(endpoint)) }
        let silent = NightVisionSelector(web: IPCWebNightVision(client: IPCWebClient(endpoint: endpoint, credentials: credentials),
                                                                log: Log(category: "test")), onvif: onvif)
        await #expect(throws: IPCWebUnavailable.noAnswer) { try await silent.capabilities() }
        #expect(onvif.asked.value == 0)
    }

    /// A camera whose web port never answers while its ONVIF does (not one of the family, as far as anyone knows): asked a few more
    /// times, then ONVIF.
    @Test func aWebServerThatNeverAnswersGetsONVIFAfterAFewTries() async throws {
        let gone = try await FakeIPCWebCamera.start()
        let endpoint = gone.endpoint, credentials = gone.credentials
        gone.stop()
        let onvif = ScriptedONVIF()
        let selector = NightVisionSelector(web: IPCWebNightVision(client: IPCWebClient(endpoint: endpoint, credentials: credentials),
                                                                  log: Log(category: "test")), onvif: onvif)
        for _ in 0..<NightVisionSelector.unansweredTries {
            await #expect(throws: IPCWebNoAnswer(), "the web server may still answer") { try await selector.capabilities() }
        }
        #expect(try await selector.capabilities() == NightVisionCapabilities(modes: [.auto], light: false))
        #expect(await selector.usesWebAPI == false)
        let asked = onvif.asked.value
        _ = try await selector.capabilities()
        #expect(onvif.asked.value == asked + 1, "ONVIF from then on")
    }

    // MARK: Choosing the web API or ONVIF

    private let onvifCredentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)

    /// ONVIF's night vision, scripted: it fails while `fails` is set, and otherwise offers auto.
    final class ScriptedONVIF: NightVisionControl, @unchecked Sendable {
        let fails = Box(false)
        let asked = Box(0)
        func capabilities() async throws -> NightVisionCapabilities {
            asked.update { $0 += 1 }
            if fails.value { throw CameraAdapterError.httpStatus(503) }
            return NightVisionCapabilities(modes: [.auto], light: false)
        }
        func currentMode() async throws -> NightVisionMode? { .auto }
        func setMode(_ mode: NightVisionMode) async throws {}
        func setLight(_ on: Bool) async throws {}
    }

    @Test func anONVIFCameraWithoutTheWebAPIKeepsONVIF() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        IPCWebLatch.shared.reset(IPCWebLatch.key(camera.endpoint))
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: onvifCredentials, mainStreamURL: nil, subStreamURL: nil, transport: UnusedTransport())
        let selector = try #require(driver.makeNightVision() as? NightVisionSelector)
        #expect(try await selector.capabilities() == NightVisionCapabilities(modes: [.auto, .on, .off], light: false))
        #expect(await selector.usesWebAPI == false)
        #expect(try await selector.currentMode() == .auto)
        #expect(camera.server.requests(path: IPCWebClient.signInScript).count == 1, "its sign-in script is looked at once")
        #expect(camera.server.requests(path: "/getSystemVersionInfo").isEmpty, "not this family's page: the tokens are never sent")
        _ = try await selector.capabilities()
        #expect(camera.server.requests(path: IPCWebClient.signInScript).count == 1)
        let setup = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)
        #expect(try await setup.ipcWeb().isNone, "its setup uses ONVIF too")
        #expect(camera.server.requests(path: "/getSystemVersionInfo").isEmpty)
    }

    @Test func aCameraThatSpeaksTheWebAPIUsesIt() async throws {
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        IPCWebLatch.shared.trip(IPCWebLatch.key(camera.endpoint))   // refused in an earlier run
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: camera.credentials, mainStreamURL: nil, subStreamURL: nil, transport: UnusedTransport())
        let control = try #require(driver.makeNightVision())
        #expect(try await control.capabilities() == NightVisionCapabilities(modes: [.auto, .on, .off], light: true), "a new start tries again")
        #expect(await (control as? NightVisionSelector)?.usesWebAPI == true)
        try await control.setMode(.off)
        #expect(camera.calls("setIRCutManual_DayNight") == ["DayMode"])
        #expect(try await control.currentLight() == true)
        #expect(camera.server.requests.allSatisfy { !$0.path.hasPrefix("/onvif") }, "ONVIF is not asked")
    }

    @Test func aWebAPIWithoutNightVisionFallsBackToONVIF() async throws {
        final class Recording: NightVisionControl, @unchecked Sendable {
            let asked = Box(0)
            func capabilities() async throws -> NightVisionCapabilities { asked.update { $0 += 1 }; return NightVisionCapabilities(modes: [.auto], light: false) }
            func currentMode() async throws -> NightVisionMode? { .auto }
            func setMode(_ mode: NightVisionMode) async throws {}
            func setLight(_ on: Bool) async throws {}
        }
        let camera = try await FakeIPCWebCamera.start()
        defer { camera.stop() }
        camera.state.update { $0.features = "+gpio_input+p2p_config+" }
        let onvif = Recording()
        let selector = NightVisionSelector(web: nightVision(camera), onvif: onvif)
        #expect(try await selector.capabilities() == NightVisionCapabilities(modes: [.auto], light: false))
        #expect(await selector.usesWebAPI == false && onvif.asked.value == 1)
        #expect(camera.calls("getMediaVideoConfig").isEmpty, "the flags say it has no night vision")
    }
}
#endif
