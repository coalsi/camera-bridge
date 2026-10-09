import BridgeSupport
import Foundation
import MediaCore
import RTP

/// The test server's own minimal RTP packetizers (independent of the client's depacketizers and of RTP's
/// `H264Packetizer`): RFC 6184 (single NAL, STAP-A, FU-A), RFC 7798 (single NAL, AP, FU), G.711, RFC 3640 AAC-hbr.
struct TestServerPacketizer {
    let maxPayload: Int
    let parameterSetMode: RTSPTestServer.ParameterSetMode
    var sequence: UInt16
    let ssrc: UInt32
    let payloadType: UInt8
    /// FU fragments sent so far (for the drop-every-Nth fault).
    var fragmentCounter = 0
    var droppedFragments = 0

    init(maxPacketSize: Int, parameterSetMode: RTSPTestServer.ParameterSetMode, payloadType: UInt8) {
        maxPayload = max(64, maxPacketSize - 12)
        self.parameterSetMode = parameterSetMode
        self.payloadType = payloadType
        sequence = UInt16.random(in: 0...UInt16.max)
        ssrc = UInt32.random(in: 1...UInt32.max)
    }

    /// Packets for one video access unit. Parameter sets precede every keyframe. `dropEveryNthFragment` skips a
    /// fragment (its sequence number is still consumed, as on a lossy path).
    mutating func packetize(_ frame: EncodedVideoFrame, timestamp: UInt32, dropEveryNthFragment: Int?) -> [RTPPacket] {
        var payloads: [(Data, isFragment: Bool)] = []
        if frame.isKeyframe {
            let sets = frame.format.parameterSets
            switch (parameterSetMode, frame.format.codec) {
            case (.aggregated, .h264): payloads.append((Self.stapA(sets), false))
            case (.aggregated, .hevc): payloads.append((Self.hevcAP(sets), false))
            case (.separate, _): payloads += sets.map { ($0, false) }
            }
        }
        for nal in frame.nalUnits {
            if nal.count <= maxPayload {
                payloads.append((nal, false))
            } else {
                let fragments = frame.format.codec == .h264 ? Self.fuA(nal, chunk: maxPayload - 2) : Self.hevcFU(nal, chunk: maxPayload - 3)
                payloads += fragments.map { ($0, true) }
            }
        }
        var packets: [RTPPacket] = []
        for (index, (payload, isFragment)) in payloads.enumerated() {
            defer { sequence &+= 1 }
            if isFragment {
                fragmentCounter += 1
                if let n = dropEveryNthFragment, n > 0, fragmentCounter % n == 0 {
                    droppedFragments += 1
                    continue
                }
            }
            packets.append(RTPPacket(marker: index == payloads.count - 1, payloadType: payloadType, sequenceNumber: sequence,
                                     timestamp: timestamp, ssrc: ssrc, payload: payload))
        }
        return packets
    }

    mutating func audioPacket(payload: Data, timestamp: UInt32) -> RTPPacket {
        defer { sequence &+= 1 }
        return RTPPacket(marker: true, payloadType: payloadType, sequenceNumber: sequence, timestamp: timestamp, ssrc: ssrc, payload: payload)
    }

    static func stapA(_ nals: [Data]) -> Data {
        let nri = nals.map { ($0.first ?? 0) & 0x60 }.max() ?? 0
        var payload = Data([nri | 24])
        for nal in nals {
            payload.append(UInt8(nal.count >> 8))
            payload.append(UInt8(nal.count & 0xFF))
            payload.append(nal)
        }
        return payload
    }

    static func hevcAP(_ nals: [Data]) -> Data {
        var payload = Data([48 << 1, 0x01])
        for nal in nals {
            payload.append(UInt8(nal.count >> 8))
            payload.append(UInt8(nal.count & 0xFF))
            payload.append(nal)
        }
        return payload
    }

    static func fuA(_ nal: Data, chunk: Int) -> [Data] {
        let bytes = [UInt8](nal)
        guard let header = bytes.first else { return [] }
        var fragments: [Data] = []
        var offset = 1
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            var fu = header & 0x1F
            if offset == 1 { fu |= 0x80 }
            if end == bytes.count { fu |= 0x40 }
            var payload = Data([(header & 0xE0) | 28, fu])
            payload.append(contentsOf: bytes[offset..<end])
            fragments.append(payload)
            offset = end
        }
        return fragments
    }

    static func hevcFU(_ nal: Data, chunk: Int) -> [Data] {
        let bytes = [UInt8](nal)
        guard bytes.count > 2 else { return [] }
        let type = (bytes[0] >> 1) & 0x3F
        var fragments: [Data] = []
        var offset = 2
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            var fu = type
            if offset == 2 { fu |= 0x80 }
            if end == bytes.count { fu |= 0x40 }
            var payload = Data([(bytes[0] & 0x81) | (49 << 1), bytes[1], fu])
            payload.append(contentsOf: bytes[offset..<end])
            fragments.append(payload)
            offset = end
        }
        return fragments
    }

    /// RFC 3640 AAC-hbr payload with one 16-bit AU header (13-bit size, 3-bit index/delta 0) per unit.
    static func aacHBR(_ units: [Data]) -> Data {
        var payload = Data()
        let bits = units.count * 16
        payload.append(UInt8(bits >> 8))
        payload.append(UInt8(bits & 0xFF))
        for unit in units {
            let header = UInt16(truncatingIfNeeded: unit.count << 3)
            payload.append(UInt8(header >> 8))
            payload.append(UInt8(header & 0xFF))
        }
        units.forEach { payload.append($0) }
        return payload
    }

    /// RTCP sender report (RFC 3550 §6.4.1) without report blocks.
    static func senderReport(ssrc: UInt32, ntp: UInt64, rtpTimestamp: UInt32, packets: UInt32, octets: UInt32) -> Data {
        var writer = ByteWriter()
        writer.write(0x80)
        writer.write(200)
        writer.writeUInt16BE(6)
        writer.writeUInt32BE(ssrc)
        writer.writeUInt64BE(ntp)
        writer.writeUInt32BE(rtpTimestamp)
        writer.writeUInt32BE(packets)
        writer.writeUInt32BE(octets)
        return writer.data
    }
}

/// SDP text for the test server.
enum TestServerSDP {
    static func make(video: VideoFormat, audio: AudioFormat?, backchannel: AudioFormat?, parameterSetsInSDP: Bool,
                     controlBase: String?) -> String {
        func control(_ track: Int) -> String {
            controlBase.map { "\($0)trackID=\(track)" } ?? "trackID=\(track)"
        }
        var lines = ["v=0", "o=- \(UInt32.random(in: 1...UInt32.max)) 1 IN IP4 127.0.0.1", "s=CameraBridge RTSPTestServer", "c=IN IP4 0.0.0.0",
                     "t=0 0", "a=control:*", "a=range:npt=now-"]
        lines.append("m=video 0 RTP/AVP 96")
        switch video.codec {
        case .h264:
            lines.append("a=rtpmap:96 H264/90000")
            var fmtp = "a=fmtp:96 packetization-mode=1"
            if let sps = video.parameterSets.first, sps.count >= 4 {
                fmtp += ";profile-level-id=" + sps[1..<4].map { String(format: "%02X", $0) }.joined()
            }
            if parameterSetsInSDP {
                fmtp += ";sprop-parameter-sets=" + video.parameterSets.prefix(2).map { $0.base64EncodedString() }.joined(separator: ",")
            }
            lines.append(fmtp)
        case .hevc:
            lines.append("a=rtpmap:96 H265/90000")
            if parameterSetsInSDP, video.parameterSets.count >= 3 {
                let sets = video.parameterSets
                lines.append("a=fmtp:96 sprop-vps=\(sets[0].base64EncodedString());sprop-sps=\(sets[1].base64EncodedString());sprop-pps=\(sets[2].base64EncodedString())")
            }
        }
        lines.append("a=control:\(control(0))")
        lines.append("a=recvonly")
        if let audio {
            lines += audioLines(audio, payloadType: audio.codec == .aac ? 97 : staticPayloadType(audio)) + ["a=control:\(control(1))", "a=recvonly"]
        }
        if let backchannel {
            lines += audioLines(backchannel, payloadType: backchannel.codec == .aac ? 98 : staticPayloadType(backchannel))
                + ["a=control:\(control(2))", "a=sendonly"]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func staticPayloadType(_ format: AudioFormat) -> UInt8 {
        format.codec == .pcma ? 8 : 0
    }

    static func payloadType(_ format: AudioFormat, backchannel: Bool) -> UInt8 {
        format.codec == .aac ? (backchannel ? 98 : 97) : staticPayloadType(format)
    }

    private static func audioLines(_ format: AudioFormat, payloadType: UInt8) -> [String] {
        switch format.codec {
        case .aac:
            let config = (format.audioSpecificConfig ?? AudioFormat.aacLC(sampleRate: format.sampleRate, channels: format.channels).audioSpecificConfig ?? Data())
                .map { String(format: "%02X", $0) }.joined()
            return ["m=audio 0 RTP/AVP \(payloadType)", "a=rtpmap:\(payloadType) MPEG4-GENERIC/\(format.sampleRate)/\(format.channels)",
                    "a=fmtp:\(payloadType) streamtype=5;profile-level-id=15;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=\(config)"]
        case .pcma:
            return ["m=audio 0 RTP/AVP \(payloadType)", "a=rtpmap:\(payloadType) PCMA/\(format.sampleRate)"]
        default:
            return ["m=audio 0 RTP/AVP \(payloadType)", "a=rtpmap:\(payloadType) PCMU/\(format.sampleRate)"]
        }
    }
}

/// Parser for what the test server receives: RTSP requests and interleaved frames (backchannel RTP, RTCP).
struct TestServerRequestParser {
    enum Message {
        case request(method: String, uri: String, headers: HTTPHeaders)
        case interleaved(channel: UInt8, payload: Data)
    }

    private var buffer: [UInt8] = []

    mutating func append(_ data: Data) { buffer.append(contentsOf: data) }

    /// Throws on garbage (the server then drops the connection).
    mutating func next() throws -> Message? {
        guard let first = buffer.first else { return nil }
        if first == 0x24 {
            guard buffer.count >= 4 else { return nil }
            let length = Int(buffer[2]) << 8 | Int(buffer[3])
            guard buffer.count >= 4 + length else { return nil }
            let message = Message.interleaved(channel: buffer[1], payload: Data(buffer[4..<(4 + length)]))
            buffer.removeFirst(4 + length)
            return message
        }
        guard let end = headerEnd() else {
            if buffer.count > 64 * 1024 { throw TestServerError.protocolError("request too large") }
            return nil
        }
        let text = String(decoding: buffer[0..<end], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("RTSP/") else { throw TestServerError.protocolError("bad request line") }
        var headers = HTTPHeaders()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.add(line[..<colon].trimmingCharacters(in: .whitespaces), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let bodyLength = max(0, Int(headers["Content-Length"] ?? "0") ?? 0)
        guard buffer.count >= end + 4 + bodyLength else { return nil }
        buffer.removeFirst(end + 4 + bodyLength)
        return .request(method: String(requestLine[0]), uri: String(requestLine[1]), headers: headers)
    }

    private func headerEnd() -> Int? {
        guard buffer.count >= 4 else { return nil }
        for index in 0...(buffer.count - 4) where buffer[index] == 0x0D && buffer[index + 1] == 0x0A && buffer[index + 2] == 0x0D && buffer[index + 3] == 0x0A {
            return index
        }
        return nil
    }
}

enum TestServerError: Error { case protocolError(String) }
