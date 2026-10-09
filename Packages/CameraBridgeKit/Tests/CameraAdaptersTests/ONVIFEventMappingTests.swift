import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

@Suite struct ONVIFEventMappingTests {
    private let hold: Duration = .seconds(20)

    private func notifications(_ name: String) throws -> [ONVIFNotification] {
        try ONVIFNotification.parse(pullMessagesResponse: XMLTree.parse(fixture("onvif/\(name)")))
    }

    private func signals(_ name: String) throws -> [[EventSignal]] {
        try notifications(name).map { ONVIFEventMapper.signals(for: $0, pulseHold: hold) }
    }

    @Test func parsesNotificationMessages() throws {
        let list = try notifications("Pull-CellMotion.xml")
        #expect(list.count == 1)
        let n = try #require(list.first)
        #expect(n.topic == "RuleEngine/CellMotionDetector/Motion")
        #expect(n.propertyOperation == "Changed")
        #expect(n.data["IsMotion"] == "true")
        #expect(n.source["Rule"] == "MyMotionDetectorRule")
        #expect(try notifications("Pull-Empty.xml").isEmpty)
    }

    @Test func topicNamespacesAreStrippedPerComponent() {
        #expect(ONVIFNotification.cleanTopic("tns1:RuleEngine/tnsvendor:MyRuleDetector/Visitor") == "RuleEngine/MyRuleDetector/Visitor")
        #expect(ONVIFNotification.cleanTopic(" tns1:VideoSource/MotionAlarm//. ") == "VideoSource/MotionAlarm")
    }

    @Test func motionAlarmIsLevel() throws {
        let s = try signals("Pull-MotionAlarm.xml")
        let source = "VideoSource/MotionAlarm|Source=000"
        #expect(s == [[.activate(.motion, source: source, hold: nil)], [.deactivate(.motion, source: source)]])
    }

    @Test func cellMotionHoldsTwentySecondsWithoutStop() throws {
        let start = try #require(try notifications("Pull-CellMotion.xml").first)
        #expect(ONVIFEventMapper.signals(for: start, pulseHold: hold)
                == [.activate(.motion, source: ONVIFEventMapper.instanceSource(start), hold: hold)])
        let stop = ONVIFNotification(topic: "RuleEngine/CellMotionDetector/Motion", propertyOperation: "Changed", source: [:],
                                     data: ["IsMotion": "false"])
        #expect(ONVIFEventMapper.signals(for: stop, pulseHold: hold) == [.deactivate(.motion, source: "RuleEngine/CellMotionDetector/Motion")])
    }

    @Test func objectDetectionClassTypes() throws {
        let s = try signals("Pull-ObjectDetection.xml")
        #expect(s[0] == [.activate(.object(.person), source: "ObjectDetection", hold: hold), .activate(.motion, source: "ObjectDetection", hold: hold)])
        #expect(s[1] == [.activate(.object(.vehicle), source: "ObjectDetection", hold: hold),
                         .activate(.object(.animal), source: "ObjectDetection", hold: hold),
                         .activate(.motion, source: "ObjectDetection", hold: hold)])
    }

    @Test func reolinkMyRuleDetectorTopics() throws {
        let s = try signals("Pull-MyRuleDetector.xml")
        func source(_ leaf: String) -> String { "RuleEngine/MyRuleDetector/\(leaf)|Source=000" }
        #expect(s[0] == [.activate(.object(.person), source: source("PeopleDetect"), hold: nil),
                         .activate(.motion, source: source("PeopleDetect"), hold: nil)])
        #expect(s[1] == [.activate(.object(.vehicle), source: source("VehicleDetect"), hold: nil),
                         .activate(.motion, source: source("VehicleDetect"), hold: nil)])
        #expect(s[2] == [.activate(.object(.animal), source: source("DogCatDetect"), hold: nil),
                         .activate(.motion, source: source("DogCatDetect"), hold: nil)])
        #expect(s[3] == [.activate(.object(.face), source: source("FaceDetect"), hold: nil), .activate(.motion, source: source("FaceDetect"), hold: nil)])
        #expect(s[4] == [.activate(.object(.package), source: source("PackageDetect"), hold: nil),
                         .activate(.motion, source: source("PackageDetect"), hold: nil)])
        #expect(s[5] == [.ring])
        #expect(s[6] == [.deactivate(.object(.person), source: source("PeopleDetect")), .deactivate(.motion, source: source("PeopleDetect"))])
    }

    @Test func visitorInitializedStateIsNotARing() {
        let initialized = ONVIFNotification(topic: "RuleEngine/MyRuleDetector/Visitor", propertyOperation: "Initialized", source: [:],
                                            data: ["State": "true"])
        #expect(ONVIFEventMapper.signals(for: initialized, pulseHold: hold).isEmpty)
        let released = ONVIFNotification(topic: "RuleEngine/MyRuleDetector/Visitor", propertyOperation: "Changed", source: [:],
                                         data: ["State": "false"])
        #expect(ONVIFEventMapper.signals(for: released, pulseHold: hold).isEmpty)
    }

    @Test func tamperTopics() throws {
        let s = try signals("Pull-Tamper.xml")
        let topics = ["GlobalSceneChange/ImagingService", "ImageTooDark/ImagingService", "ImageTooBlurry/AnalyticsService",
                      "ImageTooBright/ImagingService", "SignalLoss"]
        #expect(s == topics.map { [.activate(.tamper, source: "VideoSource/\($0)|Source=VideoSourceToken", hold: nil)] })
    }

    @Test func digitalInputAndDetectedSound() throws {
        let s = try signals("Pull-DigitalInputAndSound.xml")
        let input = "Device/Trigger/DigitalInput|InputToken=DigitalInputToken_1"
        #expect(s[0] == [.deactivate(.digitalInput("DigitalInputToken_1"), source: input)])
        #expect(s[1] == [.activate(.digitalInput("DigitalInputToken_1"), source: input, hold: nil)])
        #expect(s[2] == [.activate(.audioAlarm, source: "AudioAnalytics/Audio/DetectedSound|AudioSourceConfigurationToken=AudioSourceToken|Rule=SoundRule",
                                   hold: nil)])
    }

    @Test func mobotixRingAndUnknownTopics() {
        let ring = ONVIFNotification(topic: "VideoSource/Alarm", propertyOperation: "Changed", source: [:], data: ["Value": "Ring"])
        #expect(ONVIFEventMapper.signals(for: ring, pulseHold: hold) == [.ring])
        let unknown = ONVIFNotification(topic: "Monitoring/ProcessorUsage", propertyOperation: "Changed", source: [:], data: ["Value": "12"])
        #expect(ONVIFEventMapper.signals(for: unknown, pulseHold: hold).isEmpty)
    }

    // MARK: Property instances (review finding, W4 round 3)

    /// Runs `list` through one subscription's mapping into an `EventHoldState`: the events, and the keys still on.
    private func run(_ list: [ONVIFNotification]) async -> (events: [CameraEvent], active: Set<HoldKey>) {
        let events = Box<[CameraEvent]>([])
        let state = EventHoldState { event in events.update { $0.append(event) } }
        var mapping = ONVIFEventMapping()
        for notification in list { await state.apply(mapping.signals(for: notification, pulseHold: hold)) }
        let active = await state.activeKeys()
        await state.cancelAll()
        return (events.value, active)
    }

    private func message(_ topic: String, _ state: Bool, source: [String: String], operation: String = "Changed",
                         item: String = "State") -> ONVIFNotification {
        ONVIFNotification(topic: topic, propertyOperation: operation, source: source, data: [item: state ? "true" : "false"])
    }

    /// Imaging §5.5.1 defines each tamper topic once per detecting service, each with its own state: the analytics
    /// service's `Initialized` false right after subscribing must not end the tamper the imaging service reports.
    @Test func tamperFromOneDetectingServiceDoesNotEndAnothers() async {
        let imaging = message("VideoSource/ImageTooDark/ImagingService", true, source: ["Source": "VideoSourceToken"])
        let analytics = message("VideoSource/ImageTooDark/AnalyticsService", false,
                                source: ["VideoSourceConfigurationToken": "VSC_1", "VideoAnalyticsConfigurationToken": "VAC_1", "Rule": "Tamper"],
                                operation: "Initialized")
        let recording = message("VideoSource/ImageTooDark/RecordingService", false, source: ["RecordingToken": "Rec_1"], operation: "Initialized")
        var result = await run([imaging, analytics, recording])
        #expect(result.events == [.tamper(true)])
        #expect(result.active == [.tamper])
        result = await run([imaging, analytics, message("VideoSource/ImageTooDark/ImagingService", false, source: ["Source": "VideoSourceToken"])])
        #expect(result.events == [.tamper(true), .tamper(false)])
        #expect(result.active.isEmpty)
    }

    /// MotionAlarm is reported per video source (multi-sensor cameras): one source's stop leaves the other's motion on.
    @Test func motionAlarmIsPerVideoSource() async {
        let topic = "VideoSource/MotionAlarm"
        var result = await run([message(topic, true, source: ["Source": "VS_1"]), message(topic, true, source: ["Source": "VS_2"]),
                                message(topic, false, source: ["Source": "VS_2"])])
        #expect(result.events == [.motion(true)])
        #expect(result.active == [.motion])
        result = await run([message(topic, true, source: ["Source": "VS_1"]), message(topic, true, source: ["Source": "VS_2"]),
                            message(topic, false, source: ["Source": "VS_2"]), message(topic, false, source: ["Source": "VS_1"])])
        #expect(result.events == [.motion(true), .motion(false)])
        #expect(result.active.isEmpty)
    }

    /// Two cell-motion rules: the second rule's stop does not cut the first rule's pulse short.
    @Test func cellMotionIsPerRule() async {
        let topic = "RuleEngine/CellMotionDetector/Motion"
        func rule(_ name: String) -> [String: String] {
            ["VideoSourceConfigurationToken": "VSC_1", "VideoAnalyticsConfigurationToken": "VAC_1", "Rule": name]
        }
        let result = await run([message(topic, true, source: rule("Rule1"), item: "IsMotion"),
                                message(topic, false, source: rule("Rule2"), item: "IsMotion")])
        #expect(result.events == [.motion(true)])
        #expect(result.active == [.motion])
    }

    /// A firmware whose stop carries fewer Source items than its start (or none, or its start had none) must still end
    /// the state: otherwise a level would stay on until the channel drops.
    @Test func aStopWhoseSourceItemsDifferFromItsStartStillEndsIt() async {
        let cell = "RuleEngine/CellMotionDetector/Motion"
        let full = ["VideoSourceConfigurationToken": "VSC_1", "VideoAnalyticsConfigurationToken": "VAC_1", "Rule": "MyMotion"]
        var result = await run([message(cell, true, source: full, operation: "Initialized", item: "IsMotion"),
                                message(cell, false, source: ["Rule": "MyMotion"], item: "IsMotion")])
        #expect(result.events == [.motion(true), .motion(false)], "fewer items")
        #expect(result.active.isEmpty)

        let alarm = "VideoSource/MotionAlarm"
        result = await run([message(alarm, true, source: ["Source": "VS_1"]), message(alarm, false, source: [:])])
        #expect(result.events == [.motion(true), .motion(false)], "no items on the stop")
        result = await run([message(alarm, true, source: [:]), message(alarm, false, source: ["Source": "VS_1"])])
        #expect(result.events == [.motion(true), .motion(false)], "no items on the start")
        result = await run([message(alarm, true, source: ["Source": "VS_1"]), message(alarm, true, source: ["Source": "VS_2"]),
                            message(alarm, false, source: [:])])
        #expect(result.events == [.motion(true), .motion(false)], "a stop without items ends every instance")

        let tamper = "VideoSource/GlobalSceneChange/ImagingService"
        result = await run([message(tamper, true, source: ["Source": "VideoSourceToken"]),
                            message(tamper, false, source: ["Source": "VideoSourceToken", "Extra": "1"])])
        #expect(result.events == [.tamper(true), .tamper(false)], "more items on the stop")
        #expect(result.active.isEmpty)
    }

    @Test func instanceSourceIsTheTopicWithItsSortedSourceItems() throws {
        let cell = try #require(try notifications("Pull-CellMotion.xml").first)
        #expect(ONVIFEventMapper.instanceSource(cell) == "RuleEngine/CellMotionDetector/Motion|Rule=MyMotionDetectorRule"
                + "|VideoAnalyticsConfigurationToken=VideoAnalyticsToken|VideoSourceConfigurationToken=VideoSourceToken")
        #expect(ONVIFEventMapper.instanceSource(message("VideoSource/MotionAlarm", true, source: [:])) == "VideoSource/MotionAlarm")
        // Camera-reported items are bounded (they become hold-state keys).
        let huge = message("VideoSource/MotionAlarm", true, source: Dictionary(uniqueKeysWithValues: (0..<50).map {
            ("Name\($0)" + String(repeating: "n", count: 500), String(repeating: "v", count: 5000))
        }))
        #expect(ONVIFEventMapper.instanceSource(huge).utf8.count < 2048)
    }

    @Test func capabilitiesFromTopicSet() throws {
        let tree = try XMLTree.parse(fixture("onvif/GetEventPropertiesResponse.xml"))
        let topics = ONVIFEventMapper.topics(inEventProperties: tree)
        #expect(topics.contains("RuleEngine/MyRuleDetector/Visitor"))
        #expect(topics.contains("VideoSource/MotionAlarm"))
        let kinds = ONVIFEventMapper.eventKinds(forTopics: topics)
        #expect(kinds == [.motion, .person, .vehicle, .animal, .face, .package, .doorbell])
    }
}

@Suite struct ONVIFDiscoveryMessageTests {
    @Test func probeMessageAsksForNetworkVideoTransmitters() throws {
        let data = ONVIFDiscovery.probeMessage(messageID: "1f2e3d4c-0000-4000-8000-000000000001")
        let tree = try XMLTree.parse(data)
        #expect(tree.name == "Envelope")
        #expect(tree.string("Header", "MessageID") == "uuid:1f2e3d4c-0000-4000-8000-000000000001")
        #expect(tree.string("Header", "Action") == "http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe")
        #expect(tree.string("Header", "To") == "urn:schemas-xmlsoap-org:ws:2005:04:discovery")
        let types = try #require(tree.element("Body", "Probe", "Types"))
        #expect(types.text == "dn:NetworkVideoTransmitter")
        #expect(String(decoding: data, as: UTF8.self).contains("xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\""))
    }

    @Test func parsesProbeMatches() throws {
        let cameras = ONVIFDiscovery.parseProbeMatches(try fixture("onvif/ProbeMatches.xml"), sender: "192.0.2.120")
        #expect(cameras.count == 1)
        let camera = try #require(cameras.first)
        #expect(camera.host == "192.0.2.120")
        #expect(camera.name == "Reolink Video Doorbell")
        #expect(camera.hardware == "DB_566128M5MP_W")
        #expect(camera.xAddrs.map(\.absoluteString) == ["http://192.0.2.120:8000/onvif/device_service",
                                                        "http://[2001:db8::120]:8000/onvif/device_service"])
    }

    @Test func probeMatchHostFallsBackToSenderAndGarbageIsIgnored() {
        let noXAddrs = """
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">\
        <e:Body><d:ProbeMatches><d:ProbeMatch><d:Scopes>onvif://www.onvif.org/name/Cam+One</d:Scopes></d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>
        """
        let cameras = ONVIFDiscovery.parseProbeMatches(Data(noXAddrs.utf8), sender: "192.0.2.7")
        #expect(cameras == [DiscoveredCamera(host: "192.0.2.7", name: "Cam One", hardware: nil, xAddrs: [])])
        #expect(ONVIFDiscovery.parseProbeMatches(Data("garbage".utf8), sender: "192.0.2.8").isEmpty)
        #expect(ONVIFDiscovery.parseProbeMatches(Data(), sender: nil).isEmpty)
    }

    @Test func mergesDuplicateAnswersPerHost() throws {
        let data = try fixture("onvif/ProbeMatches.xml")
        let merged = ONVIFDiscovery.merge([ONVIFDiscovery.parseProbeMatches(data, sender: "192.0.2.120"),
                                           ONVIFDiscovery.parseProbeMatches(data, sender: "192.0.2.120")].flatMap { $0 })
        #expect(merged.count == 1)
    }
}

@Suite struct ONVIFPullPointTimingTests {
    @Test func xsDurations() {
        #expect(ONVIFPullPoint.duration(xsDuration: "PT2M") == .seconds(120))
        #expect(ONVIFPullPoint.duration(xsDuration: "PT1M30S") == .seconds(90))
        #expect(ONVIFPullPoint.duration(xsDuration: "PT0.5S") == .milliseconds(500))
        #expect(ONVIFPullPoint.duration(xsDuration: "P1DT1H") == .seconds(90_000))
        #expect(ONVIFPullPoint.duration(xsDuration: " PT10S ") == .seconds(10))
        for bad in ["", "PT", "P", "2M", "PT2", "P1Y", "-PT1M", "PT1M2M", "PTxS", "PT1e999S", "PT99999999999999999999S"] {
            #expect(ONVIFPullPoint.duration(xsDuration: bad) == nil, "\(bad)")
        }
    }

    @Test func renewsBeforeAnyPullCouldOutliveTheSubscription() {
        let timing = ONVIFEventTiming()   // PT2M lifetime, 80 s reply timeout, 60 s interval
        let lifetime = Duration.seconds(120)
        #expect(!ONVIFPullPoint.renewDue(sinceRenew: .seconds(29), lifetime: lifetime, timing: timing))
        #expect(ONVIFPullPoint.renewDue(sinceRenew: .seconds(30), lifetime: lifetime, timing: timing))   // 30 + 80 ≥ 120 − 10
        #expect(ONVIFPullPoint.renewDue(sinceRenew: .seconds(59), lifetime: lifetime, timing: timing))
        // The subscription never lapses: a pull started just before the renew threshold ends ≥ 10 s before termination.
        for start in stride(from: 0, through: 29, by: 1) {
            #expect(Duration.seconds(start) + timing.replyTimeout <= lifetime - ONVIFPullPoint.renewMargin)
        }
        var fast = timing
        fast.renewInterval = .seconds(5)
        #expect(ONVIFPullPoint.renewDue(sinceRenew: .seconds(5), lifetime: .seconds(3600), timing: fast))
    }

    @Test func renewFaultClassification() {
        #expect(ONVIFPullPoint.RenewFault("ActionNotSupported: unsupported Renew") == .unsupported)
        #expect(ONVIFPullPoint.RenewFault("Receiver: Action not supported") == .unsupported)
        #expect(ONVIFPullPoint.RenewFault("ResourceUnknown") == .subscriptionGone)
        #expect(ONVIFPullPoint.RenewFault("InvalidArgVal: You should create pull-point subscription first!") == .subscriptionGone)
        #expect(ONVIFPullPoint.RenewFault("Receiver: internal error") == .other)
    }
}

/// Review finding (W4 round 3): with "Use HTTPS" only the device service used HTTPS. Media, events, PullPoint
/// (PullMessages / Renew / Unsubscribe) and snapshot requests followed the camera's reported `http://` XAddrs, sending
/// WS-Security digests, HTTP Digest/Basic answers and snapshots in cleartext (and failing on cameras with HTTP off).
@Suite struct ONVIFXAddrTests {
    private func resolve(_ reported: String, device: String) throws -> String {
        try ONVIFClient.serviceURL(#require(URL(string: reported)), deviceServiceURL: #require(URL(string: device))).absoluteString
    }

    @Test func httpsDeviceServiceUpgradesReportedHTTPAddresses() throws {
        let device = "https://192.168.1.20:443/onvif/device_service"
        #expect(try resolve("http://192.168.1.20/onvif/Media", device: device) == "https://192.168.1.20:443/onvif/Media")
        #expect(try resolve("http://10.0.0.5:80/onvif/media_service", device: device) == "https://192.168.1.20:443/onvif/media_service")
        #expect(try resolve("http://10.0.0.5:8000/onvif/Subscription?Idx=00_0", device: device)
                == "https://192.168.1.20:443/onvif/Subscription?Idx=00_0", "PullPoint subscription address")
        #expect(try resolve("http://10.0.0.5/cgi-bin/snapshot.cgi?channel=1", device: device)
                == "https://192.168.1.20:443/cgi-bin/snapshot.cgi?channel=1", "snapshot URI")
        #expect(try resolve("HTTP://10.0.0.5/onvif/Events", device: device).hasPrefix("https://192.168.1.20:443/"))
        // The device service's own port (none: the default 443), IPv6 hosts.
        #expect(try resolve("http://10.0.0.5/onvif/Media", device: "https://cam.example:8443/onvif/device_service")
                == "https://cam.example:8443/onvif/Media")
        #expect(try resolve("http://10.0.0.5:80/onvif/Media", device: "https://cam.example/onvif/device_service")
                == "https://cam.example/onvif/Media")
        #expect(try resolve("http://[fe80::1]:80/onvif/Media", device: "https://[2001:db8::20]:443/onvif/device_service")
                == "https://[2001:db8::20]:443/onvif/Media")
    }

    @Test func otherAddressesOnlyTakeTheConfiguredHost() throws {
        let https = "https://192.168.1.20:443/onvif/device_service"
        #expect(try resolve("https://10.0.0.5:8443/onvif/events", device: https) == "https://192.168.1.20:8443/onvif/events")
        #expect(try resolve("rtsp://10.0.0.5:554/Streaming/Channels/101", device: https) == "rtsp://192.168.1.20:554/Streaming/Channels/101")
        let http = "http://192.168.1.20:8000/onvif/device_service"
        #expect(try resolve("http://10.0.0.5:8000/onvif/Media", device: http) == "http://192.168.1.20:8000/onvif/Media")
        #expect(try resolve("http://10.0.0.5/onvif/Media", device: http) == "http://192.168.1.20/onvif/Media")
    }
}
