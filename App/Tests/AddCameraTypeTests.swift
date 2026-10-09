import BridgeEngine
import CameraAdapters
import Foundation
import MediaCore
import RTSP
import Testing

/// The Camera Type page and what each type asks for, probes with and saves: network cameras with a vendor API, Wyze's official RTSP,
/// a UniFi Protect console, and cameras behind the go2rtc helper (Ring, Google Nest, Wyze, Tuya, other).
@Suite(.timeLimit(.minutes(1))) struct AddCameraTypeTests {
    private func wizard(_ service: FakeSetupService = FakeSetupService()) -> (AddCameraWizardModel, FakeSetupService) {
        (AddCameraWizardModel(service: service), service)
    }

    static let ringSource = "ring:?camera_id=77&device_id=dev-1&refresh_token=RT-SECRET-31337"

    private func ringProbe() -> CameraProbeResult {
        CameraProbeResult(vendor: .go2rtc, manufacturer: "Ring", model: "Front Door", serialNumber: "go2rtc-abc", firmware: "",
                          mainStream: StreamInfo(url: URL(string: "rtsp://127.0.0.1:41002/cb-x")!, videoCodec: .h264, width: 1920, height: 1080, fps: 15,
                                                 audioCodec: .opus, audioSampleRate: 48_000, audioChannels: 2))
    }

    // MARK: The list

    @Test func theWizardStartsOnTheCameraTypePage() {
        let (wizard, _) = wizard()
        #expect(wizard.step == .cameraType && wizard.cameraType == .automatic && wizard.canContinue && !wizard.canGoBack)
        #expect(wizard.step.title == "Camera Type")
    }

    @Test func everyTypeIsDescribedAndMapsToARoute() {
        #expect(CameraType.allCases.count == 15)
        for type in CameraType.allCases {
            #expect(!type.title.isEmpty && !type.summary.isEmpty && !type.setupSteps.isEmpty && !type.symbol.isEmpty, "\(type)")
            // ONVIF has no entry of its own: Detect Automatically stands for it, and Tapo is ONVIF with a guide.
            #expect(CameraType.standard(for: type.vendorChoice).vendorChoice == (type == .tapo ? .automatic : type.vendorChoice), "\(type)")
            #expect(CameraType.Group.allCases.contains(type.group))
            #expect(type.isIntegration == (type.group == .cloud || type.group == .console), "\(type)")
        }
        #expect(CameraType.automatic.vendorChoice == .automatic && CameraType.tapo.vendorChoice == .onvif && CameraType.amcrest.vendorChoice == .amcrest)
        #expect(CameraType.doorbird.vendorChoice == .doorbird && CameraType.unifiProtect.vendorChoice == .unifi && CameraType.wyzeRTSP.vendorChoice == .rtspURL)
        for cloud in [CameraType.ring, .googleNest, .wyzeCloud, .tuya, .otherCloud] {
            #expect(cloud.vendorChoice == .go2rtc && cloud.needsStreamingHelper && !cloud.usesDiscovery)
            #expect(cloud.service != nil)
        }
        #expect(CameraType.allCases.filter(\.usesDiscovery) == [.automatic, .hikvision, .reolink, .tapo, .amcrest, .doorbird])
    }

    @Test func theListIsHonestAboutWhatEachTypeGets() {
        // Cloud cameras: built-in motion only, no doorbell press, and a word about the service's terms.
        for type in [CameraType.ring, .wyzeCloud, .tuya] {
            if case .partly(let note) = type.events { #expect(note.contains("Built-in motion")) } else { Issue.record("\(type) events are not partial") }
            #expect(type.notes.contains { $0.contains("Unofficial") }, "\(type)")
            #expect(type.notes.contains { $0.contains("risk") || $0.contains("break") }, "\(type)")
        }
        #expect(CameraType.googleNest.notes.contains { $0.contains("Official") })
        #expect(CameraType.unifiProtect.events == .yes && CameraType.amcrest.events == .yes && CameraType.doorbird.events == .yes)
        #expect(CameraType.wyzeRTSP.setupSteps.contains { $0.contains("4.36.16.5654") && $0.contains("3.9") })
        #expect(CameraType.demo.recording != .yes)
    }

    @Test func choosingATypeFollowsTheRoute() async {
        let (wizard, _) = wizard()
        wizard.cameraType = .tapo
        #expect(wizard.vendorChoice == .onvif)
        await wizard.goForward()
        #expect(wizard.step == .discover)
        wizard.goBack()
        #expect(wizard.step == .cameraType)
        wizard.cameraType = .ring
        #expect(wizard.vendorChoice == .go2rtc)
        await wizard.goForward()
        #expect(wizard.step == .connect, "cloud cameras are not searched for")
        wizard.goBack()
        #expect(wizard.step == .cameraType)
        wizard.cameraType = .rtspURL
        await wizard.goForward()
        #expect(wizard.step == .connect)
    }

    @Test func aVendorChosenInCodeSetsTheMatchingType() {
        let (wizard, _) = wizard()
        wizard.vendorChoice = .doorbird
        #expect(wizard.cameraType == .doorbird)
        wizard.vendorChoice = .unifi
        #expect(wizard.cameraType == .unifiProtect)
        wizard.cameraType = .hikvision
        #expect(wizard.vendorChoice == .hikvision)
    }

    @Test func stepNumbersLeaveOutThePageAnIntegrationSkips() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        #expect(wizard.stepNumber == 1 && wizard.stepCount == 8)
        await wizard.goForward()
        #expect(wizard.step == .discover && wizard.stepNumber == 2 && wizard.stepCount == 8)
        let (cloud, _) = self.wizard()
        cloud.cameraType = .ring
        #expect(cloud.stepCount == 7)
        await cloud.goForward()
        #expect(cloud.step == .connect && cloud.stepNumber == 2 && cloud.stepCount == 7)
    }

    // MARK: Amcrest / Dahua and DoorBird

    @Test func amcrestAsksForAnAddressAndUserAndSavesTheVendor() async throws {
        let (wizard, service) = wizard()
        service.probeResult = .success(CameraProbeResult(
            vendor: .amcrest, manufacturer: "Amcrest", model: "AD410", serialNumber: "AMC1", firmware: "2.8",
            mainStream: StreamInfo(url: URL(string: "rtsp://192.0.2.60:554/cam/realmonitor?channel=1&subtype=0")!, videoCodec: .h264, width: 2560, height: 1920),
            capabilities: CameraCapabilities(events: [.motion, .person, .doorbell], isDoorbell: true, snapshotAPI: true)))
        wizard.cameraType = .amcrest
        await wizard.goForward()
        wizard.host = "192.0.2.60"
        await wizard.goForward()
        #expect(wizard.step == .connect && wizard.connectionProblem == "Enter the camera’s user name.")
        wizard.username = "admin"
        wizard.password = "pa55"
        await wizard.goForward()
        let call = try #require(service.probeCalls.last)
        #expect(call.vendor == .amcrest && call.endpoint == CameraEndpoint(host: "192.0.2.60") && call.username == "admin" && call.password == "pa55")
        #expect(wizard.kind == .doorbell && wizard.motionSource == .cameraEvents)
        let config = try #require(wizard.makeConfiguration())
        #expect(config.vendor == .amcrest && config.username == "admin" && config.integration == nil)
        #expect(config.mainStreamURL?.absoluteString == "rtsp://192.0.2.60:554/cam/realmonitor?channel=1&subtype=0")
        #expect(wizard.storedSecret == "pa55")
    }

    @Test func doorbirdUsesTheDoorbirdRouteWithItsCredentials() async throws {
        let (wizard, service) = wizard()
        service.probeResult = .success(CameraProbeResult(
            vendor: .doorbird, manufacturer: "DoorBird", model: "DoorBird D2101V", serialNumber: "1CCAE3700000", firmware: "000125",
            mainStream: StreamInfo(url: URL(string: "rtsp://192.0.2.61:554/mpeg/720p/media.amp")!, videoCodec: .h264, width: 1280, height: 720),
            capabilities: CameraCapabilities(events: [.motion, .doorbell], isDoorbell: true, snapshotAPI: true)))
        wizard.cameraType = .doorbird
        await wizard.goForward()   // to the search
        await wizard.advanceToProbe(host: "192.0.2.61")
        #expect(service.probeCalls.last?.vendor == .doorbird)
        let config = try #require(wizard.makeConfiguration())
        #expect(config.vendor == .doorbird && config.kind == .doorbell && config.capabilities?.isDoorbell == true)
    }

    // MARK: Wyze's official RTSP

    @Test func wyzeRTSPBuildsTheAddressFromTheIPAndTriesTheKnownPaths() async throws {
        let (wizard, service) = wizard()
        wizard.cameraType = .wyzeRTSP
        await wizard.goForward()
        #expect(wizard.step == .connect, "no search: the camera's address is typed on the Connect page")
        #expect(wizard.connectionProblem == "Enter the camera’s IP address, like 192.168.1.20.")
        wizard.host = "192.0.2.70"
        #expect(wizard.connectionProblem == "Enter the RTSP user name you created in the Wyze app.")
        wizard.username = "wyzeuser"
        #expect(wizard.connectionProblem == "Enter the RTSP password you created in the Wyze app.")
        wizard.password = "wyze1234"
        #expect(wizard.connectionProblem == nil && wizard.effectiveMainStreamText == "rtsp://192.0.2.70:554/stream0")
        // /stream0 is not there; /live is.
        var fallback = Samples.plainRTSPProbe
        fallback.mainStream?.url = URL(string: "rtsp://192.0.2.70:554/live")!
        service.probeResults = [.failure(RTSPError.notFound), .success(fallback)]
        await wizard.goForward()
        #expect(service.probeCalls.map { $0.main?.absoluteString } == ["rtsp://192.0.2.70:554/stream0", "rtsp://192.0.2.70:554/live"])
        #expect(service.probeCalls.allSatisfy { $0.vendor == .rtsp && $0.username == "wyzeuser" && $0.password == "wyze1234" })
        #expect(wizard.probeResult != nil)
        let config = try #require(wizard.makeConfiguration())
        #expect(config.vendor == .rtsp && config.username == "wyzeuser" && config.mainStreamURL?.absoluteString == "rtsp://192.0.2.70:554/live")
        #expect(wizard.storedSecret == "wyze1234")
    }

    @Test func wyzeRTSPStopsAfterARejectedLoginAndShowsTheLastFailure() async throws {
        let (wizard, service) = wizard()
        wizard.cameraType = .wyzeRTSP
        await wizard.goForward()
        wizard.host = "192.0.2.70"
        wizard.username = "u"
        wizard.password = "wrong"
        service.probeResults = [.failure(RTSPError.unauthorized), .success(Samples.plainRTSPProbe)]
        await wizard.goForward()
        #expect(service.probeCalls.count == 1, "another path would only fail the login again")
        if case .failed(let message) = wizard.probeState { #expect(message.contains("rejected")) } else { Issue.record("expected failure") }
        // Both paths missing: both were tried, and the next try starts at /stream0 again.
        service.probeResults = [.failure(RTSPError.notFound), .failure(RTSPError.notFound)]
        await wizard.probe()
        #expect(service.probeCalls.count == 3)
        #expect(wizard.effectiveMainStreamText == "rtsp://192.0.2.70:554/stream0")
    }

    // MARK: UniFi Protect

    private func protectWizard(_ service: FakeSetupService) -> AddCameraWizardModel {
        let wizard = AddCameraWizardModel(service: service)
        wizard.cameraType = .unifiProtect
        return wizard
    }

    @Test func unifiNeedsTheConsoleTheKeyAndACamera() async throws {
        let service = FakeSetupService()
        service.protectCamerasResult = .success([UnifiProtectCamera(id: "c1", name: "Front Door", model: "UVC G4 Doorbell Pro", isConnected: true, isDoorbell: true),
                                                 UnifiProtectCamera(id: "c2", name: "Garage", model: "UVC Micro", isConnected: false, isDoorbell: false)])
        let wizard = protectWizard(service)
        #expect(wizard.useHTTPS && wizard.httpPort == 443)
        await wizard.goForward()
        #expect(wizard.step == .connect, "a console is not found by a search")
        #expect(wizard.connectionProblem == "Enter the console’s address, like 192.168.1.1.")
        wizard.host = "192.0.2.1"
        #expect(wizard.connectionProblem == "Paste the API key from UniFi Protect.")
        wizard.password = "  KEY-4711\n"
        #expect(wizard.connectionProblem == "Choose Find Cameras to list the console’s cameras.")
        await wizard.findUnifiCameras()
        let listed = try #require(service.protectCameraCalls.last)
        #expect(listed.apiKey == "KEY-4711" && listed.endpoint.host == "192.0.2.1" && listed.endpoint.httpPort == 443 && listed.endpoint.useHTTPS)
        #expect(wizard.unifiCameras.count == 2 && wizard.integrationState == .idle)
        #expect(wizard.connectionProblem == "Choose a camera.")
        wizard.unifiCameraID = "c1"
        #expect(wizard.connectionProblem == nil)
    }

    @Test func unifiProbesThroughTheHelperAndSavesNoSecretInTheConfiguration() async throws {
        let service = FakeSetupService()
        service.protectCamerasResult = .success([UnifiProtectCamera(id: "c1", name: "Front Door", model: "UVC G4 Doorbell Pro", isConnected: true, isDoorbell: true)])
        service.integrationProbeResult = .success(CameraProbeResult(
            vendor: .unifi, manufacturer: "Ubiquiti", model: "UVC G4 Doorbell Pro", serialNumber: "E063DA000001", firmware: "Protect 7.3.70",
            mainStream: StreamInfo(url: URL(string: "rtsp://127.0.0.1:41002/cb-x")!, videoCodec: .h264, width: 2688, height: 1512),
            capabilities: CameraCapabilities(events: [.motion, .person, .doorbell], isDoorbell: true, snapshotAPI: true)))
        let wizard = protectWizard(service)
        await wizard.goForward()   // to the Connect page
        wizard.host = "192.0.2.1"
        wizard.password = "KEY-4711"
        await wizard.findUnifiCameras()
        #expect(wizard.unifiCameraID == "c1", "a console with one camera needs no choice")
        await wizard.goForward()   // to the probe
        let call = try #require(service.integrationProbeCalls.last)
        #expect(call.vendor == .unifi && call.secret == "KEY-4711" && call.username.isEmpty)
        #expect(call.integration == IntegrationSettings(service: .unifiProtect, details: [IntegrationSettings.Key.protectCameraID: "c1",
                                                                                           IntegrationSettings.Key.deviceName: "Front Door"]))
        #expect(wizard.kind == .doorbell && wizard.motionSource == .cameraEvents)
        let config = try #require(wizard.makeConfiguration())
        #expect(config.vendor == .unifi && config.integration == call.integration)
        #expect(config.endpoint.host == "192.0.2.1" && config.endpoint.useHTTPS && config.endpoint.httpPort == 443)
        #expect(config.mainStreamURL == nil && config.subStreamURL == nil, "the helper's address is picked at run time")
        #expect(config.username.isEmpty)
        #expect(wizard.storedSecret == "KEY-4711")
    }

    @Test func unifiKeyProblemsAreReadable() async {
        let service = FakeSetupService()
        service.protectCamerasResult = .failure(CameraAdapterError.unauthorized)
        let wizard = protectWizard(service)
        wizard.host = "192.0.2.1"
        await wizard.findUnifiCameras()
        #expect(wizard.integrationState == .failed("Paste the API key from UniFi Protect."))
        wizard.password = "bad"
        await wizard.findUnifiCameras()
        guard case .failed(let message) = wizard.integrationState else { Issue.record("expected failure"); return }
        #expect(message.lowercased().contains("rejected"))
        #expect(wizard.unifiCameras.isEmpty)
        service.protectCamerasResult = .success([])
        await wizard.findUnifiCameras()
        #expect(wizard.integrationState == .failed("The console has no cameras."))
    }

    @Test func leavingUnifiRestoresThePortsOfOtherTypes() {
        let (wizard, _) = wizard()
        wizard.cameraType = .unifiProtect
        #expect(wizard.useHTTPS && wizard.httpPort == 443 && wizard.rtspPort == 7441)
        wizard.cameraType = .amcrest
        #expect(!wizard.useHTTPS && wizard.httpPort == 80 && wizard.rtspPort == 554)
    }

    // MARK: Cloud cameras

    @Test func ringAsksForTheSourceAndRefusesWhatCouldRunAProgram() async throws {
        let (wizard, _) = wizard()
        wizard.cameraType = .ring
        await wizard.goForward()
        #expect(wizard.connectionProblem == "Paste the source address first.")
        wizard.sourceText = "exec:curl evil.example"
        #expect(wizard.connectionProblem?.contains("single line") == true)
        wizard.sourceText = "exec:curl"
        #expect(wizard.connectionProblem?.contains("not supported") == true)
        wizard.sourceText = "ring:?device_id=1&refresh_token=2"
        #expect(wizard.connectionProblem?.contains("camera_id") == true)
        #expect(!(wizard.connectionProblem ?? "").contains("refresh_token=2"))
        wizard.sourceText = Self.ringSource
        #expect(wizard.connectionProblem == nil && wizard.cloudSource?.service == .ring)
    }

    @Test func aCloudCameraProbesWithTheSourceAndIsSavedWithoutIt() async throws {
        let (wizard, service) = wizard()
        service.integrationProbeResult = .success(ringProbe())
        wizard.cameraType = .ring
        await wizard.goForward()
        wizard.sourceText = Self.ringSource
        await wizard.goForward()
        let call = try #require(service.integrationProbeCalls.last)
        #expect(call.vendor == .go2rtc && call.secret == Self.ringSource && call.integration.service == .ring)
        #expect(call.endpoint == CameraEndpoint(host: "127.0.0.1") && call.username.isEmpty)
        #expect(service.probeCalls.isEmpty, "not the address-based probe")
        // No camera events: the built-in motion detection is the motion.
        #expect(wizard.availableMotionSources == [.softMotion, .webhook] && wizard.motionSource == .softMotion)
        #expect(wizard.name == "Front Door")
        let config = try #require(wizard.makeConfiguration())
        #expect(config.vendor == .go2rtc && config.integration == IntegrationSettings(service: .ring))
        #expect(config.endpoint == CameraEndpoint(host: "127.0.0.1") && config.username.isEmpty)
        #expect(config.mainStreamURL == nil && config.subStreamURL == nil && config.motionSource == .softMotion)
        let saved = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        for secret in ["RT-SECRET-31337", "refresh_token", "dev-1"] { #expect(!saved.contains(secret), "\(secret)") }
        #expect(wizard.storedSecret == Self.ringSource)
    }

    @Test func addingACloudCameraStoresTheSourceAsThePassword() async throws {
        let (wizard, service) = wizard()
        service.integrationProbeResult = .success(ringProbe())
        service.pairing = PairingCode(setupCode: "111-22-333", setupURI: "X-HM://0081")
        wizard.cameraType = .ring
        await wizard.goForward()
        wizard.sourceText = Self.ringSource
        await wizard.advanceToSummary()
        await wizard.goForward()
        #expect(wizard.addState == .added)
        #expect(service.added.count == 1 && service.added[0].password == Self.ringSource)
    }

    @Test func cloudTypesNeedTheStreamingHelper() async {
        let service = FakeSetupService()
        service.isStreamingHelperInstalled = false
        let wizard = AddCameraWizardModel(service: service)
        wizard.cameraType = .ring
        await wizard.goForward()
        wizard.sourceText = Self.ringSource
        #expect(wizard.connectionProblem?.contains("streaming helper") == true && !wizard.canContinue)
        wizard.cameraType = .unifiProtect
        wizard.host = "192.0.2.1"
        wizard.password = "k"
        #expect(wizard.helperProblem != nil)
    }

    @Test func aFailedCloudProbeReadsAsASentence() async {
        let (wizard, service) = wizard()
        service.integrationProbeResult = .failure(IntegrationError("Ring did not deliver video in time."))
        wizard.cameraType = .ring
        await wizard.goForward()
        wizard.sourceText = Self.ringSource
        await wizard.goForward()
        #expect(wizard.probeState == .failed("Ring did not deliver video in time."))
        #expect(!wizard.canContinue)
    }

    @Test func wyzeTuyaAndOtherSourcesNameTheirServices() throws {
        let (wizard, _) = wizard()
        wizard.cameraType = .wyzeCloud
        wizard.sourceText = "wyze://192.0.2.80?uid=WYZEUID1234567890AB&enr=ENR&mac=AABBCCDDEEFF&model=HL_CAM4"
        #expect(wizard.connectionProblem == nil && wizard.integrationSettings?.service == .wyze)
        wizard.cameraType = .tuya
        wizard.sourceText = "tuya://protect-us.ismartlife.me?device_id=d1&email=me%40example.com&password=pw"
        #expect(wizard.integrationSettings?.service == .tuya)
        wizard.cameraType = .otherCloud
        wizard.sourceText = "kasa://user:pw@192.0.2.81:19443/https/stream/mixed"
        #expect(wizard.connectionProblem == nil && wizard.integrationSettings?.service == .other)
        wizard.sourceText = "tapo://admin:ABCDEF@192.0.2.82?subtype=0"
        #expect(wizard.connectionProblem == nil && wizard.cloudSource?.scheme == "tapo")
        wizard.sourceText = "ffmpeg:rtsp://a/b"
        #expect(wizard.connectionProblem != nil)
    }

    @Test func twoCloudCamerasAreNotTheSameCamera() async throws {
        let existing = CameraConfiguration(name: "Porch", kind: .camera, vendor: .go2rtc, endpoint: CameraEndpoint(host: "127.0.0.1"), username: "")
        var other = existing
        other.serialNumber = "go2rtc-other"
        let service = FakeSetupService()
        service.configuredCameras = [other]
        service.integrationProbeResult = .success(ringProbe())
        let wizard = AddCameraWizardModel(service: service)
        wizard.cameraType = .ring
        await wizard.goForward()
        wizard.sourceText = Self.ringSource
        await wizard.advanceToSummary()
        #expect(wizard.alreadyAdded == nil, "same address (the helper's), another camera")
        var same = other
        same.serialNumber = "go2rtc-abc"
        service.configuredCameras = [same]
        #expect(wizard.alreadyAdded?.serialNumber == "go2rtc-abc", "the same source added twice")
    }

    // MARK: Google Nest

    private func nestJSON(_ text: String) -> NestDeviceAccess {
        NestDeviceAccess(transport: { request in
            if request.url?.host == "www.googleapis.com" { return (Data(#"{"access_token":"ya29.A","refresh_token":"1//0R-SECRET"}"#.utf8), 200) }
            return (Data(text.utf8), 200)
        })
    }

    @Test func nestGuidesFromProjectToCamera() async throws {
        let service = FakeSetupService()
        service.nestAccess = nestJSON(#"{"devices":[{"name":"enterprises/p/devices/DEV1","type":"sdm.devices.types.DOORBELL","traits":{"sdm.devices.traits.Info":{"customName":"Front"},"sdm.devices.traits.CameraLiveStream":{"supportedProtocols":["WEB_RTC"]}}}]}"#)
        let wizard = AddCameraWizardModel(service: service)
        wizard.cameraType = .googleNest
        await wizard.goForward()
        #expect(wizard.connectionProblem == "Enter the Device Access project ID.")
        #expect(wizard.nestAuthorizationURL == nil)
        wizard.nestProjectID = "proj-1"
        wizard.nestClientID = "cid.apps.googleusercontent.com"
        #expect(wizard.nestAuthorizationURL?.host == "nestservices.google.com" && wizard.connectionProblem == "Enter the OAuth client secret.")
        wizard.nestClientSecret = "GOCSPX-s"
        #expect(wizard.connectionProblem == "Open Google’s sign-in link, then paste the code and choose Connect.")
        wizard.nestCodeText = "   "
        await wizard.connectNest()
        #expect(wizard.integrationState == .failed("Paste the code from the page Google showed (or that page’s address)."))
        wizard.nestCodeText = "https://www.google.com/?code=4/0Acode&scope=sdm"
        await wizard.connectNest()
        #expect(wizard.integrationState == .idle && wizard.nestCameras.map(\.name) == ["Front"])
        #expect(wizard.nestDeviceID == "DEV1" && wizard.nestCodeText.isEmpty, "one camera needs no choice, and the code is forgotten")
        #expect(wizard.connectionProblem == nil)
        let source = try #require(wizard.cloudSource)
        #expect(source.service == .nest && source.url.contains("refresh_token=1%2F%2F0R-SECRET") && source.url.contains("device_id=DEV1"))
        #expect(source.url.contains("project_id=proj-1") && source.url.contains("protocols=WEB_RTC"))
        #expect(wizard.integrationSettings == IntegrationSettings(service: .nest, details: [IntegrationSettings.Key.deviceName: "Front"]))
    }

    @Test func changingTheNestProjectDropsWhatWasFetched() async throws {
        let service = FakeSetupService()
        service.nestAccess = nestJSON(#"{"devices":[{"name":"enterprises/p/devices/DEV1","type":"sdm.devices.types.CAMERA","traits":{}}]}"#)
        let wizard = AddCameraWizardModel(service: service)
        wizard.cameraType = .googleNest
        wizard.nestProjectID = "proj-1"
        wizard.nestClientID = "cid"
        wizard.nestClientSecret = "s"
        wizard.nestCodeText = "4/0Acode"
        await wizard.connectNest()
        #expect(wizard.cloudSource != nil)
        wizard.nestProjectID = "proj-2"
        #expect(wizard.cloudSource == nil && wizard.nestCameras.isEmpty && wizard.nestDeviceID == nil)
    }

    @Test func nestRefusalsAreShownAndNothingIsKept() async {
        let service = FakeSetupService()
        service.nestAccess = NestDeviceAccess(transport: { _ in (Data(#"{"error":"invalid_grant"}"#.utf8), 400) })
        let wizard = AddCameraWizardModel(service: service)
        wizard.cameraType = .googleNest
        wizard.nestProjectID = "proj-1"
        wizard.nestClientID = "cid"
        wizard.nestClientSecret = "s"
        wizard.nestCodeText = "4/0Aused"
        await wizard.connectNest()
        guard case .failed(let message) = wizard.integrationState else { Issue.record("expected failure"); return }
        #expect(message.contains("rejected the code") && wizard.cloudSource == nil)
    }

    // MARK: The sign-in page

    @Test func theSignInPageOpensAndClosesWithTheWizard() async {
        let (wizard, service) = wizard()
        wizard.cameraType = .ring
        let url = await wizard.openSignInPage()
        #expect(url?.host == "127.0.0.1" && wizard.signInPageURL == url && service.signInBegun == 1)
        wizard.closeSignInPage()
        await settle(until: { service.signInEnded == 1 })
        #expect(wizard.signInPageURL == nil && service.signInEnded == 1)
        _ = await wizard.openSignInPage()
        wizard.cancel()   // the sheet going away closes it too
        await settle(until: { service.signInEnded == 2 })
        #expect(service.signInEnded == 2 && wizard.signInPageURL == nil)
    }

    @Test func aSignInPageThatCannotStartSaysWhy() async {
        let (wizard, service) = wizard()
        service.signInURL = .failure(Go2RTCError.helperMissing)
        #expect(await wizard.openSignInPage() == nil)
        guard case .failed(let message) = wizard.integrationState else { Issue.record("expected failure"); return }
        #expect(message.contains("streaming helper"))
    }
}
