// Loopback mock ISAPI camera (PlatformApple transport): macOS only.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import MediaCore
import TestSupport
import Testing
@testable import CameraAdapters

/// Loopback Hikvision ISAPI device. Digest-protected; rejects any user but `admin`.
final class MockHikvisionCamera: Sendable {
    typealias AlertWriter = @Sendable (MockStreamWriter, Int) async -> Void
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0xFF, 0xD9])

    let server: MockHTTPServer
    let alertConnections = Box(0)
    let alertRequestTimes = Box<[ContinuousClock.Instant]>([])
    let audioBytes = Box(Data())
    let talkCalls = Box<[String]>([])
    /// The two-way channel's `audioCompressionType` (nil: the element is missing).
    let twoWayCompression = Box<String?>("G.711ulaw")
    /// The `TwoWayAudio` channels the device lists (an NVR lists only channel 1); other channels answer 404.
    let twoWayChannelIDs = Box(["1"])
    /// A host impersonating the camera answers the audio upload: it asks for Basic (and takes the audio once it gets it).
    let impersonatedAudioData = Box(false)
    /// `/ISAPI/Streaming/channels/<id>` documents, keyed by channel id ("101", "102", …): each has a `SmartCodec`
    /// element so `HomeKitReadinessAdvisor`/optimizer tests can read and flip it. `PUT` replaces the stored document
    /// (ISAPI semantics); `putChannelDocuments` records every body received, in order.
    let channelDocuments = Box<[String: String]>([
        "101": MockHikvisionCamera.channelDocument(id: "101", smartCodecEnabled: true),
        "102": MockHikvisionCamera.channelDocument(id: "102", smartCodecEnabled: true)])
    let putChannelDocuments = Box<[(id: String, body: String)]>([])
    /// Every channel `PUT` received, accepted or not.
    let channelPUTAttempts = Box(0)
    /// Channel `PUT`s answer HTTP 400 (the camera refuses the document).
    let rejectChannelPUT = Box(false)
    /// Channel `PUT`s answer success but the stored document stays as it was.
    let ignoreChannelPUT = Box(false)
    /// Channels `requestKeyFrame` was called on, in order; the call answers this HTTP status (a camera without it answers 404).
    let keyFrameRequests = Box<[String]>([])
    let keyFrameStatus = Box(200)

    /// `/ISAPI/System/Video/inputs/channels/<n>/overlays` documents by input channel ("1"): `PUT` replaces the stored one
    /// (`putOverlayDocuments` records every body, in order); an input with no document answers 404.
    let overlayDocuments = Box<[String: String]>(["1": MockHikvisionCamera.overlayDocument(dateTimeEnabled: true)])
    let putOverlayDocuments = Box<[(input: String, body: String)]>([])
    /// Overlay `PUT`s answer success but the stored document stays as it was.
    let ignoreOverlayPUT = Box(false)

    /// An on-screen display document: a channel name overlay (enabled) and the date/time overlay, with the layout
    /// elements a camera sends around them.
    static func overlayDocument(dateTimeEnabled: Bool?) -> String {
        let dateTime = dateTimeEnabled.map {
            "<DateTimeOverlay><enabled>\($0)</enabled><positionX>0</positionX><positionY>544</positionY><dateStyle>MM-DD-YYYY</dateStyle><timeStyle>24hour</timeStyle><displayWeek>true</displayWeek></DateTimeOverlay>"
        } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <VideoOverlay xmlns="http://www.hikvision.com/ver20/XMLSchema" version="2.0">
        <normalizedScreenSize><normalizedScreenWidth>704</normalizedScreenWidth><normalizedScreenHeight>576</normalizedScreenHeight></normalizedScreenSize>
        <attribute><transparent>false</transparent><flashing>false</flashing></attribute>
        <channelNameOverlay><enabled>true</enabled><positionX>512</positionX><positionY>64</positionY></channelNameOverlay>
        \(dateTime)
        </VideoOverlay>
        """
    }

    /// A channel document with the video values the encoder methods read: keyframe interval `gov`, frame rate (hundredths),
    /// bit rate (kbit/s), smart codec off.
    static func encoderDocument(id: String, gov: Int, frameRate: Int = 2500, bitrate: Int = 8192) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <StreamingChannel xmlns="http://www.hikvision.com/ver20/XMLSchema" version="2.0">
        <id>\(id)</id><channelName>Camera 1</channelName>
        <Video><enabled>true</enabled><videoCodecType>H.264</videoCodecType><videoResolutionWidth>1920</videoResolutionWidth>\
        <videoResolutionHeight>1080</videoResolutionHeight><videoQualityControlType>CBR</videoQualityControlType>\
        <constantBitRate>\(bitrate)</constantBitRate><maxFrameRate>\(frameRate)</maxFrameRate><GovLength>\(gov)</GovLength>\
        <SmartCodec><enabled>false</enabled></SmartCodec></Video>
        </StreamingChannel>
        """
    }

    static func channelDocument(id: String, smartCodecEnabled: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <StreamingChannel xmlns="http://www.hikvision.com/ver20/XMLSchema" version="2.0">
        <id>\(id)</id><channelName>Camera 1</channelName>
        <Video><videoCodecType>H.264</videoCodecType><videoResolutionWidth>1920</videoResolutionWidth>\
        <videoResolutionHeight>1080</videoResolutionHeight><maxFrameRate>2500</maxFrameRate>\
        <SmartCodec><enabled>\(smartCodecEnabled)</enabled></SmartCodec></Video>
        </StreamingChannel>
        """
    }

    var endpoint: CameraEndpoint { CameraEndpoint(host: "127.0.0.1", httpPort: Int(server.port)) }

    private init(server: MockHTTPServer, deviceInfo: String) {
        self.server = server
        self.deviceInfo = deviceInfo
    }

    /// `deviceInfo.xml` unless overridden.
    let deviceInfo: String

    static func start(deviceInfo: String? = nil, alertWriter: @escaping AlertWriter = { _, _ in }) async throws -> MockHikvisionCamera {
        let holder = Box<MockHikvisionCamera?>(nil)
        let server = try await MockHTTPServer.start { request in
            guard let camera = holder.value else { return .status(503) }
            return await camera.handle(request, alertWriter: alertWriter)
        }
        let camera = MockHikvisionCamera(server: server, deviceInfo: deviceInfo ?? ((try? fixtureText("hikvision/deviceInfo.xml")) ?? ""))
        holder.set(camera)
        return camera
    }

    func stop() { server.stop() }

    private func handle(_ request: MockRequest, alertWriter: @escaping AlertWriter) async -> MockResponse {
        if impersonatedAudioData.value, request.method == "PUT", request.path.hasSuffix("/audioData") {
            talkCalls.update { $0.append("audioData") }
            guard request.head.headers["Authorization"]?.lowercased().hasPrefix("basic") == true else {
                return .full(status: 401, headers: [("WWW-Authenticate", #"Basic realm="DS-2CD2387G2""#)], body: Data())
            }
            return .raw(status: 200, headers: []) { [audioBytes] chunk in audioBytes.update { $0.append(chunk) } }
        }
        guard isDigestAuthorization(request.head.headers["Authorization"]) else { return .digestChallenge() }
        let ok = #"<?xml version="1.0"?><ResponseStatus xmlns="http://www.hikvision.com/ver20/XMLSchema"><statusCode>1</statusCode></ResponseStatus>"#
        switch (request.method, request.path) {
        case ("GET", "/ISAPI/System/deviceInfo"): return .xml(deviceInfo)
        case ("GET", "/ISAPI/Streaming/channels"): return .xml((try? fixtureText("hikvision/streamingChannels.xml")) ?? "")
        case ("GET", "/ISAPI/Event/triggers"): return .xml((try? fixtureText("hikvision/triggers.xml")) ?? "")
        case ("GET", "/ISAPI/System/TwoWayAudio/channels"):
            let element = twoWayCompression.value.map { "<audioCompressionType>\($0)</audioCompressionType>" } ?? ""
            let xml = ((try? fixtureText("hikvision/twoWayAudioChannels.xml")) ?? "")
                .replacingOccurrences(of: "<audioCompressionType>G.711ulaw</audioCompressionType>", with: element)
            // The fixture's channel 1, once per listed channel.
            guard let start = xml.range(of: "<TwoWayAudioChannel "), let end = xml.range(of: "</TwoWayAudioChannel>") else { return .xml(xml) }
            let channel = String(xml[start.lowerBound..<end.upperBound])
            let channels = twoWayChannelIDs.value.map { channel.replacingOccurrences(of: "<id>1</id>", with: "<id>\($0)</id>") }
            return .xml(xml.replacingCharacters(in: start.lowerBound..<end.upperBound, with: channels.joined(separator: "\n")))
        case ("GET", "/ISAPI/Streaming/channels/101/picture"):
            guard request.query("snapShotImageType") == "JPEG" else { return .status(400) }
            return .full(status: 200, headers: [("Content-Type", "image/jpeg")], body: Self.jpeg)
        case ("GET", "/ISAPI/Event/notification/alertStream"):
            let index = alertConnections.update { $0 += 1; return $0 }
            alertRequestTimes.update { $0.append(.now) }
            return .stream(status: 200, headers: [("Content-Type", "multipart/mixed; boundary=boundary")]) { writer in
                await alertWriter(writer, index)
            }
        case ("PUT", let path) where path.hasPrefix("/ISAPI/System/TwoWayAudio/channels/"):
            let parts = path.dropFirst("/ISAPI/System/TwoWayAudio/channels/".count).split(separator: "/").map(String.init)
            guard parts.count == 2, twoWayChannelIDs.value.contains(parts[0]) else { return .status(404) }
            switch parts[1] {
            case "open", "close":
                talkCalls.update { $0.append(parts[1]) }
                return .xml(ok)
            case "audioData":
                talkCalls.update { $0.append("audioData") }
                guard request.head.headers["Content-Type"] == "application/octet-stream" else { return .status(400) }
                return .raw(status: 200, headers: []) { [audioBytes] chunk in audioBytes.update { $0.append(chunk) } }
            default:
                return .status(404)
            }
        case ("PUT", let path) where path.hasPrefix("/ISAPI/Streaming/channels/") && path.hasSuffix("/requestKeyFrame"):
            let id = String(path.dropFirst("/ISAPI/Streaming/channels/".count).dropLast("/requestKeyFrame".count))
            keyFrameRequests.update { $0.append(id) }
            return keyFrameStatus.value == 200 ? .xml(ok) : .status(keyFrameStatus.value)
        case ("GET", let path) where path.hasPrefix("/ISAPI/System/Video/inputs/channels/") && path.hasSuffix("/overlays"):
            let input = path.dropFirst("/ISAPI/System/Video/inputs/channels/".count).dropLast("/overlays".count)
            guard let document = overlayDocuments.value[String(input)] else { return .status(404) }
            return .xml(document)
        case ("PUT", let path) where path.hasPrefix("/ISAPI/System/Video/inputs/channels/") && path.hasSuffix("/overlays"):
            let input = String(path.dropFirst("/ISAPI/System/Video/inputs/channels/".count).dropLast("/overlays".count))
            guard overlayDocuments.value[input] != nil else { return .status(404) }
            if ignoreOverlayPUT.value { return .xml(ok) }
            putOverlayDocuments.update { $0.append((input, request.bodyText)) }
            overlayDocuments.update { $0[input] = request.bodyText }
            return .xml(ok)
        case ("GET", let path) where path.hasPrefix("/ISAPI/Streaming/channels/") && !path.hasSuffix("/picture"):
            let id = String(path.dropFirst("/ISAPI/Streaming/channels/".count))
            guard let document = channelDocuments.value[id] else { return .status(404) }
            return .xml(document)
        case ("PUT", let path) where path.hasPrefix("/ISAPI/Streaming/channels/") && !path.contains("TwoWayAudio"):
            let id = String(path.dropFirst("/ISAPI/Streaming/channels/".count))
            let body = request.bodyText
            channelPUTAttempts.update { $0 += 1 }
            if rejectChannelPUT.value { return .status(400) }
            if ignoreChannelPUT.value { return .xml(ok) }
            putChannelDocuments.update { $0.append((id, body)) }
            channelDocuments.update { $0[id] = body }
            return .xml(ok)
        default:
            return .status(404)
        }
    }
}

private func alertPart(_ name: String) -> Data {
    hikPart(boundary: "boundary", contentType: "application/xml; charset=\"UTF-8\"", body: (try? fixture("hikvision/\(name)")) ?? Data())
}

/// An alert for NVR channel `channel` (`fielddetection` with a human target, or `VMD`).
private func channelAlertPart(_ type: String, channel: Int) -> Data {
    let target = type == "fielddetection" ? "<DetectionRegionList><DetectionRegionEntry><detectionTarget>human</detectionTarget></DetectionRegionEntry></DetectionRegionList>" : ""
    let xml = """
    <EventNotificationAlert version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema"><channelID>\(channel)</channelID>\
    <eventType>\(type)</eventType><eventState>active</eventState>\(target)</EventNotificationAlert>
    """
    return hikPart(boundary: "boundary", contentType: "application/xml", body: Data(xml.utf8))
}

@Suite(.timeLimit(.minutes(1))) struct HikvisionDriverTests {
    private let credentials = HTTPCredentials(username: "admin", password: "pa55")

    private func timing(idle: Duration = .seconds(30), minimumDelay: Duration = .milliseconds(200)) -> HikvisionEventTiming {
        var timing = HikvisionEventTiming()
        timing.pulseHold = .milliseconds(300)
        timing.idleTimeout = idle
        timing.policy = ReconnectPolicy(backoff: Backoff(initial: .milliseconds(20), maximum: .milliseconds(50), jitter: 0),
                                        healthyAfter: .seconds(10), minimumDelayAfterFailure: minimumDelay)
        return timing
    }

    private func driver(_ camera: MockHikvisionCamera, credentials: HTTPCredentials? = nil, timing: HikvisionEventTiming = HikvisionEventTiming(),
                        mainStreamURL: URL? = nil) -> HikvisionDriver {
        HikvisionDriver(endpoint: camera.endpoint, credentials: credentials ?? self.credentials, mainStreamURL: mainStreamURL, subStreamURL: nil,
                        transport: PlatformNetworkTransport(), timing: timing)
    }

    @Test func probeReadsDeviceChannelsAndCapabilities() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let result = try await driver(camera).probe()
        #expect(result.vendor == .hikvision)
        #expect(result.manufacturer == "Hikvision")
        #expect(result.model == "DS-2CD2387G2P-LSU/SL")
        #expect(result.serialNumber == "DS-2CD2387G2P-LSU/SL20230101AAWRL00000001")
        #expect(result.firmware == "V5.7.15 build 230329")
        let main = try #require(result.mainStream)
        #expect(main.url.absoluteString == "rtsp://127.0.0.1:554/ISAPI/Streaming/channels/101")
        #expect(main.videoCodec == .h264 && main.width == 4256 && main.height == 1888 && main.fps == 20)
        #expect(main.audioCodec == .pcmu && main.audioSampleRate == 8000 && main.audioChannels == 1)
        let sub = try #require(result.subStream)
        #expect(sub.url.absoluteString == "rtsp://127.0.0.1:554/ISAPI/Streaming/channels/102")
        #expect(sub.width == 640 && sub.audioCodec == nil)
        #expect(result.capabilities.events == [.motion, .person, .vehicle, .tamper, .digitalInput])
        #expect(result.capabilities.twoWayAudio)
        #expect(result.capabilities.snapshotAPI)
        #expect(!result.capabilities.isDoorbell)
    }

    @Test func rejectedCredentialsAreUnauthorized() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let bad = driver(camera, credentials: HTTPCredentials(username: "nobody", password: "x"))
        await #expect(throws: CameraAdapterError.unauthorized) { try await bad.probe() }
    }

    @Test func snapshotFromPictureEndpoint() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        #expect(try await driver(camera).snapshot() == MockHikvisionCamera.jpeg)
    }

    @Test func alertStreamDeliversMotionAndSmartEvents() async throws {
        let camera = try await MockHikvisionCamera.start { writer, _ in
            await writer.write(alertPart("alert-vmd.xml"))
            await writer.write(alertPart("alert-fielddetection-human.xml"))
            await writer.write(hikPart(boundary: "boundary", contentType: "image/jpeg", body: MockHikvisionCamera.jpeg))
            await writer.write(alertPart("alert-videoloss-heartbeat.xml"))
            try? await Task.sleep(for: .seconds(20))
        }
        defer { camera.stop() }
        let source = try #require(driver(camera, timing: timing()).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await recorder.wait { $0.contains(.object(.person, false)) && $0.contains(.motion(false)) })
        await source.stop()
        let events = recorder.values
        #expect(events.first == .eventChannel(connected: true))
        #expect(events.firstIndex(of: .motion(true)).map { $0 < events.firstIndex(of: .motion(false)) ?? 0 } == true)
        #expect(events.contains(.object(.person, true)))
        #expect(events.filter { $0 == .motion(true) }.count == 1)
        #expect(camera.alertConnections.value == 1)
    }

    @Test func reconnectsTenSecondsAfterAFastDeath() async throws {
        let camera = try await MockHikvisionCamera.start { writer, _ in
            await writer.write(alertPart("alert-vmd.xml"))   // then the camera closes the stream
        }
        defer { camera.stop() }
        let source = try #require(driver(camera, timing: timing(minimumDelay: .milliseconds(300))).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await eventually { camera.alertConnections.value >= 2 })
        #expect(await recorder.wait { $0.filter { $0 == .eventChannel(connected: true) }.count >= 2 })
        await source.stop()
        let times = camera.alertRequestTimes.value
        try #require(times.count >= 2)
        #expect(times[1] - times[0] >= .milliseconds(290))
        #expect(recorder.values.contains(.eventChannel(connected: false)))
    }

    @Test func restartsAfterIdleTimeout() async throws {
        let camera = try await MockHikvisionCamera.start { writer, _ in
            await writer.write(alertPart("alert-videoloss-heartbeat.xml"))
            try? await Task.sleep(for: .seconds(20))   // silent but open
        }
        defer { camera.stop() }
        let source = try #require(driver(camera, timing: timing(idle: .milliseconds(400), minimumDelay: .milliseconds(50))).makeEventSource())
        let recorder = Recorder(source.events())
        #expect(await eventually { camera.alertConnections.value >= 2 })
        await source.stop()
        let times = camera.alertRequestTimes.value
        try #require(times.count >= 2)
        #expect(times[1] - times[0] >= .milliseconds(390))
        #expect(!recorder.values.contains(.motion(true)))
    }

    @Test func nvrChannelsShareOneAlertStreamAndFilterByChannel() async throws {
        let camera = try await MockHikvisionCamera.start { writer, _ in
            try? await Task.sleep(for: .milliseconds(300))   // both channel cameras subscribe
            await writer.write(channelAlertPart("fielddetection", channel: 2))
            await writer.write(channelAlertPart("VMD", channel: 1))
            try? await Task.sleep(for: .seconds(20))
        }
        defer { camera.stop() }
        let nvr = "rtsp://127.0.0.1:554/Streaming/Channels/"
        let channel1 = driver(camera, timing: timing(), mainStreamURL: URL(string: nvr + "101"))
        let channel2 = driver(camera, timing: timing(), mainStreamURL: URL(string: nvr + "201"))
        let source1 = try #require(channel1.makeEventSource())
        let source2 = try #require(channel2.makeEventSource())
        let recorder1 = Recorder(source1.events())
        let recorder2 = Recorder(source2.events())
        #expect(await recorder1.wait { $0.contains(.motion(true)) })
        #expect(await recorder2.wait { $0.contains(.object(.person, true)) && $0.contains(.motion(true)) })
        #expect(camera.alertConnections.value == 1, "one alertStream per device")
        #expect(!recorder1.values.contains(.object(.person, true)), "channel 2's person is not channel 1's")
        #expect(recorder1.values.first == .eventChannel(connected: true) && recorder2.values.first == .eventChannel(connected: true))
        await source1.stop()
        #expect(camera.alertConnections.value == 1)
        await source2.stop()
        // The last release closed the shared stream: a new camera source opens a new one (it would join a live hub).
        let again = try #require(channel1.makeEventSource())
        _ = again.events()
        #expect(await eventually { camera.alertConnections.value == 2 })
        await again.stop()
    }

    @Test func rejectedCredentialsAreNotRetriedQuickly() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        var slow = timing(minimumDelay: .milliseconds(20))
        slow.policy.delayAfterUnauthorized = .seconds(600)
        let source = try #require(driver(camera, credentials: HTTPCredentials(username: "nobody", password: "x"), timing: slow).makeEventSource())
        _ = source.events()
        #expect(await eventually { !camera.server.requests(path: "/ISAPI/Event/notification/alertStream").isEmpty })
        try await Task.sleep(for: .milliseconds(500))
        // One attempt (challenge + one Digest answer), not one every 20 ms: the camera's illegal-login lockout is never hit.
        #expect(camera.server.requests(path: "/ISAPI/Event/notification/alertStream").count <= 2)
        await source.stop()
    }

    @Test func rejectedCredentialsAreReportedToEveryChannel() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        var slow = timing(minimumDelay: .milliseconds(20))
        slow.policy.delayAfterUnauthorized = .seconds(600)
        let wrong = HTTPCredentials(username: "nobody", password: "x")
        let first = try #require(driver(camera, credentials: wrong, timing: slow).makeEventSource())
        let firstRecorder = Recorder(first.events())
        #expect(await firstRecorder.wait { $0.contains(.authenticationFailed) })
        // A camera on the same device that subscribes while the shared stream waits out its retry delay learns it too.
        let second = try #require(driver(camera, credentials: wrong, timing: slow).makeEventSource())
        let secondRecorder = Recorder(second.events())
        #expect(await secondRecorder.wait { $0.contains(.authenticationFailed) })
        #expect(!firstRecorder.values.contains(.eventChannel(connected: true)))
        #expect(camera.server.requests(path: "/ISAPI/Event/notification/alertStream").count <= 2, "still one attempt per 10 min")
        await first.stop()
        await second.stop()
    }

    @Test func explicitChannelOneFiltersTheSharedStream() {
        let url = URL(string: "rtsp://192.0.2.1:554/Streaming/Channels/101")
        #expect(HikvisionDriver.explicitCameraNumber(from: url) == 1)
        #expect(HikvisionDriver.explicitCameraNumber(from: URL(string: "rtsp://192.0.2.1/live")) == nil)
        #expect(HikvisionDriver.explicitCameraNumber(from: nil) == nil)
        let transport = UnusedTransport()
        let endpoint = CameraEndpoint(host: "192.0.2.1")
        #expect(HikvisionDriver(endpoint: endpoint, credentials: nil, mainStreamURL: url, subStreamURL: nil, transport: transport)
            .eventChannelFilter == "1")
        #expect(HikvisionDriver(endpoint: endpoint, credentials: nil, mainStreamURL: nil, subStreamURL: nil, transport: transport)
            .eventChannelFilter == nil)
    }

    @Test func intercomsAreNotReportedAsDoorbellsWithoutARingEvent() async throws {
        let info = (try fixtureText("hikvision/deviceInfo.xml"))
            .replacingOccurrences(of: "DS-2CD2387G2P-LSU/SL</model>", with: "DS-KV6113-WPE1(C)</model>")
        let camera = try await MockHikvisionCamera.start(deviceInfo: info)
        defer { camera.stop() }
        let result = try await driver(camera).probe()
        #expect(result.model == "DS-KV6113-WPE1(C)")
        #expect(!result.capabilities.isDoorbell)
        #expect(!result.capabilities.events.contains(.doorbell))
    }

    @Test func aStalledAudioUploadTimesOut() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let transport = StallingUploadTransport()
        let sink = HikvisionTalkbackSink(endpoint: camera.endpoint, credentials: credentials, transport: transport, sendTimeout: .milliseconds(200))
        try await sink.open()
        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) { try await sink.send(audioFrame(1)) }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(transport.connection.closed.value)
        await #expect(throws: CameraAdapterError.unsupported("talkback is not open")) { try await sink.send(audioFrame(2)) }
        await sink.close()   // the camera's two-way session still gets closed
        #expect(await eventually { camera.talkCalls.value == ["close", "open", "close"] })
    }

    /// The timer closes the upload, which fails the stalled send with `.closed` before the timer itself finishes: the
    /// caller still learns that the send timed out.
    @Test func aStalledUploadTimesOutEvenWhenClosingFailsItFirst() async throws {
        let transport = StallingUploadTransport(closeDelay: 0.2)
        try await transport.connection.send(Data([0]))   // the request head goes through; audio then stalls
        await #expect(throws: TransportError.timedOut) {
            try await HikvisionTalkbackSink.send(Data(count: 160), on: transport.connection, timeout: .milliseconds(100))
        }
        #expect(transport.connection.closed.value)
    }

    /// Talkback sends raw G.711 bytes: a camera set to another two-way codec would play them as noise.
    @Test func talkbackRefusesATwoWayCodecOtherThanG711() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        for compression in ["G.726", "G.722.1", "MP2L2", "AAC"] {
            camera.twoWayCompression.set(compression)
            let sink = try #require(driver(camera).makeTalkbackSink())
            let error = await #expect(throws: CameraAdapterError.self) { try await sink.open() }
            guard case .unsupported(let reason)? = error else {
                Issue.record("\(compression): expected .unsupported, got \(String(describing: error))")
                continue
            }
            #expect(reason.contains(compression) && reason.contains("G.711"), "\(reason)")
        }
        #expect(!camera.talkCalls.value.contains("open"), "the camera's two-way session is never opened")
    }

    @Test func talkbackFollowsTheReportedG711Variant() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let sink = try #require(driver(camera).makeTalkbackSink())
        let cases: [(String?, AudioCodec)] = [("G.711alaw", .pcma), ("G.711ulaw", .pcmu), ("G.711alaw", .pcma), (nil, .pcmu)]
        for (compression, codec) in cases {
            camera.twoWayCompression.set(compression)
            try await sink.open()
            #expect(sink.inputFormat == AudioFormat(codec: codec, sampleRate: 8000, channels: 1), "\(compression ?? "not reported")")
            await sink.close()
        }
    }

    /// Wake or a network change re-subscribes every camera's events (`CameraRuntime.refresh`: stop, then a new source
    /// from the same driver). Cameras sharing an NVR's alertStream must get a fresh stream too — once all of them
    /// re-subscribed, not once per camera — and a camera that merely joins must not restart it.
    @Test func resubscribingEveryNVRChannelReconnectsTheSharedStreamOnce() async throws {
        let camera = try await MockHikvisionCamera.start { writer, index in
            guard index > 1 else {
                await writer.write(alertPart("alert-videoloss-heartbeat.xml"))
                try? await Task.sleep(for: .seconds(20))   // then the stream went half-open during sleep: silent
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
            await writer.write(channelAlertPart("VMD", channel: 1))
            await writer.write(channelAlertPart("VMD", channel: 2))
            try? await Task.sleep(for: .seconds(20))
        }
        defer { camera.stop() }
        let nvr = "rtsp://127.0.0.1:554/Streaming/Channels/"
        let channel1 = driver(camera, timing: timing(), mainStreamURL: URL(string: nvr + "101"))
        let channel2 = driver(camera, timing: timing(), mainStreamURL: URL(string: nvr + "201"))
        let first1 = try #require(channel1.makeEventSource())
        let first2 = try #require(channel2.makeEventSource())
        let early1 = Recorder(first1.events())
        let early2 = Recorder(first2.events())
        #expect(await early1.wait { $0.contains(.eventChannel(connected: true)) })
        #expect(await early2.wait { $0.contains(.eventChannel(connected: true)) })
        #expect(camera.alertConnections.value == 1)

        await first1.stop()
        let second1 = try #require(channel1.makeEventSource())
        let recorder1 = Recorder(second1.events())
        await first2.stop()
        let second2 = try #require(channel2.makeEventSource())
        let recorder2 = Recorder(second2.events())
        #expect(await eventually { camera.alertConnections.value >= 2 }, "the shared stream is reconnected")
        #expect(await recorder1.wait { $0.contains(.motion(true)) })
        #expect(await recorder2.wait { $0.contains(.motion(true)) })

        // A camera that joins (its driver's first source) shares the live stream.
        let channel3 = driver(camera, timing: timing(), mainStreamURL: URL(string: nvr + "301"))
        let third = try #require(channel3.makeEventSource())
        let recorder3 = Recorder(third.events())
        #expect(await recorder3.wait { $0.contains(.eventChannel(connected: true)) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(camera.alertConnections.value == 2, "one reconnect for the whole refresh")
        await second1.stop()
        await second2.stop()
        await third.stop()
    }

    @Test func failedAudioUploadClosesTheTwoWaySession() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        // Same camera, but a talkback sink whose raw upload connects to a closed port.
        let sink = HikvisionTalkbackSink(endpoint: camera.endpoint, credentials: credentials, transport: RefusingTransport())
        await #expect(throws: (any Error).self) { try await sink.open() }
        #expect(await eventually { camera.talkCalls.value == ["close", "open", "close"] })
    }

    /// Review finding (W4 round 3): an NVR camera (stream `…/channels/301`, camera number 3) on a device that lists only
    /// TwoWayAudio channel 1 was offered two-way audio for channel 1, but its sink opened channel 3, which the device
    /// does not have: every talk attempt failed (404) and was retried. The sink opens the channel the probe offered and
    /// reads the codec from it.
    @Test func nvrCameraTalksOnTheChannelItsProbeOffered() async throws {
        let camera = try await MockHikvisionCamera.start()   // lists only TwoWayAudio channel 1
        defer { camera.stop() }
        let nvr = driver(camera, mainStreamURL: URL(string: "rtsp://127.0.0.1:554/Streaming/Channels/301"))
        #expect(nvr.cameraNumber == 3)
        #expect(try await nvr.probe().capabilities.twoWayAudio)
        camera.twoWayCompression.set("G.711alaw")
        let sink = try #require(nvr.makeTalkbackSink())
        try await sink.open()
        #expect(sink.inputFormat == AudioFormat(codec: .pcma, sampleRate: 8000, channels: 1), "the codec of the channel that is opened")
        try await sink.send(EncodedAudioFrame(format: sink.inputFormat, data: Data(repeating: 7, count: 160),
                                              pts: MediaTime(value: 0, timescale: 8000), sampleCount: 160, wallClock: Date()))
        #expect(await eventually { camera.audioBytes.value.count == 160 })
        await sink.close()
        #expect(await eventually { camera.talkCalls.value == ["close", "open", "audioData", "close"] })
        let base = "/ISAPI/System/TwoWayAudio/channels/"
        #expect(!camera.server.requests(path: base + "1/open").isEmpty)
        #expect(camera.server.requests(path: base + "3/open").isEmpty && camera.server.requests(path: base + "3/close").isEmpty)

        // A device that lists the camera's own channel talks on that one.
        camera.twoWayChannelIDs.set(["1", "3"])
        camera.twoWayCompression.set("G.711ulaw")
        try await sink.open()
        #expect(sink.inputFormat.codec == .pcmu)
        await sink.close()
        #expect(!camera.server.requests(path: base + "3/open").isEmpty)
        #expect(await eventually { !camera.server.requests(path: base + "3/close").isEmpty })
    }

    /// Review finding (W4 round 4): an NVR's cameras share TwoWayAudio channel 1, but every camera has its own
    /// `TalkbackBridge` and sink: camera B's open closed channel 1 under camera A's live talk session (it closes the
    /// channel first, as a stale session blocks the open), and A's close ended B's. The cameras share one two-way
    /// session: B joins A's, only the last one closes it, and while one camera talks the other's audio is dropped.
    @Test func nvrCamerasOnChannelOneShareOneTwoWaySession() async throws {
        let camera = try await MockHikvisionCamera.start()   // lists only TwoWayAudio channel 1
        defer { camera.stop() }
        let nvr = "rtsp://127.0.0.1:554/Streaming/Channels/"
        let a = try #require(driver(camera, mainStreamURL: URL(string: nvr + "201")).makeTalkbackSink())
        let b = try #require(driver(camera, mainStreamURL: URL(string: nvr + "301")).makeTalkbackSink())
        try await a.open()
        try await a.send(audioFrame(1))
        #expect(await eventually { camera.audioBytes.value.count == 160 })
        try await b.open()
        #expect(camera.talkCalls.value == ["close", "open", "audioData"], "B joins A's session: no close, no second open")
        try await b.send(audioFrame(2))   // A is talking: B's audio is dropped
        try await a.send(audioFrame(3))
        #expect(await eventually { camera.audioBytes.value.count == 320 })
        try await Task.sleep(for: .milliseconds(1200))   // A stays quiet longer than the handover
        try await b.send(audioFrame(4))
        #expect(await eventually { camera.audioBytes.value.count == 480 })
        await a.close()   // A's live view ends while B talks
        try await b.send(audioFrame(5))
        #expect(await eventually { camera.audioBytes.value.count == 640 })
        #expect(camera.talkCalls.value == ["close", "open", "audioData"], "A's close leaves B's session open")
        await b.close()
        #expect(await eventually { camera.talkCalls.value == ["close", "open", "audioData", "close"] }, "the last one closes it")
        let expected = [UInt8(1), 3, 4, 5].reduce(into: Data()) { $0.append(Data(repeating: $1, count: 160)) }
        #expect(camera.audioBytes.value == expected)
        // The next talker opens it again.
        try await b.open()
        #expect(camera.talkCalls.value == ["close", "open", "audioData", "close", "close", "open", "audioData"])
        await b.close()
        #expect(await eventually { camera.talkCalls.value.count == 8 })
        let key = HikvisionTwoWaySession.Key(host: "127.0.0.1", port: Int(camera.server.port), useHTTPS: false, channel: "1")
        #expect(await eventually { !HikvisionTwoWaySession.isRegistered(key) }, "a session nobody holds leaves the registry")
    }

    /// Cameras that start talking at the same time open the shared channel once.
    @Test func concurrentOpensOfASharedChannelOpenItOnce() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let nvr = "rtsp://127.0.0.1:554/Streaming/Channels/"
        var sinks: [any TalkbackSink] = []
        for number in [201, 301, 401] {
            sinks.append(try #require(driver(camera, mainStreamURL: URL(string: nvr + "\(number)")).makeTalkbackSink()))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for sink in sinks { group.addTask { try await sink.open() } }
            try await group.waitForAll()
        }
        #expect(camera.talkCalls.value == ["close", "open", "audioData"])
        for sink in sinks { await sink.close() }
        #expect(await eventually { camera.talkCalls.value == ["close", "open", "audioData", "close"] })
    }

    @Test func talkbackStreamsG711OverAudioData() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let sink = try #require(driver(camera).makeTalkbackSink())
        #expect(sink.inputFormat == AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))
        try await sink.open()
        let format = sink.inputFormat
        for n in 0..<3 {
            let frame = EncodedAudioFrame(format: format, data: Data(repeating: UInt8(n), count: 160), pts: MediaTime(value: Int64(n * 160), timescale: 8000),
                                          sampleCount: 160, wallClock: Date())
            try await sink.send(frame)
        }
        #expect(await eventually { camera.audioBytes.value.count == 480 })
        await sink.close()
        #expect(camera.audioBytes.value.prefix(160) == Data(repeating: 0, count: 160))
        #expect(await eventually { camera.talkCalls.value.last == "close" })
        #expect(camera.talkCalls.value.contains("open"))
        #expect(camera.server.requests(path: "/ISAPI/System/TwoWayAudio/channels/1/audioData").count == 2)   // challenge, then authenticated
        await #expect(throws: (any Error).self) {
            try await sink.send(EncodedAudioFrame(format: format, data: Data(count: 160), pts: MediaTime(value: 0, timescale: 8000),
                                                  sampleCount: 160, wallClock: Date()))
        }
    }

    /// Review finding (W4 BridgeSupport, round 4): the raw audio upload answered any Basic challenge, so a host
    /// impersonating a Digest camera got the password with one 401. Once the camera asked for Digest, the sink never
    /// answers Basic.
    @Test func talkbackUploadNeverAnswersBasicAfterDigest() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let sink = try #require(driver(camera).makeTalkbackSink())
        try await sink.open()
        await sink.close()

        camera.impersonatedAudioData.set(true)
        await #expect(throws: CameraAdapterError.unauthorized) { try await sink.open() }
        await sink.close()
        let uploads = camera.server.requests(path: "/ISAPI/System/TwoWayAudio/channels/1/audioData")
        #expect(uploads.count == 3)   // challenge and Digest; then the Basic challenge, not answered
        #expect(!uploads.contains { $0.head.headers["Authorization"]?.lowercased().hasPrefix("basic") == true })
    }
}
#endif
