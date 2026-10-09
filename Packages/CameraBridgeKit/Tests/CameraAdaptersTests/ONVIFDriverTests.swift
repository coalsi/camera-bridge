// Loopback mock ONVIF camera (PlatformApple transport): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import MediaCore
import RTSP
import TestSupport
import Testing
@testable import CameraAdapters

@Suite(.timeLimit(.minutes(1))) struct ONVIFDriverTests {
    private let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)

    private static let fastTiming: ONVIFEventTiming = {
        var timing = ONVIFEventTiming()
        timing.pullTimeout = "PT1S"
        timing.replyTimeout = .seconds(5)
        timing.renewInterval = .milliseconds(150)
        timing.minimumPullInterval = .milliseconds(20)
        timing.policy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(50), maximum: .milliseconds(100), jitter: 0),
                                        healthyAfter: .seconds(30), minimumDelayAfterFailure: .zero)
        return timing
    }()

    private func backchannelFactory(_ offers: Bool) -> FakeRTSPFactory {
        let info = RTSPSessionInfo(tracks: [], backchannelFormat: offers ? AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1) : nil)
        return FakeRTSPFactory(FakeRTSPSession(info: info))
    }

    @Test func probeReadsDeviceProfilesStreamsAndCapabilities() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let rtsp = backchannelFactory(true)
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                 transport: UnusedTransport(), rtspFactory: rtsp.factory)
        let result = try await driver.probe()
        #expect(result.vendor == .onvif)
        #expect(result.manufacturer == "Reolink")
        #expect(result.model == "Reolink Video Doorbell WiFi")
        #expect(result.serialNumber == "00000000ABCD")
        #expect(result.firmware == "v3.0.0.4867_2505072124")
        let main = try #require(result.mainStream)
        #expect(main.url.absoluteString == "rtsp://127.0.0.1:554/Preview_01_main")   // host rewritten, credentials stripped
        #expect(main.videoCodec == .h264 && main.width == 2560 && main.height == 1920 && main.fps == 15)
        #expect(main.audioCodec == .aac && main.audioSampleRate == 16000 && main.audioChannels == 1)
        let sub = try #require(result.subStream)
        #expect(sub.url.absoluteString == "rtsp://127.0.0.1:554/Preview_01_sub")
        #expect(sub.width == 640 && sub.height == 480 && sub.audioCodec == nil)
        #expect(result.capabilities.events == [.motion, .person, .vehicle, .animal, .face, .package, .doorbell])
        #expect(result.capabilities.isDoorbell)
        #expect(result.capabilities.snapshotAPI)
        #expect(result.capabilities.twoWayAudio)
        // The backchannel probe asked for the ONVIF backchannel on the main stream, with credentials outside the URL.
        let configuration = try #require(rtsp.configurations.value.first)
        #expect(configuration.requestBackchannel)
        #expect(configuration.url == main.url)
        #expect(configuration.credentials == credentials)
        #expect(!camera.actions.value.contains("CreatePullPointSubscription"))
    }

    @Test func servicesAndStreamSetupRequests() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let client = ONVIFClient(deviceServiceURL: camera.deviceServiceURL, credentials: credentials)
        let services = try await client.services()
        #expect(services[ONVIFClient.mediaNamespace] == camera.baseURL.appending(path: "onvif/Media"))
        #expect(services[ONVIFClient.eventsNamespace] == camera.baseURL.appending(path: "onvif/Events"))
        let capabilities = try await client.capabilities()
        #expect(capabilities.pullPointSupported)
        #expect(capabilities.mediaURL == camera.baseURL.appending(path: "onvif/media_service"))
        _ = try await client.streamURI(profileToken: "001")
        let request = try #require(camera.server.requests.last { $0.bodyText.contains("GetStreamUri") })
        #expect(request.path == "/onvif/media_service")
        #expect(request.bodyText.contains("<tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>"))
        #expect(request.bodyText.contains("<trt:ProfileToken>001</trt:ProfileToken>"))
        #expect(request.head.headers["Content-Type"]?.hasPrefix("application/soap+xml") == true)
        #expect(!request.bodyText.contains(MockONVIFCamera.password))
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "wrong"),
                                 mainStreamURL: nil, subStreamURL: nil, transport: UnusedTransport(), rtspFactory: backchannelFactory(false).factory)
        await #expect(throws: CameraAdapterError.unauthorized) { try await driver.probe() }
    }

    @Test func wsSecurityUsesTheCameraClock() async throws {
        let camera = try await MockONVIFCamera.start(clockOffset: 3600)
        defer { camera.stop() }
        let client = ONVIFClient(deviceServiceURL: camera.deviceServiceURL, credentials: credentials)
        try await client.systemDateAndTime()
        _ = try await client.deviceInformation()
        let created = try #require(camera.createdStamps.value.last)
        let date = try #require(try? Date(created, strategy: .iso8601))
        #expect(abs(date.timeIntervalSinceNow - 3600) < 60)
    }

    @Test func snapshotUsesSnapshotURIWithDigest() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                 transport: UnusedTransport(), rtspFactory: backchannelFactory(false).factory)
        #expect(try await driver.snapshot() == MockONVIFCamera.jpeg)
        #expect(camera.server.requests(path: "/cgi-bin/api.cgi").count == 2)   // challenge + authenticated
    }

    @Test func talkbackIsNilWhenProbeFoundNoBackchannel() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                 transport: UnusedTransport(), rtspFactory: backchannelFactory(false).factory)
        #expect(driver.makeTalkbackSink() != nil)   // unknown before probing: the sink checks the SDP on open
        let result = try await driver.probe()
        #expect(!result.capabilities.twoWayAudio)
        #expect(driver.makeTalkbackSink() == nil)
    }

    @Test func pullPointReportsRejectedCredentials() async throws {
        let camera = try await MockONVIFCamera.start(pulls: ["Pull-CellMotion.xml"])
        defer { camera.stop() }
        var timing = Self.fastTiming
        timing.policy.delayAfterUnauthorized = .seconds(600)
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: HTTPCredentials(username: "admin", password: "wrong"),
                                 mainStreamURL: nil, subStreamURL: nil, transport: UnusedTransport(),
                                 rtspFactory: backchannelFactory(false).factory, timing: timing)
        let source = try #require(driver.makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.authenticationFailed) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.values == [.authenticationFailed])
        #expect(camera.actions.value.filter { $0 == "CreatePullPointSubscription" }.count <= 1, "no quick retry (the login guard may stop it before the camera is asked)")
        await source.stop()
    }

    @Test func pullPointDeliversEventsRenewsAndUnsubscribes() async throws {
        let camera = try await MockONVIFCamera.start(pulls: ["Pull-CellMotion.xml", "Pull-MyRuleDetector.xml"])
        defer { camera.stop() }
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                 transport: UnusedTransport(), rtspFactory: backchannelFactory(false).factory, timing: Self.fastTiming)
        let source = try #require(driver.makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.doorbellPressed) && $0.contains(.object(.person, false)) })
        #expect(await eventually { camera.actions.value.contains("Renew") })
        await source.stop()
        let events = recorder.values
        #expect(events.first == .eventChannel(connected: true))
        for expected: CameraEvent in [.motion(true), .object(.person, true), .object(.vehicle, true), .object(.animal, true),
                                      .object(.face, true), .object(.package, true), .doorbellPressed] {
            #expect(events.contains(expected), "missing \(expected)")
        }
        #expect(events.filter { $0 == .motion(true) }.count == 1, "motion stays on while sources overlap")
        #expect(camera.actions.value.last == "Unsubscribe")
        // Every subscription-manager call is addressed to the subscription and echoes its reference parameters.
        let headers = camera.subscriptionHeaders.value
        #expect(!headers.isEmpty)
        for header in headers {
            #expect(header.contains("/onvif/Subscription?Idx=00_0</wsa:To>"))
            #expect(header.contains(#"<dom0:SubscriptionId xmlns:dom0="http://www.example.com/subscription">42</dom0:SubscriptionId>"#))
        }
        let pull = try #require(camera.server.requests.first { $0.bodyText.contains("PullMessages") })
        #expect(pull.bodyText.contains("<tev:Timeout>PT1S</tev:Timeout><tev:MessageLimit>10</tev:MessageLimit>"))
        let create = try #require(camera.server.requests.first { $0.bodyText.contains("CreatePullPointSubscription") })
        #expect(create.bodyText.contains("<tev:InitialTerminationTime>PT2M</tev:InitialTerminationTime>"))
        #expect(create.path == "/onvif/event_service")
    }

    /// Review finding (W4 round 3): MotionAlarm from two video sources shared one hold source, so one source's stop ended
    /// motion the other still reported (and the camera's next start turned it on again). Each instance is its own OR
    /// input; a stop that carries fewer Source items than its start still ends it.
    @Test func pullPointKeepsMotionAlarmPerVideoSource() async throws {
        let camera = try await MockONVIFCamera.start(pulls: ["Pull-MotionAlarmTwoSources.xml"])
        defer { camera.stop() }
        let source = try pullPointSource(camera)
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.motion(false)) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.values.filter { $0 == .motion(true) || $0 == .motion(false) } == [.motion(true), .motion(false)],
                "on from the first start until both sources stopped")
        await source.stop()
    }

    private func pullPointSource(_ camera: MockONVIFCamera) throws -> any CameraEventSource {
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                 transport: UnusedTransport(), rtspFactory: backchannelFactory(false).factory, timing: Self.fastTiming)
        return try #require(driver.makeEventSource())
    }

    private func count(_ camera: MockONVIFCamera, _ action: String) -> Int { camera.actions.value.filter { $0 == action }.count }

    @Test func renewOfAnExpiredSubscriptionResubscribes() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.renewFault.set("ResourceUnknown")
        let source = try pullPointSource(camera)
        let recorder = Recorder(source.events())
        #expect(await eventually { self.count(camera, "CreatePullPointSubscription") >= 2 })
        #expect(await recorder.wait { $0.filter { $0 == .eventChannel(connected: true) }.count >= 2 })
        await source.stop()
    }

    @Test func subscriptionGoneMessageResubscribes() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.renewFault.set("InvalidArgVal")
        camera.renewFaultReason.set("You should create pull-point subscription first!")
        let source = try pullPointSource(camera)
        _ = source.events()
        #expect(await eventually { self.count(camera, "CreatePullPointSubscription") >= 2 })
        await source.stop()
    }

    /// Review finding (W4 round 4): no test waited for a successful Renew's answer (`pullPointDeliversEventsRenewsAndUnsubscribes`
    /// stops as soon as the Renew arrives), so a regression that took every Renew answer for a failure — the subscription
    /// torn down and created again at every renew interval, events lost in each gap — passed. Renews that succeed keep
    /// the one subscription: pulls go on on it, nothing is unsubscribed, and the channel never drops.
    @Test func successfulRenewsKeepTheSubscription() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let source = try pullPointSource(camera)   // renews every 150 ms
        let recorder = Recorder(source.events())
        #expect(await eventually {
            let actions = camera.actions.value
            guard let lastRenew = actions.lastIndex(of: "Renew") else { return false }
            return actions.filter { $0 == "Renew" }.count >= 4 && actions[(lastRenew + 1)...].contains("PullMessages")
        }, "several renew intervals, and pulls after the last Renew was answered")
        #expect(count(camera, "CreatePullPointSubscription") == 1, "renewed, not created again")
        #expect(!camera.actions.value.contains("Unsubscribe"))
        #expect(recorder.values == [.eventChannel(connected: true)], "the channel never dropped")
        await source.stop()
        #expect(camera.actions.value.last == "Unsubscribe")
    }

    /// Review finding (W4 round 4): the pause after an empty PullMessages answered faster than `minimumPullInterval` never
    /// ran in tests (the mock always took 50 ms, longer than the tests' 20 ms interval), so removing it — a camera that
    /// ignores `Timeout` would be pulled in a tight loop of authenticated SOAP requests — passed. A camera that answers
    /// empty pulls at once is pulled at most once per `minimumPullInterval`.
    @Test func instantEmptyPullsAreThrottled() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.instantEmptyPulls.set(true)
        var timing = Self.fastTiming
        timing.minimumPullInterval = .milliseconds(200)
        timing.renewInterval = .seconds(60)
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                 transport: UnusedTransport(), rtspFactory: backchannelFactory(false).factory, timing: timing)
        let source = try #require(driver.makeEventSource())
        _ = source.events()
        #expect(await eventually { self.count(camera, "PullMessages") >= 1 })
        let before = count(camera, "PullMessages")
        let started = ContinuousClock.now
        try await Task.sleep(for: .seconds(1))
        let pulls = count(camera, "PullMessages") - before
        let elapsed = ContinuousClock.now - started
        await source.stop()
        #expect(pulls <= Int(elapsed / .milliseconds(200)) + 2, "\(pulls) pulls in \(elapsed)")
        #expect(pulls >= 2, "it keeps pulling")
        #expect(count(camera, "CreatePullPointSubscription") == 1)
    }

    @Test func unsupportedRenewFallsBackToPulling() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.renewFault.set("ActionNotSupported")
        let source = try pullPointSource(camera)
        _ = source.events()
        #expect(await eventually { self.count(camera, "Renew") == 1 && self.count(camera, "PullMessages") >= 8 })
        #expect(count(camera, "Renew") == 1)
        #expect(count(camera, "CreatePullPointSubscription") == 1)
        await source.stop()
    }

    @Test func otherRenewFaultsAreRetriedThenGivenUp() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.renewFault.set("Receiver")
        let source = try pullPointSource(camera)
        _ = source.events()
        #expect(await eventually { self.count(camera, "PullMessages") >= 10 })
        #expect(count(camera, "Renew") == ONVIFPullPoint.maximumRenewFaults)
        #expect(count(camera, "CreatePullPointSubscription") == 1)
        await source.stop()
    }

    @Test func unsubscribeIsGuardedWhenCreateFails() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.failCreateSubscription.set(true)
        let driver = ONVIFDriver(endpoint: camera.endpoint, credentials: credentials, mainStreamURL: nil, subStreamURL: nil,
                                 transport: UnusedTransport(), rtspFactory: backchannelFactory(false).factory, timing: Self.fastTiming)
        let source = try #require(driver.makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await eventually { camera.actions.value.filter { $0 == "CreatePullPointSubscription" }.count >= 2 })   // retried
        await source.stop()
        #expect(!camera.actions.value.contains("Unsubscribe"))
        #expect(!recorder.values.contains(.eventChannel(connected: true)))
    }
}
#endif
