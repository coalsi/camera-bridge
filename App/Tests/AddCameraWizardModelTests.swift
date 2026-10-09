import BridgeEngine
import CameraAdapters
import Foundation
import MediaCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct AddCameraWizardModelTests {
    private func wizard(_ service: FakeSetupService = FakeSetupService()) -> (AddCameraWizardModel, FakeSetupService) {
        (AddCameraWizardModel(service: service, initialStep: .discover), service)   // the Camera Type page has its own tests below
    }

    @Test func discoveryListsCamerasAndSelectionFillsTheAddress() async {
        let (wizard, service) = wizard()
        service.discovered = [DiscoveredCamera(host: "192.0.2.21", name: "Driveway", hardware: "DS-2CD2347G2-LU")]
        #expect(wizard.step == .discover && !wizard.canContinue)
        await wizard.discover()
        #expect(service.discoverCalls == 1 && wizard.discovered.count == 1 && wizard.hasDiscovered && !wizard.isDiscovering)
        wizard.select(wizard.discovered[0])
        #expect(wizard.host == "192.0.2.21" && wizard.canContinue)
        #expect(wizard.selectedDiscoveredHost == "192.0.2.21")
        wizard.host = "  "
        #expect(!wizard.canContinue)
    }

    @Test func manualHostAndCredentialsLeadToAProbe() async throws {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        wizard.host = " 192.0.2.21 "
        await wizard.goForward()
        #expect(wizard.step == .connect && !wizard.canContinue)   // username required
        wizard.username = "admin"
        wizard.password = "s3cret"
        #expect(wizard.canContinue)
        await wizard.goForward()
        #expect(wizard.step == .probe)
        let call = try #require(service.probeCalls.last)
        #expect(call.vendor == nil && call.endpoint == CameraEndpoint(host: "192.0.2.21") && call.username == "admin" && call.password == "s3cret")
        #expect(wizard.probeState == .succeeded(Samples.hikvisionProbe) && wizard.canContinue)
    }

    @Test func probeFailureCanBeRetried() async {
        let (wizard, service) = wizard()
        service.probeResult = .failure(FakeError.unreachable)
        wizard.host = "192.0.2.50"
        wizard.vendorChoice = .onvif
        await wizard.goForward()
        wizard.username = "admin"
        await wizard.goForward()
        #expect(wizard.probeState == .failed("The camera didn't respond.") && !wizard.canContinue)
        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.probe()
        #expect(service.probeCalls.count == 2 && service.probeCalls[1].vendor == .onvif)
        #expect(wizard.canContinue)
    }

    // MARK: Review findings: readable failures, ONVIF ports, Local Network, webhook sensors

    /// A wrong password is the most common setup failure: it reads as a sentence, not as `CameraAdapterError.unauthorized`.
    @Test func aWrongPasswordReadsAsASentence() async {
        let (wizard, service) = wizard()
        service.probeResult = .failure(CameraAdapterError.unauthorized)
        await wizard.advanceToProbe(host: "192.0.2.21")
        #expect(wizard.probeState == .failed("The camera rejected the user name or password."))
    }

    /// Automatic detection that finds nothing says which interfaces were tried and how to use a stream URL instead
    /// (the Connect page has no stream field in Automatic mode).
    @Test func automaticDetectionFailureSaysWhatToDo() async {
        let (wizard, service) = wizard()
        service.probeResult = .failure(EngineError.noCameraAPI(host: "192.0.2.20"))
        await wizard.advanceToProbe(host: "192.0.2.20")
        #expect(wizard.probeState == .failed("No Hikvision, Reolink or ONVIF interface answered at 192.0.2.20. Check the address and ports (turn on Use HTTPS if the camera only answers HTTPS), or go back and choose Camera Type › RTSP URL."))
    }

    /// WS-Discovery tells where the device service is (`http://host:8000/onvif/device_service`): the probe and the saved
    /// camera use that port.
    @Test func aDiscoveredCameraKeepsItsONVIFPort() async throws {
        let (wizard, service) = wizard()
        service.discovered = [DiscoveredCamera(host: "192.0.2.32", name: "Porch", xAddrs: [try #require(URL(string: "http://192.0.2.32:8000/onvif/device_service"))])]
        service.probeResult = .success(Samples.plainONVIFProbe)
        await wizard.discover()
        wizard.select(wizard.discovered[0])
        #expect(wizard.onvifPort == 8000)
        await wizard.goForward()
        wizard.username = "admin"
        await wizard.goForward()
        #expect(service.probeCalls.last?.endpoint == CameraEndpoint(host: "192.0.2.32", onvifPort: 8000))
        wizard.name = "Porch"
        #expect(wizard.makeConfiguration()?.endpoint.onvifPort == 8000)

        // Typing another address drops the discovered camera's port; a port typed under Advanced stays.
        wizard.goBack()
        wizard.goBack()
        #expect(wizard.step == .discover)
        wizard.host = "192.0.2.33"
        #expect(wizard.onvifPort == nil)
        wizard.onvifPort = 2020
        wizard.host = "192.0.2.34"
        #expect(wizard.onvifPort == 2020)
    }

    /// Automatic detection found the device service on another port: the saved camera keeps it.
    @Test func theONVIFPortTheProbeFoundIsSaved() async {
        let (wizard, service) = wizard()
        var result = Samples.plainONVIFProbe
        result.onvifPort = 2020
        service.probeResult = .success(result)
        await wizard.advanceToProbe(host: "192.0.2.35")
        #expect(wizard.makeConfiguration()?.endpoint == CameraEndpoint(host: "192.0.2.35", onvifPort: 2020))
    }

    @Test func onvifPortsAreValidated() {
        let (wizard, _) = wizard()
        wizard.host = "192.0.2.21"
        wizard.username = "admin"
        wizard.onvifPort = 70_000
        #expect(wizard.connectionProblem == "Ports must be between 1 and 65535.")
        wizard.onvifPort = nil
        #expect(wizard.connectionProblem == nil)
    }

    /// With Local Network access denied the Discover page says so instead of "No cameras answered", and once access is
    /// allowed it searches again by itself.
    @Test func localNetworkDenialShowsOnTheDiscoverPageAndAllowingSearchesAgain() async {
        let (wizard, service) = wizard()
        service.localNetworkAccess = .denied
        await wizard.discover()
        #expect(wizard.isLocalNetworkDenied && wizard.hasDiscovered && wizard.discovered.isEmpty)
        service.localNetworkAccess = .granted
        service.discovered = [DiscoveredCamera(host: "192.0.2.21", name: "Driveway")]
        #expect(!wizard.isLocalNetworkDenied)
        await wizard.localNetworkAccessDidChange(.granted)?.value
        #expect(service.discoverCalls == 2 && wizard.discovered.count == 1)
        // Nothing to do once cameras are listed, or after Cancel.
        #expect(wizard.localNetworkAccessDidChange(.granted) == nil)
        wizard.cancel()
        #expect(wizard.localNetworkAccessDidChange(.granted) == nil)
    }

    /// A camera whose motion comes from the webhook (RTSP + Frigate) can show the webhook's person, vehicle, animal and
    /// package events as sensors, although the camera reports no detections itself.
    @Test func webhookCamerasOfferDetectionSensors() async throws {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.plainRTSPProbe)
        wizard.vendorChoice = .rtspURL
        await wizard.goForward()
        wizard.mainStreamURLText = "rtsp://192.0.2.24:8554/live"
        await wizard.goForward()
        #expect(wizard.availableSensors.isEmpty)
        wizard.motionSource = .webhook
        #expect(wizard.availableSensors == [.person, .vehicle, .animal, .package])
        wizard.sensors.person = true
        wizard.name = "Side Yard"
        let config = try #require(wizard.makeConfiguration())
        #expect(config.motionSource == .webhook && config.sensors.person)
        wizard.motionSource = .softMotion
        #expect(wizard.makeConfiguration()?.sensors.person == false, "no webhook, no detections")
    }

    @Test func probeResultSetsSensibleDefaults() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.doorbellProbe)
        await wizard.advanceToProbe(host: "192.0.2.22")
        #expect(wizard.kind == .doorbell)
        #expect(wizard.name == "Reolink Video Doorbell WiFi")
        #expect(wizard.motionSource == .cameraEvents)
        #expect(!wizard.twoWayAudio && !wizard.canUseTwoWayAudio)
        #expect(wizard.availableSensors == [.person, .package])
        #expect(wizard.availableMotionSources == [.cameraEvents, .softMotion, .webhook])
    }

    @Test func discoveredNameWinsOverTheModelName() async {
        let (wizard, service) = wizard()
        service.discovered = [DiscoveredCamera(host: "192.0.2.21", name: "Driveway")]
        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.discover()
        wizard.select(wizard.discovered[0])
        await wizard.goForward()
        wizard.username = "admin"
        await wizard.goForward()
        #expect(wizard.name == "Driveway" && wizard.kind == .camera && wizard.twoWayAudio)
    }

    @Test func camerasWithoutMotionEventsDefaultToBuiltInDetection() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.plainRTSPProbe)
        wizard.vendorChoice = .rtspURL
        #expect(wizard.canContinue)            // no host needed: it comes from the URL
        await wizard.goForward()
        #expect(wizard.step == .connect && !wizard.canContinue)
        wizard.mainStreamURLText = "rtsp://viewer:pa55@192.0.2.24:8554/live"
        #expect(wizard.canContinue)            // username optional for plain RTSP
        await wizard.goForward()
        let call = service.probeCalls.last
        #expect(call?.vendor == .rtsp && call?.endpoint.host == "192.0.2.24" && call?.endpoint.rtspPort == 8_554)
        #expect(call?.main == URL(string: "rtsp://192.0.2.24:8554/live"))   // credentials moved out of the URL…
        #expect(call?.username == "viewer" && call?.password == "pa55")       // …into the credential fields
        #expect(wizard.mainStreamURLText == "rtsp://192.0.2.24:8554/live")
        #expect(wizard.motionSource == .softMotion)
        #expect(wizard.availableMotionSources == [.softMotion, .webhook])
        #expect(wizard.availableSensors.isEmpty)
    }

    @Test func invalidStreamURLsAreRejected() {
        let (wizard, _) = wizard()
        wizard.vendorChoice = .rtspURL
        for text in ["", "http://192.0.2.1/x", "rtsp://", "not a url"] {
            wizard.mainStreamURLText = text
            #expect(wizard.connectionProblem != nil, "accepted \(text)")
        }
        wizard.mainStreamURLText = "rtsp://192.0.2.1/main"
        wizard.subStreamURLText = "ftp://x"
        #expect(wizard.connectionProblem == "The sub stream URL must start with rtsp://.")
        wizard.subStreamURLText = ""
        #expect(wizard.connectionProblem == nil)
    }

    @Test func demoCameraSkipsAddressAndCredentials() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(CameraProbeResult(vendor: .demo, manufacturer: "CameraBridge", model: "Demo Camera", serialNumber: "D",
                                                         firmware: "1", capabilities: CameraCapabilities(events: [.motion])))
        wizard.vendorChoice = .demo
        #expect(wizard.canContinue)
        await wizard.goForward()
        #expect(wizard.step == .probe)
        #expect(service.probeCalls.last?.vendor == .demo && service.probeCalls.last?.endpoint.host == "localhost")
        wizard.goBack()
        #expect(wizard.step == .cameraType)
    }

    @Test func editingConnectionDetailsDiscardsAnEarlierProbe() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.advanceToProbe(host: "192.0.2.21")
        #expect(wizard.probeResult != nil)
        wizard.goBack()
        wizard.password = "changed"
        #expect(wizard.probeState == .idle)
    }

    @Test func nameIsRequiredAndKindChangeCarriesAWarning() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.advanceToProbe(host: "192.0.2.21")
        await wizard.goForward()
        #expect(wizard.step == .kind)
        wizard.name = "   "
        #expect(!wizard.canContinue)
        wizard.name = "Driveway"
        #expect(wizard.canContinue)
        #expect(AddCameraWizardModel.kindChangeWarning.contains("re-add"))
    }

    @Test func configurationKeepsOnlyAvailableFeaturesAndNoCredentials() async throws {
        let (wizard, service) = wizard()
        var probe = Samples.hikvisionProbe
        probe.mainStream?.url = URL(string: "rtsp://admin:leak@192.0.2.21:554/ISAPI/Streaming/channels/101")!
        service.probeResult = .success(probe)
        await wizard.advanceToProbe(host: "192.0.2.21")
        wizard.name = " Driveway "
        wizard.kind = .camera
        wizard.motionSource = .softMotion
        wizard.motionSensitivity = 0.8
        wizard.sensors.person = true
        wizard.sensors.package = true          // not offered by this camera
        wizard.twoWayAudio = true
        let config = try #require(wizard.makeConfiguration())
        #expect(config.id == wizard.cameraID && config.name == "Driveway" && config.vendor == .hikvision)
        #expect(config.endpoint == CameraEndpoint(host: "192.0.2.21") && config.username == "admin")
        #expect(config.mainStreamURL == URL(string: "rtsp://192.0.2.21:554/ISAPI/Streaming/channels/101"))
        #expect(config.subStreamURL == Samples.hikvisionProbe.subStream?.url)
        #expect(config.motionSource == .softMotion && config.motionSensitivity == 0.8)
        #expect(config.sensors.person && !config.sensors.package)
        #expect(config.twoWayAudio && config.audioEnabled)
        #expect(config.manufacturer == "Hikvision" && config.model == "DS-2CD2347G2-LU" && config.firmware == "V5.7.15")
        #expect(config.capabilities == Samples.hikvisionProbe.capabilities)
        #expect(config.hapPort == 0 && config.isEnabled)
    }

    @Test func summaryAddsTheCameraThenShowsItsPairingCode() async throws {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        service.pairing = PairingCode(setupCode: "482-17-935", setupURI: "X-HM://0081YCYEP3QXO")
        await wizard.advanceToProbe(host: "192.0.2.21")
        await wizard.advanceToSummary()
        #expect(wizard.continueTitle == "Add Camera")
        await wizard.goForward()
        #expect(wizard.addState == .added && wizard.step == .pairing)
        #expect(service.added.count == 1 && service.added[0].password == "s3cret")
        #expect(service.added[0].configuration.id == wizard.cameraID)
        #expect(wizard.pairingCode == service.pairing)
        #expect(wizard.continueTitle == "Done" && !wizard.canGoBack)
    }

    @Test func addFailureStaysOnTheSummary() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        service.addError = FakeError.unreachable
        await wizard.advanceToProbe(host: "192.0.2.21")
        await wizard.advanceToSummary()
        await wizard.goForward()
        #expect(wizard.step == .summary && wizard.addState == .failed("The camera didn't respond."))
    }

    // MARK: Cancellation

    /// Cancel stops a probe in flight: the engine call is cancelled and no result lands afterwards.
    @Test func cancelStopsAProbeInFlight() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        service.probeDelay = .seconds(30)
        wizard.host = "192.0.2.21"
        await wizard.goForward()
        wizard.username = "admin"
        let forward = wizard.startForward()
        await settle(until: { !service.probeCalls.isEmpty })
        #expect(wizard.step == .probe && wizard.probeState == .probing)
        wizard.cancel()
        await forward.value
        #expect(service.probeWasCancelled)
        #expect(wizard.probeState == .idle && wizard.probeResult == nil)
        await wizard.probe()                         // a closed wizard starts nothing new
        #expect(service.probeCalls.count == 1)
    }

    @Test func cancelStopsARetriedProbe() async {
        let (wizard, service) = wizard()
        service.probeResult = .failure(FakeError.unreachable)
        await wizard.advanceToProbe(host: "192.0.2.21")
        service.probeDelay = .seconds(30)
        let retry = wizard.startProbe()
        await settle(until: { service.probeCalls.count == 2 })
        wizard.cancel()
        await retry.value
        #expect(service.probeWasCancelled && wizard.probeState == .idle)
    }

    /// Leaving the Discover page mid-search (its `.task` is cancelled) doesn't cut the search short: the complete list
    /// lands, and the page shows it next time instead of a partial or empty one.
    @Test func leavingTheDiscoverPageDoesntCutTheSearchShort() async {
        let (wizard, service) = wizard()
        service.discovered = [DiscoveredCamera(host: "192.0.2.21", name: "Driveway"), DiscoveredCamera(host: "192.0.2.22", name: "Porch")]
        service.discoveryDelay = .milliseconds(100)
        let pageTask = Task { await wizard.discover() }
        await settle(until: { service.discoverCalls == 1 })
        #expect(wizard.isDiscovering)
        pageTask.cancel()
        await pageTask.value
        #expect(!service.discoveryWasCancelled)
        #expect(wizard.hasDiscovered && !wizard.isDiscovering && wizard.discovered.count == 2)
    }

    /// The page's `.task` and another caller (Search Again, screenshot capture) share one search.
    @Test func concurrentSearchesShareOneRun() async {
        let (wizard, service) = wizard()
        service.discovered = [DiscoveredCamera(host: "192.0.2.21", name: "Driveway")]
        service.discoveryDelay = .milliseconds(50)
        let page = Task { await wizard.discover() }
        await settle(until: { service.discoverCalls == 1 })
        await wizard.discover()
        await page.value
        #expect(service.discoverCalls == 1 && wizard.discovered.count == 1 && wizard.hasDiscovered)
        await wizard.discover()                      // Search Again after it finished: a new search
        #expect(service.discoverCalls == 2)
    }

    @Test func cancelStopsSearchAgain() async {
        let (wizard, service) = wizard()
        service.discovered = [DiscoveredCamera(host: "192.0.2.21")]
        service.discoveryDelay = .seconds(30)
        let search = wizard.startDiscovery()
        await settle(until: { service.discoverCalls == 1 })
        wizard.cancel()
        await search.value
        #expect(service.discoveryWasCancelled && !wizard.isDiscovering && !wizard.hasDiscovered)
    }

    /// Once the engine is creating the accessory, Cancel doesn't interrupt it.
    @Test func cancelLeavesAnAddInProgressAlone() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.advanceToProbe(host: "192.0.2.21")
        await wizard.advanceToSummary()
        let add = wizard.startForward()
        wizard.cancel()
        await add.value
        #expect(service.added.count == 1 && wizard.addState == .added)
    }

    // MARK: Input handling

    @Test func discoveredCamerasAreUniqueByHost() async {
        let (wizard, service) = wizard()
        service.discovered = [
            DiscoveredCamera(host: "192.0.2.21", name: nil, hardware: "NVR", xAddrs: [URL(string: "http://192.0.2.21/onvif/device_service")!]),
            DiscoveredCamera(host: "192.0.2.22", name: "Porch"),
            DiscoveredCamera(host: "192.0.2.21", name: "Driveway", xAddrs: [URL(string: "http://192.0.2.21:8000/onvif/device_service")!]),
        ]
        await wizard.discover()
        #expect(wizard.discovered.map(\.host) == ["192.0.2.21", "192.0.2.22"])
        #expect(wizard.discovered[0].name == "Driveway" && wizard.discovered[0].hardware == "NVR")
        #expect(wizard.discovered[0].xAddrs.count == 2)
    }

    /// A name the wizard filled in follows the next camera probed; a name the person typed is kept.
    @Test func defaultNameFollowsTheProbedCamera() async {
        let (wizard, service) = wizard()
        service.discovered = [DiscoveredCamera(host: "192.0.2.21", name: "Driveway"), DiscoveredCamera(host: "192.0.2.22", name: "Porch")]
        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.discover()
        wizard.select(wizard.discovered[0])
        await wizard.goForward()
        wizard.username = "admin"
        await wizard.goForward()
        #expect(wizard.name == "Driveway")
        wizard.goBack()
        wizard.goBack()
        wizard.select(wizard.discovered[1])
        service.probeResult = .success(Samples.doorbellProbe)
        await wizard.goForward()
        await wizard.goForward()
        #expect(wizard.name == "Porch" && wizard.kind == .doorbell)

        wizard.name = "Front Door"
        wizard.goBack()
        wizard.goBack()
        wizard.select(wizard.discovered[0])
        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.goForward()
        await wizard.goForward()
        #expect(wizard.name == "Front Door")
    }

    /// Review finding (W4 round 2): `rtsps://` URLs were accepted (port 322 by default), but the engine's RTSP client
    /// speaks plain RTSP only, so such a camera could never be added or never streamed. They are refused, saying why.
    @Test func rtspOverTLSIsRefusedWithAReason() async {
        let (wizard, _) = wizard()
        wizard.vendorChoice = .rtspURL
        await wizard.goForward()
        #expect(wizard.step == .connect)
        wizard.mainStreamURLText = "rtsps://192.0.2.24:7441/live"
        #expect(wizard.connectionProblem == AddCameraWizardModel.rtspOverTLSUnsupported && !wizard.canContinue)
        #expect(wizard.endpoint == nil && AddCameraWizardModel.streamURL("rtsps://192.0.2.24/live") == nil)
        #expect(AddCameraWizardModel.rtspOverTLSUnsupported.contains("rtsp://"))
        wizard.mainStreamURLText = "rtsp://192.0.2.24/live"
        #expect(wizard.connectionProblem == nil && wizard.endpoint?.rtspPort == 554)
        wizard.subStreamURLText = "RTSPS://192.0.2.24:7441/sub"
        #expect(wizard.connectionProblem == AddCameraWizardModel.rtspOverTLSUnsupported)
        wizard.subStreamURLText = ""

        // A pasted rtsps address gives the camera's address, but its TLS port isn't the plain RTSP port.
        let (pasted, _) = self.wizard()
        pasted.host = "rtsps://192.0.2.24:7441/live"
        pasted.normalizeHost()
        #expect(pasted.host == "192.0.2.24" && pasted.rtspPort == 554)
    }

    /// Review finding (W4 round 2): a doorbell that reports no button (every Hikvision doorbell) rings only through the
    /// webhook, and no wizard page showed its doorbell URL.
    @Test func aDoorbellWithoutAButtonRingsThroughTheWebhook() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.advanceToProbe(host: "192.0.2.21")
        await wizard.goForward()
        #expect(wizard.step == .kind && wizard.kind == .camera && !wizard.ringsThroughWebhook)
        wizard.kind = .doorbell
        #expect(wizard.ringsThroughWebhook)

        let (reolink, other) = self.wizard()
        other.probeResult = .success(Samples.doorbellProbe)
        await reolink.advanceToProbe(host: "192.0.2.22")
        #expect(reolink.kind == .doorbell && !reolink.ringsThroughWebhook, "the camera reports its button")
    }

    /// A pasted URL or host:port is split into the address, port, HTTPS switch and credentials.
    @Test func pastedAddressesAreNormalized() async {
        let (wizard, service) = wizard()
        service.probeResult = .success(Samples.hikvisionProbe)
        wizard.host = "http://admin:pa55@192.0.2.40:8080/doc/page/login.asp"
        #expect(wizard.canContinue && wizard.hostProblem == nil)
        await wizard.goForward()
        #expect(wizard.step == .connect)
        #expect(wizard.host == "192.0.2.40" && wizard.httpPort == 8_080 && !wizard.useHTTPS)
        #expect(wizard.username == "admin" && wizard.password == "pa55")
        #expect(wizard.endpoint == CameraEndpoint(host: "192.0.2.40", httpPort: 8_080))

        let (secure, _) = self.wizard()
        secure.host = "https://camera.local/"
        await secure.goForward()
        #expect(secure.host == "camera.local" && secure.useHTTPS && secure.httpPort == 443)

        let (plain, _) = self.wizard()
        plain.host = "camera.local:8000"
        await plain.goForward()
        #expect(plain.host == "camera.local" && plain.httpPort == 8_000)
    }

    /// Review finding (W4 App): Use HTTPS left the port at 80, so every check spoke TLS to the HTTP port and failed with
    /// "No … interface answered". Switching it moves a default port (80 ↔ 443) with it; a port the person chose stays,
    /// and the field says which protocol the port is for.
    @Test func useHTTPSMovesTheDefaultPort() async {
        let (wizard, _) = wizard()
        wizard.host = "192.0.2.21"
        #expect(wizard.httpPort == 80 && wizard.httpPortTitle == "HTTP Port")
        wizard.useHTTPS = true
        #expect(wizard.httpPort == 443 && wizard.httpPortTitle == "HTTPS Port")
        #expect(wizard.endpoint == CameraEndpoint(host: "192.0.2.21", httpPort: 443, useHTTPS: true))
        wizard.useHTTPS = false
        #expect(wizard.httpPort == 80 && wizard.httpPortTitle == "HTTP Port")
        wizard.httpPort = 8_443
        wizard.useHTTPS = true
        #expect(wizard.httpPort == 8_443, "a port the person entered stays")
        wizard.useHTTPS = false
        #expect(wizard.httpPort == 8_443)

        // A pasted address sets both: its own port wins, else the scheme's default.
        let (pasted, _) = self.wizard()
        pasted.host = "https://camera.local:8443/"
        await pasted.goForward()
        #expect(pasted.useHTTPS && pasted.httpPort == 8_443)
        let (back, _) = self.wizard()
        back.useHTTPS = true
        back.host = "http://camera.local"
        await back.goForward()
        #expect(!back.useHTTPS && back.httpPort == 80)
        let (named, _) = self.wizard()
        named.useHTTPS = true
        named.host = "http://camera.local:443"
        await named.goForward()
        #expect(!named.useHTTPS && named.httpPort == 443, "the port the address names wins")
    }

    /// Review finding (W4 App): every wizard run makes a new camera ID, so adding a camera that is already set up made
    /// a second Home accessory with its own stream and event sessions to the camera. The search marks it, and the
    /// Review page names the camera that already shows it (a warning: the same address can be another channel).
    @Test func aCameraThatIsAlreadyAddedIsPointedOut() async throws {
        let (wizard, service) = wizard()
        var existing = CameraConfiguration(name: "Driveway", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.21"),
                                           username: "admin")
        existing.serialNumber = "SN-OTHER"
        service.configuredCameras = [existing]
        service.discovered = [DiscoveredCamera(host: "192.0.2.21", name: "Driveway"), DiscoveredCamera(host: "192.0.2.22", name: "Porch")]
        await wizard.discover()
        #expect(wizard.existingCamera(at: wizard.discovered[0].host)?.id == existing.id)
        #expect(wizard.existingCamera(at: wizard.discovered[1].host) == nil)
        #expect(wizard.existingCamera(at: "192.0.2.21".uppercased())?.id == existing.id)

        service.probeResult = .success(Samples.hikvisionProbe)
        await wizard.advanceToProbe(host: "192.0.2.21")
        await wizard.advanceToSummary()
        #expect(wizard.alreadyAdded?.id == existing.id, "same address and ports")
        #expect(wizard.canContinue, "a warning, not a block")

        // Another port on the same address (an NVR's other channel) is not the same camera…
        wizard.goBack()
        wizard.goBack()
        wizard.goBack()
        wizard.goBack()
        wizard.goBack()
        #expect(wizard.step == .connect)
        wizard.httpPort = 8_080
        await wizard.advanceToSummary()
        #expect(wizard.alreadyAdded == nil)

        // …unless the camera reports the serial number of a configured one (its address changed since).
        existing.serialNumber = Samples.hikvisionProbe.serialNumber
        service.configuredCameras = [existing]
        #expect(wizard.alreadyAdded?.id == existing.id)
    }

    /// RTSP URL cameras on one host are often an NVR's channels: only the same main stream is the same camera. The demo
    /// camera is never a duplicate.
    @Test func streamURLsAndTheDemoCameraAreComparedByWhatTheyShow() async {
        let (wizard, service) = wizard()
        var existing = CameraConfiguration(name: "Side Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.24", rtspPort: 8554),
                                           username: "")
        existing.mainStreamURL = URL(string: "rtsp://192.0.2.24:8554/live")
        let demo = CameraConfiguration(name: "Demo", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        service.configuredCameras = [existing, demo]
        service.probeResult = .success(Samples.plainRTSPProbe)
        wizard.vendorChoice = .rtspURL
        await wizard.goForward()
        wizard.mainStreamURLText = "rtsp://viewer:pw@192.0.2.24:8554/live"
        await wizard.advanceToSummary()
        #expect(wizard.alreadyAdded?.id == existing.id)
        #expect(wizard.existingCamera(at: "localhost") == nil, "the demo camera has no address of its own")

        let (other, otherService) = self.wizard()
        otherService.configuredCameras = [existing, demo]
        otherService.probeResult = .success(PreviewFixtures.probeResult(vendor: .demo, endpoint: CameraEndpoint(host: "localhost"),
                                                                        mainStreamURL: nil, subStreamURL: nil))
        other.vendorChoice = .demo
        await other.advanceToSummary()
        #expect(other.alreadyAdded == nil)
    }

    @Test func addressParsing() {
        #expect(HostInput("192.0.2.1") == HostInput(host: "192.0.2.1"))
        #expect(HostInput("  cam-1.local  ") == HostInput(host: "cam-1.local"))
        #expect(HostInput("192.0.2.1:8000") == HostInput(host: "192.0.2.1", port: 8_000))
        #expect(HostInput("fe80::1") == HostInput(host: "fe80::1"))
        #expect(HostInput("[fe80::1%en0]:8000") == HostInput(host: "fe80::1%en0", port: 8_000))
        #expect(HostInput("rtsp://192.0.2.1:8554/live") == HostInput(host: "192.0.2.1", port: 8_554, scheme: "rtsp"))
        #expect(HostInput("HTTPS://Camera.local") == HostInput(host: "Camera.local", scheme: "https"))
        for bad in ["", "   ", "two words", "192.0.2.1:99999", "192.0.2.1:", "host:abc", "ftp://192.0.2.1", "[fe80::1", "http://", "admin@"] {
            #expect(HostInput(bad) == nil, "accepted \(bad)")
        }
    }

    @Test func invalidAddressesCantContinue() {
        let (wizard, _) = wizard()
        wizard.host = "192.0.2.1 camera"
        #expect(!wizard.canContinue && wizard.hostProblem != nil)
        wizard.host = ""
        #expect(!wizard.canContinue && wizard.hostProblem == nil)   // nothing typed yet: no complaint
    }

    @Test func stepNumbering() {
        let (wizard, _) = wizard()
        #expect(wizard.stepNumber == 2 && wizard.stepCount == 8)   // the Camera Type page came first
        #expect(WizardStep.allCases.map(\.title).allSatisfy { !$0.isEmpty })
    }
}

extension AddCameraWizardModel {
    /// Host + admin/s3cret, then probe.
    func advanceToProbe(host: String) async {
        self.host = host
        await goForward()
        username = "admin"
        password = "s3cret"
        await goForward()
    }

    /// Continue until the Review page (bounded, in case a page can't continue).
    func advanceToSummary() async {
        for _ in 0..<WizardStep.allCases.count where step != .summary {
            await goForward()
        }
        #expect(step == .summary)
    }
}
