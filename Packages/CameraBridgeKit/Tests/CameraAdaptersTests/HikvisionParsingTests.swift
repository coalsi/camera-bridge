import BridgeSupport
import Foundation
import MediaCore
import Testing
@testable import CameraAdapters

/// Builds one multipart part as Hikvision sends it.
func hikPart(boundary: String, contentType: String, body: Data, contentLength: Bool = true) -> Data {
    var head = "--\(boundary)\r\nContent-Type: \(contentType)\r\n"
    if contentLength { head += "Content-Length: \(body.count)\r\n" }
    head += "\r\n"
    var data = Data(head.utf8)
    data.append(body)
    data.append(Data("\r\n".utf8))
    return data
}

@Suite struct MultipartParserTests {
    @Test func boundaryFromContentTypeHeader() {
        #expect(MultipartStreamParser.boundary(fromContentType: "multipart/mixed; boundary=MIME_boundary") == "MIME_boundary")
        #expect(MultipartStreamParser.boundary(fromContentType: #"multipart/mixed;boundary="quoted b""#) == "quoted b")
        #expect(MultipartStreamParser.boundary(fromContentType: "multipart/mixed") == "boundary")
        #expect(MultipartStreamParser.boundary(fromContentType: nil) == "boundary")
    }

    @Test func parsesPartsSplitAtEveryByte() throws {
        let xml = try fixture("hikvision/alert-vmd.xml")
        var stream = hikPart(boundary: "MIME_boundary", contentType: "application/xml; charset=\"UTF-8\"", body: xml)
        stream.append(hikPart(boundary: "MIME_boundary", contentType: "image/jpeg", body: Data([0xFF, 0xD8, 0x0D, 0x0A, 0x2D, 0x2D, 0xFF, 0xD9])))
        stream.append(hikPart(boundary: "MIME_boundary", contentType: "application/xml", body: xml))
        var parser = MultipartStreamParser(contentType: "multipart/mixed; boundary=MIME_boundary")
        var parts: [MultipartPart] = []
        for byte in stream { parts += try parser.feed(Data([byte])) }
        #expect(parts.count == 3)
        #expect(parts[0].body == xml)
        #expect(parts[0].isXML)
        #expect(parts[1].contentType == "image/jpeg")
        #expect(!parts[1].isXML)
        #expect(parts[1].body.count == 8)   // CRLF-- inside the JPEG does not end it: Content-Length rules
        #expect(parts[2].body == xml)
    }

    @Test func acceptsLiteralBoundaryFromOlderNVRs() throws {
        let xml = try fixture("hikvision/alert-vmd.xml")
        var parser = MultipartStreamParser(contentType: "multipart/mixed; boundary=something-else")
        let parts = try parser.feed(hikPart(boundary: "boundary", contentType: "application/xml", body: xml))
        #expect(parts.map(\.body) == [xml])
    }

    @Test func partWithoutContentLengthEndsAtNextBoundary() throws {
        let xml = try fixture("hikvision/alert-vmd.xml")
        var stream = hikPart(boundary: "boundary", contentType: "application/xml", body: xml, contentLength: false)
        stream.append(Data("--boundary\r\n".utf8))
        var parser = MultipartStreamParser(contentType: "multipart/mixed; boundary=boundary")
        let parts = try parser.feed(stream)
        #expect(parts.count == 1)
        #expect(String(decoding: parts[0].body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == String(decoding: xml, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func unsizedStream(_ body: String, then tail: String = "\r\n--boundary\r\n") -> Data {
        Data("--boundary\r\nContent-Type: text/plain\r\n\r\n\(body)\(tail)".utf8)
    }

    @Test func unsizedPartIgnoresLinesThatOnlyStartLikeTheBoundary() throws {
        // A delimiter line is "--boundary" (or "--boundary--") plus optional blanks, nothing else.
        let body = "line1\r\n--boundaryX is not a boundary\r\n--boundary-y neither\n--boundary\tpadded, then text\r\nline5"
        var whole = MultipartStreamParser(contentType: "multipart/mixed; boundary=boundary")
        let parts = try whole.feed(unsizedStream(body))
        #expect(parts.map { String(decoding: $0.body, as: UTF8.self) } == [body])
        var bytewise = MultipartStreamParser(contentType: "multipart/mixed; boundary=boundary")
        var split: [MultipartPart] = []
        for byte in unsizedStream(body) { split += try bytewise.feed(Data([byte])) }
        #expect(split.map(\.body) == parts.map(\.body))
    }

    @Test func unsizedPartEndsAtClosingAndPaddedDelimiters() throws {
        for tail in ["\r\n--boundary--\r\n", "\r\n--boundary  \r\n", "\n--boundary\n"] {
            var parser = MultipartStreamParser(contentType: "multipart/mixed; boundary=boundary")
            let parts = try parser.feed(unsizedStream("<a>x</a>", then: tail))
            #expect(parts.map { String(decoding: $0.body, as: UTF8.self) } == ["<a>x</a>"], "\(tail.debugDescription)")
        }
    }

    @Test func unsizedPartWaitsUntilTheDelimiterLineIsComplete() throws {
        var parser = MultipartStreamParser(contentType: "multipart/mixed; boundary=boundary")
        #expect(try parser.feed(unsizedStream("<a>1</a>", then: "\r\n--boundary")).isEmpty)
        #expect(try parser.feed(Data("-".utf8)).isEmpty)          // "--boundary-" could still be "--boundary--"
        let parts = try parser.feed(Data("-\r\n".utf8))
        #expect(parts.map { String(decoding: $0.body, as: UTF8.self) } == ["<a>1</a>"])
    }

    @Test func unsizedEmptyPartEndsAtADelimiterRightAfterTheHeaders() throws {
        let stream = "--boundary\r\nContent-Type: text/plain\r\n\r\n--boundary\r\nContent-Type: application/xml\r\n\r\n<a/>\r\n--boundary\r\n"
        for split in [false, true] {
            var parser = MultipartStreamParser(contentType: "multipart/mixed; boundary=boundary")
            var parts: [MultipartPart] = []
            if split { for byte in Data(stream.utf8) { parts += try parser.feed(Data([byte])) } } else { parts = try parser.feed(Data(stream.utf8)) }
            #expect(parts.map { String(decoding: $0.body, as: UTF8.self) } == ["", "<a/>"], "split: \(split)")
        }
    }

    /// Random streams built from boundary-like fragments parse the same whole and in random chunks (and never trap).
    @Test func chunkingNeverChangesTheParts() {
        struct SplitMix: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
        var random = SplitMix(state: 42)
        var compared = 0
        let bodyFragments = ["<a/>", "x", "\r\n", "\n", "\r", "-", " ", "\t", "--boundaryX", "--MIME-", "\r\n--MIMEy", "\n--boundary-",
                             "\r\n--MIME ", "\r\n--boundary", "--MIME--", ":", "\u{FF}\u{D8}"]
        func pick(_ items: [String]) -> String { items.randomElement(using: &random) ?? "" }
        for _ in 0..<1500 {
            var text = ""
            for _ in 0..<Int.random(in: 1...5, using: &random) {
                if Bool.random(using: &random) { text += pick(["noise\r\n", "\r\n", "", "-", "--MIMEx\r\n"]) }
                var body = ""
                for _ in 0..<Int.random(in: 0...6, using: &random) { body += pick(bodyFragments) }
                text += "--" + pick(["MIME", "boundary"]) + pick(["", " ", "\t"]) + pick(["\r\n", "\n"])
                if Bool.random(using: &random) { text += "Content-Type: application/xml\r\n" }
                switch Int.random(in: 0...3, using: &random) {
                case 0: text += "Content-Length: \(body.utf8.count)\r\n"
                case 1: text += "Content-Length: \(Int.random(in: 0...12, using: &random))\r\n"
                default: break
                }
                text += pick(["\r\n", "\n"]) + body + pick(["\r\n", "\n", ""])
            }
            if Bool.random(using: &random) { text += pick(["--MIME--\r\n", "--MIME\r\n", "--boundary\r\n"]) }
            let stream = Data(text.utf8)
            var whole = MultipartStreamParser(contentType: "multipart/mixed; boundary=MIME")
            let expected = try? whole.feed(stream)
            var chunked = MultipartStreamParser(contentType: "multipart/mixed; boundary=MIME")
            var parts: [MultipartPart] = []
            var offset = 0
            var failed = false
            while offset < stream.count {
                let size = Int.random(in: 1...8, using: &random)
                let end = min(stream.count, offset + size)
                do { parts += try chunked.feed(stream.subdata(in: offset..<end)) } catch { failed = true; break }
                offset = end
            }
            if let expected, !failed {
                if !expected.isEmpty { compared += 1 }
                #expect(parts.map(\.body) == expected.map(\.body), "\(String(decoding: stream, as: UTF8.self).debugDescription)")
            }
        }
        #expect(compared >= 100, "the generator must produce streams with parts")
    }

    @Test func largeUnsizedPartIsScannedIncrementally() throws {
        var parser = MultipartStreamParser(contentType: "multipart/mixed; boundary=boundary")
        _ = try parser.feed(Data("--boundary\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        let chunk = Data(repeating: 0x41, count: 1024)
        let started = ContinuousClock.now
        for _ in 0..<(4 * 1024) { #expect(try parser.feed(chunk).isEmpty) }
        let parts = try parser.feed(Data("\r\n--boundary\r\n".utf8))
        #expect(ContinuousClock.now - started < .seconds(3), "each chunk must not rescan the whole buffer")
        #expect(parts.first?.body.count == 4 << 20)
    }

    @Test func skipsGarbageAndClosingBoundary() throws {
        let xml = try fixture("hikvision/alert-vmd.xml")
        var stream = Data("\r\n\r\nnoise before\r\n".utf8)
        stream.append(hikPart(boundary: "boundary", contentType: "application/xml", body: xml))
        stream.append(Data("--boundary--\r\n".utf8))
        var parser = MultipartStreamParser(contentType: nil)
        #expect(try parser.feed(stream).count == 1)
    }

    @Test func rejectsOversizedParts() {
        var parser = MultipartStreamParser(contentType: nil)
        let head = Data("--boundary\r\nContent-Type: image/jpeg\r\nContent-Length: 999999999\r\n\r\n".utf8)
        #expect(throws: (any Error).self) { try parser.feed(head) }
    }
}

@Suite struct HikvisionAlertTests {
    private let hold: Duration = .seconds(20)

    private func alert(_ name: String) throws -> HikvisionAlert {
        try #require(HikvisionAlert.parse(fixture("hikvision/\(name)")))
    }

    @Test func parsesAlertsInBothNamespaces() throws {
        let vmd = try alert("alert-vmd.xml")
        #expect(vmd.eventType == "VMD" && vmd.eventState == "active" && vmd.channelID == "1")
        let field = try alert("alert-fielddetection-human.xml")
        #expect(field.eventType == "fielddetection" && field.targets == ["human"])
        let line = try alert("alert-linedetection-vehicle.xml")
        #expect(line.channelID == "1" && line.targets == ["vehicle"])
        #expect(HikvisionAlert.parse(Data("<html/>".utf8)) == nil)
        #expect(HikvisionAlert.parse(Data([0xFF, 0xD8])) == nil)
    }

    @Test func vmdPulsesMotionWithTwentySecondHold() throws {
        #expect(HikvisionEventMapper.signals(for: try alert("alert-vmd.xml"), pulseHold: hold) == [.activate(.motion, source: "VMD", hold: hold)])
        var inactive = try alert("alert-vmd.xml")
        inactive.eventState = "inactive"
        #expect(HikvisionEventMapper.signals(for: inactive, pulseHold: hold).isEmpty)   // the hold ends it
    }

    @Test func smartEventsMapTargetsAndPulseMotion() throws {
        #expect(HikvisionEventMapper.signals(for: try alert("alert-fielddetection-human.xml"), pulseHold: hold)
                == [.activate(.object(.person), source: "fielddetection", hold: hold), .activate(.motion, source: "smart", hold: hold)])
        #expect(HikvisionEventMapper.signals(for: try alert("alert-linedetection-vehicle.xml"), pulseHold: hold)
                == [.activate(.object(.vehicle), source: "linedetection", hold: hold), .activate(.motion, source: "smart", hold: hold)])
        for type in ["regionEntrance", "regionExiting"] {
            let a = HikvisionAlert(eventType: type, eventState: "active", channelID: "1", targets: ["human", "vehicle"], inputPort: nil)
            #expect(HikvisionEventMapper.signals(for: a, pulseHold: hold)
                    == [.activate(.object(.person), source: type, hold: hold), .activate(.object(.vehicle), source: type, hold: hold),
                        .activate(.motion, source: "smart", hold: hold)])
        }
        let noTarget = HikvisionAlert(eventType: "fielddetection", eventState: "active", channelID: "1", targets: [], inputPort: nil)
        #expect(HikvisionEventMapper.signals(for: noTarget, pulseHold: hold) == [.activate(.motion, source: "smart", hold: hold)])
    }

    @Test func tamperIOAndHeartbeat() throws {
        for type in ["tamperdetection", "shelteralarm", "defocus"] {
            let on = HikvisionAlert(eventType: type, eventState: "active", channelID: "1", targets: [], inputPort: nil)
            #expect(HikvisionEventMapper.signals(for: on, pulseHold: hold) == [.activate(.tamper, source: type, hold: hold)])
            let off = HikvisionAlert(eventType: type, eventState: "inactive", channelID: "1", targets: [], inputPort: nil)
            #expect(HikvisionEventMapper.signals(for: off, pulseHold: hold) == [.deactivate(.tamper, source: type)])
        }
        let io = HikvisionAlert(eventType: "IO", eventState: "active", channelID: nil, targets: [], inputPort: "2")
        #expect(HikvisionEventMapper.signals(for: io, pulseHold: hold) == [.activate(.digitalInput("2"), source: "IO", hold: hold)])
        let heartbeat = try alert("alert-videoloss-heartbeat.xml")
        #expect(heartbeat.isHeartbeat)
        #expect(HikvisionEventMapper.signals(for: heartbeat, pulseHold: hold).isEmpty)
    }

    @Test func nvrChannelFilter() throws {
        let vmd = try alert("alert-vmd.xml")   // channel 1
        #expect(HikvisionEventMapper.signals(for: vmd, pulseHold: hold, channelFilter: "2").isEmpty)
        #expect(!HikvisionEventMapper.signals(for: vmd, pulseHold: hold, channelFilter: "1").isEmpty)
    }

    @Test func parsesISAPIDocuments() throws {
        let info = try HikvisionXML.deviceInfo(XMLTree.parse(fixture("hikvision/deviceInfo.xml")))
        #expect(info.model == "DS-2CD2387G2P-LSU/SL")
        #expect(info.firmware == "V5.7.15 build 230329")
        let channels = HikvisionXML.streamingChannels(try XMLTree.parse(fixture("hikvision/streamingChannels.xml")))
        #expect(channels.map(\.id) == ["101", "102", "103"])
        #expect(channels[0].videoCodec == .h264 && channels[0].width == 4256 && channels[0].height == 1888 && channels[0].fps == 20)
        #expect(channels[0].audioCodec == .pcmu)
        #expect(channels[1].audioCodec == nil && channels[1].fps == 15)
        #expect(channels[2].videoCodec == .hevc)
        let kinds = HikvisionXML.triggerKinds(try XMLTree.parse(fixture("hikvision/triggers.xml")))
        #expect(kinds == [.motion, .person, .vehicle, .tamper, .digitalInput])
        let twoWay = HikvisionXML.twoWayAudioChannels(try XMLTree.parse(fixture("hikvision/twoWayAudioChannels.xml")))
        #expect(twoWay.count == 1 && twoWay[0].id == "1" && twoWay[0].codec == .pcmu && twoWay[0].compression == "G.711ulaw")
    }

    /// Codecs `AudioCodec` cannot represent keep their reported name, so talkback can refuse them by name.
    @Test func twoWayChannelKeepsTheReportedCompression() throws {
        func channel(_ compression: String?) throws -> HikvisionTwoWayChannel? {
            let element = compression.map { "<audioCompressionType>\($0)</audioCompressionType>" } ?? ""
            let xml = "<TwoWayAudioChannelList><TwoWayAudioChannel><id>1</id>\(element)</TwoWayAudioChannel></TwoWayAudioChannelList>"
            return HikvisionXML.twoWayAudioChannels(try XMLTree.parse(Data(xml.utf8))).first
        }
        #expect(try channel("G.726") == HikvisionTwoWayChannel(id: "1", codec: nil, compression: "G.726"))
        #expect(try channel("AAC") == HikvisionTwoWayChannel(id: "1", codec: .aac, compression: "AAC"))
        #expect(try channel("G.711alaw") == HikvisionTwoWayChannel(id: "1", codec: .pcma, compression: "G.711alaw"))
        #expect(try channel(nil) == HikvisionTwoWayChannel(id: "1", codec: nil, compression: nil))
        #expect(throws: CameraAdapterError.unsupported("Hikvision two-way audio is set to G.726; set the camera's two-way audio "
                                                       + "encoding to G.711ulaw (or G.711alaw)")) {
            try HikvisionTalkbackSink.format(for: channel("G.726"))
        }
        #expect(try HikvisionTalkbackSink.format(for: channel(nil)).codec == .pcmu, "not reported: G.711 µ-law, as before")
        #expect(try HikvisionTalkbackSink.format(for: nil).codec == .pcmu)
    }

    @Test func cameraNumberFromStreamURL() {
        #expect(HikvisionDriver.cameraNumber(from: URL(string: "rtsp://192.0.2.1/ISAPI/Streaming/channels/101")) == 1)
        #expect(HikvisionDriver.cameraNumber(from: URL(string: "rtsp://192.0.2.1:554/Streaming/Channels/402?transportmode=unicast")) == 4)
        #expect(HikvisionDriver.cameraNumber(from: URL(string: "rtsp://192.0.2.1/live")) == 1)
        #expect(HikvisionDriver.cameraNumber(from: nil) == 1)
    }

    /// Talkback uploads the audio over a raw TCP connection, which cannot do TLS (`open()` throws `.unsupported` for
    /// HTTPS): an HTTPS camera must neither report two-way audio from its probe nor get a sink (the runtime would
    /// publish a Speaker whose talk button never works and retry `open()` every 5 s).
    @Test func httpsCamerasOfferNoTwoWayAudio() {
        let https = HikvisionDriver(endpoint: CameraEndpoint(host: "192.0.2.10", httpPort: 443, useHTTPS: true),
                                    credentials: HTTPCredentials(username: "admin", password: "pa55"), mainStreamURL: nil, subStreamURL: nil,
                                    transport: UnusedTransport())
        #expect(https.makeTalkbackSink() == nil)
        let http = HikvisionDriver(endpoint: CameraEndpoint(host: "192.0.2.10"), credentials: nil, mainStreamURL: nil, subStreamURL: nil,
                                   transport: UnusedTransport())
        #expect(http.makeTalkbackSink() != nil)

        let channels = [HikvisionTwoWayChannel(id: "1", codec: .pcmu, compression: "G.711ulaw")]
        #expect(!HikvisionDriver.offersTwoWayAudio(channels: channels, cameraNumber: 1, useHTTPS: true))
        #expect(HikvisionDriver.offersTwoWayAudio(channels: channels, cameraNumber: 1, useHTTPS: false))
        #expect(HikvisionDriver.offersTwoWayAudio(channels: channels, cameraNumber: 3, useHTTPS: false), "channel 1 serves an NVR's cameras")
        #expect(!HikvisionDriver.offersTwoWayAudio(channels: [], cameraNumber: 1, useHTTPS: false))
        #expect(!HikvisionDriver.offersTwoWayAudio(channels: nil, cameraNumber: 1, useHTTPS: false))
    }

    /// Review finding (W4 round 3): the probe and the sink chose the TwoWayAudio channel differently. Both now use one
    /// rule: the camera's own channel when the device lists it, else channel 1, else none (no two-way audio).
    @Test func probeAndSinkChooseTheSameTwoWayChannel() {
        let one = HikvisionTwoWayChannel(id: "1", codec: .pcmu, compression: "G.711ulaw")
        let three = HikvisionTwoWayChannel(id: "3", codec: .pcma, compression: "G.711alaw")
        #expect(HikvisionTalkbackSink.channel(forCamera: "3", in: [one]) == one, "an NVR's shared channel 1")
        #expect(HikvisionTalkbackSink.channel(forCamera: "3", in: [one, three]) == three, "the camera's own channel first")
        #expect(HikvisionTalkbackSink.channel(forCamera: "1", in: [one, three]) == one)
        #expect(HikvisionTalkbackSink.channel(forCamera: "2", in: [three]) == nil)
        #expect(HikvisionTalkbackSink.channel(forCamera: "2", in: []) == nil)
        for (channels, number) in [([one], 3), ([one, three], 3), ([three], 2), ([three], 3), ([], 1)] {
            #expect(HikvisionDriver.offersTwoWayAudio(channels: channels, cameraNumber: number, useHTTPS: false)
                    == (HikvisionTalkbackSink.channel(forCamera: "\(number)", in: channels) != nil))
        }
    }
}
