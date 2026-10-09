import BridgeSupport
import Foundation
import MediaCore
import Testing
@testable import RTSP

/// Independent FLV writer for tests (Adobe FLV v10.1 §E, Enhanced RTMP v1 for HEVC).
enum FLVWriter {
    static func header(audio: Bool = true, video: Bool = true) -> Data {
        var data = Data("FLV".utf8)
        data.append(1)
        data.append((audio ? 0x04 : 0) | (video ? 0x01 : 0))
        data.append(contentsOf: [0, 0, 0, 9])
        data.append(contentsOf: [0, 0, 0, 0])   // PreviousTagSize0
        return data
    }

    static func tag(type: UInt8, timestamp: UInt32, body: Data) -> Data {
        var writer = ByteWriter()
        writer.write(type)
        writer.writeUInt24BE(UInt32(body.count))
        writer.writeUInt24BE(timestamp & 0xFF_FFFF)
        writer.write(UInt8(timestamp >> 24))
        writer.writeUInt24BE(0)
        writer.write(body)
        writer.writeUInt32BE(UInt32(11 + body.count))
        return writer.data
    }

    static func script() -> Data {
        // AMF0 "onMetaData" + empty ECMA array.
        var body = Data([0x02, 0x00, 0x0A])
        body.append(Data("onMetaData".utf8))
        body.append(contentsOf: [0x08, 0, 0, 0, 0, 0, 0, 9])
        return tag(type: 18, timestamp: 0, body: body)
    }

    static func avcSequenceHeader(sps: Data, pps: Data, timestamp: UInt32 = 0) -> Data {
        let s = [UInt8](sps)
        var record = Data([0x01, s[1], s[2], s[3], 0xFF, 0xE1])
        record.append(UInt8(sps.count >> 8)); record.append(UInt8(sps.count & 0xFF)); record.append(sps)
        record.append(0x01)
        record.append(UInt8(pps.count >> 8)); record.append(UInt8(pps.count & 0xFF)); record.append(pps)
        var body = Data([0x17, 0x00, 0, 0, 0])
        body.append(record)
        return tag(type: 9, timestamp: timestamp, body: body)
    }

    static func avcNALUs(_ nals: [Data], keyframe: Bool, timestamp: UInt32, compositionTime: Int32 = 0) -> Data {
        var body = Data([keyframe ? 0x17 : 0x27, 0x01])
        let cts = UInt32(bitPattern: compositionTime) & 0xFF_FFFF
        body.append(contentsOf: [UInt8(cts >> 16), UInt8((cts >> 8) & 0xFF), UInt8(cts & 0xFF)])
        for nal in nals {
            var length = ByteWriter()
            length.writeUInt32BE(UInt32(nal.count))
            body.append(length.data)
            body.append(nal)
        }
        return tag(type: 9, timestamp: timestamp, body: body)
    }

    static func hevcRecord(vps: Data, sps: Data, pps: Data) -> Data {
        var record = Data([0x01])
        record.append(Data(repeating: 0, count: 20))   // profile/tier/level/constraints/… (not read by the demuxer)
        record.append(0x0F)                             // … lengthSizeMinusOne = 3
        record.append(3)                                // numOfArrays
        for (type, nal) in [(UInt8(32), vps), (33, sps), (34, pps)] {
            record.append(0x80 | type)
            record.append(contentsOf: [0x00, 0x01])
            record.append(UInt8(nal.count >> 8)); record.append(UInt8(nal.count & 0xFF)); record.append(nal)
        }
        return record
    }

    static func enhancedHEVCSequenceStart(vps: Data, sps: Data, pps: Data) -> Data {
        var body = Data([0x80 | 0x10 | 0x00])   // ExHeader, keyframe, SequenceStart
        body.append(Data("hvc1".utf8))
        body.append(hevcRecord(vps: vps, sps: sps, pps: pps))
        return tag(type: 9, timestamp: 0, body: body)
    }

    /// Enhanced RTMP coded frames: packet type 1 (with composition time) or 3 (CodedFramesX).
    static func enhancedHEVCFrames(_ nals: [Data], keyframe: Bool, timestamp: UInt32, withCompositionTime: Bool) -> Data {
        var body = Data([0x80 | (keyframe ? 0x10 : 0x20) | (withCompositionTime ? 0x01 : 0x03)])
        body.append(Data("hvc1".utf8))
        if withCompositionTime { body.append(contentsOf: [0, 0, 0]) }
        for nal in nals {
            var length = ByteWriter()
            length.writeUInt32BE(UInt32(nal.count))
            body.append(length.data)
            body.append(nal)
        }
        return tag(type: 9, timestamp: timestamp, body: body)
    }

    static func aacSequenceHeader(_ config: Data) -> Data {
        var body = Data([0xAF, 0x00])
        body.append(config)
        return tag(type: 8, timestamp: 0, body: body)
    }

    static func aacRaw(_ frame: Data, timestamp: UInt32) -> Data {
        var body = Data([0xAF, 0x01])
        body.append(frame)
        return tag(type: 8, timestamp: timestamp, body: body)
    }

    static func muLaw(_ samples: Data, timestamp: UInt32) -> Data {
        var body = Data([0x82])   // format 8 (G.711 µ-law), 5.5 kHz flag (ignored), 16-bit, mono
        body.append(samples)
        return tag(type: 8, timestamp: timestamp, body: body)
    }
}

@Suite struct FLVDemuxerTests {
    let sets = RealParameterSets.h264Main640x360

    private func sampleStream() -> Data {
        var stream = FLVWriter.header()
        stream.append(FLVWriter.script())
        stream.append(FLVWriter.avcSequenceHeader(sps: sets.sps, pps: sets.pps))
        stream.append(FLVWriter.aacSequenceHeader(Data([0x14, 0x08])))
        stream.append(FLVWriter.avcNALUs([Data([0x09, 0xF0]), h264NAL(type: 5, size: 400)], keyframe: true, timestamp: 0))
        stream.append(FLVWriter.aacRaw(filler(100, seed: 1), timestamp: 0))
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 1, size: 120, seed: 2, nri: 0x40)], keyframe: false, timestamp: 40, compositionTime: 40))
        stream.append(FLVWriter.aacRaw(filler(100, seed: 2), timestamp: 64))
        return stream
    }

    private func check(_ samples: [FLVSample]) throws {
        #expect(samples.count == 4)
        guard case .video(let key) = samples[0], case .audio(let a0) = samples[1], case .video(let p) = samples[2],
              case .audio(let a1) = samples[3] else {
            Issue.record("unexpected order")
            return
        }
        #expect(key.isKeyframe)
        #expect(key.nalUnits == [h264NAL(type: 5, size: 400)])   // AUD removed
        #expect(key.format.width == 640)
        #expect(key.format.height == 360)
        #expect(key.format.parameterSets == [sets.sps, sets.pps])
        #expect(key.timestamp == 0)
        #expect(!p.isKeyframe)
        #expect(p.timestamp == 40)
        #expect(p.compositionOffset == 40)
        #expect(a0.format == AudioFormat(codec: .aac, sampleRate: 16_000, channels: 1, audioSpecificConfig: Data([0x14, 0x08])))
        #expect(a0.data == filler(100, seed: 1))
        #expect(a1.timestamp == 64)
    }

    @Test func avcAndAACStream() throws {
        var demuxer = FLVDemuxer()
        try check(try demuxer.append(sampleStream()))
    }

    @Test func byteByByteFeeding() throws {
        var demuxer = FLVDemuxer()
        var samples: [FLVSample] = []
        for byte in sampleStream() { samples += try demuxer.append(Data([byte])) }
        try check(samples)
    }

    @Test func extendedTimestampsAndWrap() throws {
        var demuxer = FLVDemuxer()
        var stream = FLVWriter.header()
        stream.append(FLVWriter.avcSequenceHeader(sps: sets.sps, pps: sets.pps, timestamp: 0xFFFF_FF00))
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 5, size: 10)], keyframe: true, timestamp: 0xFFFF_FF00))
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 1, size: 10)], keyframe: false, timestamp: UInt32.max - 5))
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 1, size: 10)], keyframe: false, timestamp: 30))
        let samples = try demuxer.append(stream)
        let times = samples.compactMap { sample -> Int64? in if case .video(let v) = sample { v.timestamp } else { nil } }
        #expect(times == [0xFFFF_FF00, Int64(UInt32.max) - 5, Int64(UInt32.max) + 31])
    }

    @Test func enhancedHEVC() throws {
        let hevc = RealParameterSets.hevcMain640x360
        var demuxer = FLVDemuxer()
        var stream = FLVWriter.header(audio: false)
        stream.append(FLVWriter.enhancedHEVCSequenceStart(vps: hevc.vps, sps: hevc.sps, pps: hevc.pps))
        stream.append(FLVWriter.enhancedHEVCFrames([hevcNAL(type: 19, size: 300)], keyframe: true, timestamp: 0, withCompositionTime: true))
        stream.append(FLVWriter.enhancedHEVCFrames([hevcNAL(type: 1, size: 100)], keyframe: false, timestamp: 33, withCompositionTime: false))
        let samples = try demuxer.append(stream)
        #expect(samples.count == 2)
        guard case .video(let key) = samples.first, case .video(let trail) = samples.last else { Issue.record("expected video"); return }
        #expect(key.format.codec == .hevc)
        #expect(key.format.width == 640)
        #expect(key.isKeyframe)
        #expect(key.nalUnits == [hevcNAL(type: 19, size: 300)])
        #expect(trail.nalUnits == [hevcNAL(type: 1, size: 100)])
        #expect(trail.timestamp == 33)
    }

    @Test func legacyHEVCCodecID() throws {
        let hevc = RealParameterSets.hevcMain640x360
        var demuxer = FLVDemuxer()
        var stream = FLVWriter.header(audio: false)
        var header = Data([0x1C, 0x00, 0, 0, 0])
        header.append(FLVWriter.hevcRecord(vps: hevc.vps, sps: hevc.sps, pps: hevc.pps))
        stream.append(FLVWriter.tag(type: 9, timestamp: 0, body: header))
        var frame = Data([0x1C, 0x01, 0, 0, 0])
        let nal = hevcNAL(type: 20, size: 50)
        frame.append(contentsOf: [0, 0, 0, UInt8(nal.count)])
        frame.append(nal)
        stream.append(FLVWriter.tag(type: 9, timestamp: 0, body: frame))
        let samples = try demuxer.append(stream)
        guard case .video(let key)? = samples.first else { Issue.record("expected video"); return }
        #expect(key.format.codec == .hevc)
        #expect(key.isKeyframe)
    }

    @Test func g711Audio() throws {
        var demuxer = FLVDemuxer()
        var stream = FLVWriter.header(video: false)
        stream.append(FLVWriter.muLaw(filler(160), timestamp: 20))
        let samples = try demuxer.append(stream)
        guard case .audio(let audio)? = samples.first else { Issue.record("expected audio"); return }
        #expect(audio.format == AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))
        #expect(audio.data == filler(160))
        #expect(audio.timestamp == 20)
    }

    @Test func inBandParameterSetsChangeFormat() throws {
        var demuxer = FLVDemuxer()
        let big = RealParameterSets.h264High1080p
        var stream = FLVWriter.header(audio: false)
        stream.append(FLVWriter.avcSequenceHeader(sps: sets.sps, pps: sets.pps))
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 5, size: 10)], keyframe: true, timestamp: 0))
        stream.append(FLVWriter.avcNALUs([big.sps, big.pps, h264NAL(type: 5, size: 10)], keyframe: true, timestamp: 40))
        let samples = try demuxer.append(stream)
        let widths = samples.compactMap { sample -> Int? in if case .video(let v) = sample { v.format.width } else { nil } }
        #expect(widths == [640, 1920])
    }

    @Test func framesBeforeSequenceHeaderAreDropped() throws {
        var demuxer = FLVDemuxer()
        var stream = FLVWriter.header()
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 5, size: 10)], keyframe: true, timestamp: 0))
        stream.append(FLVWriter.aacRaw(filler(10), timestamp: 0))
        #expect(try demuxer.append(stream).isEmpty)
    }

    @Test func invalidSignatureThrows() {
        var demuxer = FLVDemuxer()
        #expect(throws: RTSPError.self) { _ = try demuxer.append(Data("HTTP/1.1 200".utf8)) }
    }

    @Test func truncatedVideoBodyIsSkipped() throws {
        var demuxer = FLVDemuxer()
        var stream = FLVWriter.header(audio: false)
        stream.append(FLVWriter.avcSequenceHeader(sps: sets.sps, pps: sets.pps))
        // NAL length prefix claims more bytes than the tag holds.
        stream.append(FLVWriter.tag(type: 9, timestamp: 0, body: Data([0x17, 0x01, 0, 0, 0, 0, 0, 0x10, 0x00, 0x65])))
        stream.append(FLVWriter.avcNALUs([h264NAL(type: 5, size: 10)], keyframe: true, timestamp: 40))
        let samples = try demuxer.append(stream)
        #expect(samples.count == 1)
    }
}
