import Foundation
import Testing
@testable import RTSP

@Suite struct RTSPMessageParserTests {
    private func drain(_ parser: inout RTSPMessageParser) throws -> [RTSPIncomingMessage] {
        var out: [RTSPIncomingMessage] = []
        while let message = try parser.next() { out.append(message) }
        return out
    }

    @Test func responseWithBodySplitAcrossChunks() throws {
        let wire = Data("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Type: application/sdp\r\nContent-Length: 10\r\n\r\n0123456789".utf8)
        var parser = RTSPMessageParser()
        var messages: [RTSPIncomingMessage] = []
        for byte in wire {
            parser.append(Data([byte]))
            messages += try drain(&parser)
        }
        #expect(messages.count == 1)
        guard case .response(let response) = messages.first else { Issue.record("expected a response"); return }
        #expect(response.status == 200)
        #expect(response.reason == "OK")
        #expect(response.cseq == 2)
        #expect(response.headers["content-type"] == "application/sdp")
        #expect(response.body == Data("0123456789".utf8))
    }

    @Test func interleavedFramesMixedWithResponses() throws {
        var wire = Data([0x24, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])
        wire.append(Data("RTSP/1.0 200 OK\r\nCSeq: 7\r\nSession: abc;timeout=30\r\n\r\n".utf8))
        wire.append(Data([0x24, 0x01, 0x00, 0x02, 0x01, 0x02, 0x24, 0x02, 0x00, 0x00]))
        var parser = RTSPMessageParser()
        parser.append(wire)
        let messages = try drain(&parser)
        #expect(messages.count == 4)
        guard case .interleaved(let c0, let p0) = messages[0], case .response(let r) = messages[1],
              case .interleaved(let c1, let p1) = messages[2], case .interleaved(let c2, let p2) = messages[3] else {
            Issue.record("unexpected message order: \(messages)")
            return
        }
        #expect(c0 == 0 && p0 == Data([0xAA, 0xBB, 0xCC]))
        #expect(r.cseq == 7 && r.headers["Session"] == "abc;timeout=30")
        #expect(c1 == 1 && p1 == Data([0x01, 0x02]))
        #expect(c2 == 2 && p2.isEmpty)
    }

    @Test func partialInterleavedFrameWaitsForMoreData() throws {
        var parser = RTSPMessageParser()
        parser.append(Data([0x24, 0x04, 0x00, 0x04, 0x01]))
        #expect(try parser.next() == nil)
        parser.append(Data([0x02, 0x03, 0x04]))
        guard case .interleaved(let channel, let payload)? = try parser.next() else { Issue.record("expected a frame"); return }
        #expect(channel == 4)
        #expect(payload == Data([1, 2, 3, 4]))
    }

    @Test func serverRequestsAreParsed() throws {
        var parser = RTSPMessageParser()
        parser.append(Data("GET_PARAMETER rtsp://127.0.0.1/stream RTSP/1.0\r\nCSeq: 9\r\n\r\n".utf8))
        guard case .request(let request)? = try parser.next() else { Issue.record("expected a request"); return }
        #expect(request.method == "GET_PARAMETER")
        #expect(request.uri == "rtsp://127.0.0.1/stream")
        #expect(request.headers["CSeq"] == "9")
    }

    @Test func bareLineFeedsAreAccepted() throws {
        var parser = RTSPMessageParser()
        parser.append(Data("RTSP/1.0 401 Unauthorized\nCSeq: 3\nWWW-Authenticate: Basic realm=\"x\"\n\n".utf8))
        guard case .response(let response)? = try parser.next() else { Issue.record("expected a response"); return }
        #expect(response.status == 401)
        #expect(response.headers["www-authenticate"] == "Basic realm=\"x\"")
    }

    @Test func junkBetweenMessagesIsSkipped() throws {
        var parser = RTSPMessageParser()
        var wire = Data([0x00, 0x00, 0xFF])
        wire.append(Data("garbage line\r\n".utf8))
        wire.append(Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8))
        parser.append(wire)
        let messages = try drain(&parser)
        #expect(messages.count == 1)
        guard case .response(let response) = messages.first else { Issue.record("expected a response"); return }
        #expect(response.cseq == 1)
    }

    /// RTP-looking payloads that contain LF bytes (which a text scan would take for line ends).
    private func interleavedFrames(_ count: Int) -> Data {
        var data = Data()
        for i in 0..<count {
            var payload = Data([0x80, 0x60, 0x00, UInt8(i)])
            payload.append(Data(repeating: 0x0A, count: 3))
            payload.append(Data(repeating: 0x41, count: 20))
            data.append(RTSPRequestSerializer.interleaved(channel: 0, payload: payload))
        }
        return data
    }

    @Test func letterJunkWithoutNewlineBeforeInterleavedFrames() throws {
        var parser = RTSPMessageParser()
        var wire = Data("x".utf8)
        wire.append(interleavedFrames(20))
        parser.append(wire)
        let messages = try drain(&parser)
        #expect(messages.count == 20)
        #expect(messages.allSatisfy { if case .interleaved(0, _) = $0 { true } else { false } })
        #expect(parser.bufferedByteCount == 0)
    }

    @Test func letterJunkArrivingAloneIsResolvedByTheNextChunk() throws {
        var parser = RTSPMessageParser()
        parser.append(Data("junk".utf8))
        #expect(try parser.next() == nil)
        parser.append(interleavedFrames(3))
        #expect(try drain(&parser).count == 3)
    }

    @Test func junkGluedToAResponseIsSkipped() throws {
        var parser = RTSPMessageParser()
        var wire = Data("xyRTSP/1.0 200 OK\r\nCSeq: 4\r\n\r\n".utf8)
        wire.append(interleavedFrames(2))
        parser.append(wire)
        let messages = try drain(&parser)
        #expect(messages.count == 3)
        guard case .response(let response)? = messages.first else { Issue.record("expected a response, got \(messages)"); return }
        #expect(response.cseq == 4)
    }

    @Test func binaryInsideAHeaderBlockDropsTheBrokenMessage() throws {
        // A start line, then binary instead of headers: the frames after it must survive.
        var parser = RTSPMessageParser()
        var wire = Data("RTSP/1.0 200 OK\r\n".utf8)
        wire.append(interleavedFrames(5))
        parser.append(wire)
        let messages = try drain(&parser)
        #expect(messages.filter { if case .interleaved = $0 { true } else { false } }.count == 5)
        #expect(parser.bufferedByteCount == 0)
    }

    @Test func partialStartLinesWaitForMoreData() throws {
        var parser = RTSPMessageParser()
        let wire = Data("GET_PARAMETER rtsp://h/s RTSP/1.0\r\nCSeq: 2\r\n\r\n".utf8)
        for cut in 1..<wire.count {
            parser = RTSPMessageParser()
            parser.append(wire.prefix(cut))
            #expect(try parser.next() == nil)
            parser.append(wire.dropFirst(cut))
            guard case .request(let request)? = try parser.next() else { Issue.record("cut \(cut)"); continue }
            #expect(request.method == "GET_PARAMETER")
        }
    }

    @Test func oversizeHeaderThrows() {
        var parser = RTSPMessageParser(maxHeaderSize: 128)
        parser.append(Data(("RTSP/1.0 200 OK\r\nX: " + String(repeating: "a", count: 200)).utf8))
        #expect(throws: RTSPError.self) { _ = try parser.next() }
    }

    @Test func oversizeBodyThrows() {
        var parser = RTSPMessageParser(maxBodySize: 16)
        parser.append(Data("RTSP/1.0 200 OK\r\nContent-Length: 17\r\n\r\n".utf8))
        #expect(throws: RTSPError.self) { _ = try parser.next() }
    }

    @Test func sessionAndTransportHeaders() {
        let session = RTSPHeaderValues.session("47112344;timeout=20")
        #expect(session?.id == "47112344")
        #expect(session?.timeout == .seconds(20))
        #expect(RTSPHeaderValues.session("ABC")?.timeout == nil)
        // Absurd timeouts are clamped (a day at most) instead of overflowing later arithmetic.
        #expect(RTSPHeaderValues.session("S;timeout=9223372036854775807")?.timeout == .seconds(86_400))
        let transport = RTSPHeaderValues.transportParameters("RTP/AVP/TCP;unicast;interleaved=4-5;ssrc=1A2B3C4D;mode=\"PLAY\"")
        #expect(transport["interleaved"] == "4-5")
        #expect(transport["ssrc"] == "1A2B3C4D")
        #expect(transport["unicast"] == "")
        #expect(RTSPHeaderValues.interleavedChannels("RTP/AVP/TCP;unicast;interleaved=4-5")?.rtp == 4)
        #expect(RTSPHeaderValues.interleavedChannels("RTP/AVP/TCP;unicast;interleaved=4-5")?.rtcp == 5)
        #expect(RTSPHeaderValues.interleavedChannels("RTP/AVP/TCP;unicast;interleaved=6")?.rtcp == 7)
        #expect(RTSPHeaderValues.interleavedChannels("RTP/AVP;unicast;client_port=5000-5001") == nil)
    }

    @Test func requestSerialization() {
        let data = RTSPRequestSerializer.serialize(method: "DESCRIBE", uri: "rtsp://h/s", headers: [("CSeq", "2"), ("Accept", "application/sdp")])
        #expect(String(decoding: data, as: UTF8.self) == "DESCRIBE rtsp://h/s RTSP/1.0\r\nCSeq: 2\r\nAccept: application/sdp\r\n\r\n")
        let interleaved = RTSPRequestSerializer.interleaved(channel: 3, payload: Data([9, 8]))
        #expect(interleaved == Data([0x24, 3, 0, 2, 9, 8]))
    }
}

extension RTSPIncomingMessage: CustomStringConvertible {
    public var description: String {
        switch self {
        case .response(let r): "response(\(r.status))"
        case .request(let r): "request(\(r.method))"
        case .interleaved(let c, let p): "interleaved(\(c), \(p.count))"
        }
    }
}
