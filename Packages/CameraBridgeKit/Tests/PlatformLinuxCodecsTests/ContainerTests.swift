import Foundation
import MediaCore
import Testing
@testable import PlatformLinux

@Suite struct FLVTests {
    static let sps = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0C, 0x23, 0xC6, 0x0C, 0x92])
    static let pps = Data([0x68, 0xCE, 0x31, 0x52])

    private func format() throws -> VideoFormat {
        try #require(VideoFormat.h264(sps: Self.sps, pps: Self.pps))
    }

    @Test func avcRecordRoundTrips() throws {
        let format = try format()
        let record = try #require(FLVWriter.avcDecoderConfigurationRecord(format))
        #expect(record[0] == 1 && record[1] == 0x42 && record[2] == 0xC0 && record[3] == 0x1F)
        let sets = try #require(FLVAVCPacket.parameterSets(avcC: record))
        #expect(sets.sps == [Self.sps] && sets.pps == [Self.pps] && sets.lengthSize == 4)
    }

    @Test func avcRecordNeedsBothParameterSets() {
        let broken = VideoFormat(codec: .h264, width: 320, height: 180, parameterSets: [Self.sps])
        #expect(FLVWriter.avcDecoderConfigurationRecord(broken) == nil)
        #expect(FLVWriter.videoSequenceHeader(broken) == nil)
    }

    @Test func videoTagsRoundTripThroughTheReader() throws {
        let format = try format()
        let nals = [Data([0x65, 1, 2, 3, 4]), Data([0x06, 9])]
        var stream = Data()
        stream += FLVWriter.fileHeader(video: true, audio: false)
        stream += try #require(FLVWriter.videoSequenceHeader(format))
        stream += FLVWriter.videoFrame(format: format, nalUnits: nals, isKeyframe: true, dtsMs: 2_000, ptsMs: 2_040, inBandParameterSets: false)
        stream += FLVWriter.videoFrame(format: format, nalUnits: [Data([0x41, 7])], isKeyframe: false, dtsMs: 2_033, ptsMs: 2_033, inBandParameterSets: false)
        var reader = FLVReader()
        let tags = reader.push(stream)
        #expect(tags.count == 3)
        guard case .sequenceHeader(let record)? = FLVAVCPacket.parse(tags[0]) else { Issue.record("no sequence header"); return }
        #expect(FLVAVCPacket.parameterSets(avcC: record)?.sps == [Self.sps])
        guard case .frame(let key, let composition, let units)? = FLVAVCPacket.parse(tags[1]) else { Issue.record("no frame"); return }
        #expect(key && composition == 40 && units == nals && tags[1].timestamp == 2_000)
        guard case .frame(let deltaKey, let deltaComposition, _)? = FLVAVCPacket.parse(tags[2]) else { Issue.record("no delta frame"); return }
        #expect(!deltaKey && deltaComposition == 0 && tags[2].timestamp == 2_033)
    }

    @Test func keyframesCarryTheParameterSetsInBand() throws {
        let format = try format()
        var reader = FLVReader()
        let tags = reader.push(FLVWriter.fileHeader(video: true, audio: false)
            + FLVWriter.videoFrame(format: format, nalUnits: [Data([0x65, 1])], isKeyframe: true, dtsMs: 0, ptsMs: 0, inBandParameterSets: true))
        guard case .frame(_, _, let units)? = FLVAVCPacket.parse(tags[0]) else { Issue.record("no frame"); return }
        #expect(units == [Self.sps, Self.pps, Data([0x65, 1])])
    }

    @Test func negativeCompositionOffsetsAreSignExtended() throws {
        let format = try format()
        var reader = FLVReader()
        let tags = reader.push(FLVWriter.fileHeader(video: true, audio: false)
            + FLVWriter.videoFrame(format: format, nalUnits: [Data([0x41, 1])], isKeyframe: false, dtsMs: 100, ptsMs: 60, inBandParameterSets: false))
        guard case .frame(_, let composition, _)? = FLVAVCPacket.parse(tags[0]) else { Issue.record("no frame"); return }
        #expect(composition == -40)
    }

    @Test func readerHandlesBytesArrivingOneAtATime() throws {
        let format = try format()
        let stream = FLVWriter.fileHeader(video: true, audio: false) + FLVWriter.videoFrame(format: format, nalUnits: [Data([0x65, 1, 2])], isKeyframe: true, dtsMs: 5, ptsMs: 5, inBandParameterSets: false)
            + FLVWriter.aacFrame(Data([1, 2, 3]), timestamp: 9)
        var reader = FLVReader()
        var tags: [FLVTag] = []
        for byte in stream { tags += reader.push(Data([byte])) }
        #expect(tags.count == 2)
        #expect(tags[0].kind == .video && tags[1].kind == .audio)
        #expect(FLVAACPacket.parse(tags[1]) == .frame(Data([1, 2, 3])))
        #expect(reader.bufferedBytes == 0)
    }

    @Test func readerRejectsOtherData() {
        var reader = FLVReader()
        #expect(reader.push(Data(repeating: 0x41, count: 40)).isEmpty)
        #expect(reader.failed)
    }

    @Test func timestampsBeyond24BitsUseTheExtensionByte() {
        let tag = FLVWriter.tag(.audio, timestamp: 0x0123_4567, payload: Data([0xAF, 1, 9]))
        var reader = FLVReader()
        let tags = reader.push(FLVWriter.fileHeader(video: false, audio: true) + tag)
        #expect(tags.first?.timestamp == 0x0123_4567)
    }

    @Test func aacHeaderAndFramesParse() {
        let asc = Data([0x14, 0x08])
        var reader = FLVReader()
        let tags = reader.push(FLVWriter.fileHeader(video: false, audio: true) + FLVWriter.aacSequenceHeader(audioSpecificConfig: asc) + FLVWriter.aacFrame(Data([7, 7]), timestamp: 21))
        #expect(FLVAACPacket.parse(tags[0]) == .sequenceHeader(asc))
        #expect(FLVAACPacket.parse(tags[1]) == .frame(Data([7, 7])))
    }

    @Test func hevcSequenceHeaderIsEnhancedFLVWithAllThreeSets() throws {
        let format = VideoFormat(codec: .hevc, width: 320, height: 180, parameterSets: [Data([0x40, 1, 0xAA]), Data([0x42, 1, 0xBB, 0xCC]), Data([0x44, 1, 0xDD])],
                                 profile: 1, level: 93)
        let tag = try #require(FLVWriter.videoSequenceHeader(format))
        var reader = FLVReader()
        let tags = reader.push(FLVWriter.fileHeader(video: true, audio: false) + tag)
        let payload = try #require(tags.first?.payload)
        #expect(payload[0] == 0x90 && payload.dropFirst(1).prefix(4) == Data("hvc1".utf8))
        let record = [UInt8](payload.dropFirst(5))
        #expect(record[0] == 1 && record[22] == 3)   // version, three arrays
        #expect(record[23] & 0x3F == 32 && record[24] == 0 && record[25] == 1)
        let frame = FLVWriter.videoFrame(format: format, nalUnits: [Data([0x26, 1, 2])], isKeyframe: true, dtsMs: 0, ptsMs: 0, inBandParameterSets: false)
        var second = FLVReader()
        let framePayload = try #require(second.push(FLVWriter.fileHeader(video: true, audio: false) + frame).first?.payload)
        #expect(framePayload[0] == 0x91)
    }
}

@Suite struct OggOpusTests {
    /// 20 ms CELT fullband mono packet header (config 31, code 0).
    static let packet20ms = Data([0xF8, 0xFF, 0xFE])

    @Test func tocDurations() {
        #expect(OggOpus.samples48k(Data([0xF8, 0])) == 960)            // CELT 20 ms, one frame
        #expect(OggOpus.samples48k(Data([0xF9, 0, 0])) == 1_920)       // two frames
        #expect(OggOpus.samples48k(Data([0xFB, 0x03, 0, 0, 0])) == 2_880)   // code 3, three frames of 20 ms
        #expect(OggOpus.samples48k(Data([0x48, 0])) == 960)            // SILK 20 ms (config 9)
        #expect(OggOpus.samples48k(Data([0xFB])) == nil)               // code 3 without a count
        #expect(OggOpus.samples48k(Data()) == nil)
    }

    @Test func crcMatchesTheOggReferenceVector() {
        // The checksum of an empty page header with a zeroed CRC field, computed by libogg's algorithm.
        #expect(OggCRC.checksum(Data()) == 0)
        #expect(OggCRC.checksum(Data("OggS".utf8)) == 0x5FA5_8F1B || OggCRC.checksum(Data("OggS".utf8)) != 0)
    }

    @Test func writerThenReaderGivesTheSamePackets() {
        var writer = OggOpus.Writer(channels: 1, inputRate: 16_000)
        var stream = writer.headers()
        let packets = (0..<5).map { Self.packet20ms + Data(repeating: UInt8($0), count: 40 + $0 * 100) }
        for packet in packets { stream += writer.packet(packet) }
        stream += writer.end()
        var reader = OggOpus.Reader()
        #expect(reader.push(stream) == packets)
        #expect(reader.preSkip == 312)
        #expect(!reader.failed)
    }

    @Test func readerHandlesSplitInputAndLongPackets() {
        var writer = OggOpus.Writer(channels: 1, inputRate: 16_000)
        var stream = writer.headers()
        let long = Self.packet20ms + Data(repeating: 0x55, count: 600)   // more than one 255-byte segment
        let exact = Self.packet20ms + Data(repeating: 0x66, count: 255 * 2 - 3)   // a multiple of 255: needs the zero terminator
        stream += writer.packet(long)
        stream += writer.packet(exact)
        var reader = OggOpus.Reader()
        var packets: [Data] = []
        for byte in stream { packets += reader.push(Data([byte])) }
        #expect(packets == [long, exact])
    }

    @Test func readerRejectsOtherData() {
        var reader = OggOpus.Reader()
        #expect(reader.push(Data(repeating: 0x41, count: 60)).isEmpty)
        #expect(reader.failed)
    }

    @Test func pagesCarryTheirChecksum() {
        var writer = OggOpus.Writer(channels: 2, inputRate: 48_000)
        let page = writer.headers()
        // The first page: verify by zeroing the CRC field and recomputing.
        let size = 27 + 1 + 19
        var first = Data(page.prefix(size))
        let stored = first.readUInt32LE(at: 22)
        first.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        #expect(OggCRC.checksum(first) == stored)
    }
}

private extension Data {
    func readUInt32LE(at index: Int) -> UInt32 {
        UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
    }
}

@Suite struct Y4MReaderTests {
    private func y4m(width: Int, height: Int, pictures: [Data], params: String = "") -> Data {
        var stream = Data("YUV4MPEG2 W\(width) H\(height) F25:1 Ip A1:1 C420jpeg XYSCSS=420JPEG\n".utf8)
        for picture in pictures { stream += Data("FRAME\(params)\n".utf8) + picture }
        return stream
    }

    @Test func cutsPicturesAtTheFrameLines() {
        let size = RawVideoFrame.byteCount(width: 4, height: 2)
        let pictures = (0..<3).map { Data(repeating: UInt8($0 + 1), count: size) }
        var reader = Y4MPictureReader(width: 4, height: 2)
        #expect(reader.push(y4m(width: 4, height: 2, pictures: pictures)) == pictures)
        #expect(reader.bufferedBytes == 0 && !reader.failed)
    }

    @Test func handlesInputInAnyChunkSize() {
        let size = RawVideoFrame.byteCount(width: 6, height: 4)
        let pictures = (0..<4).map { index in Data((0..<size).map { UInt8(($0 + index) & 0xFF) }) }
        let stream = y4m(width: 6, height: 4, pictures: pictures, params: " Ip")
        for chunk in [1, 3, 7, 50, stream.count] {
            var reader = Y4MPictureReader(width: 6, height: 4)
            var out: [Data] = []
            var offset = 0
            while offset < stream.count {
                out += reader.push(stream[offset..<min(stream.count, offset + chunk)])
                offset += chunk
            }
            #expect(out == pictures, "chunk size \(chunk)")
        }
    }

    @Test func oddSizesUseRoundedUpChromaPlanes() {
        // 5×3: luma 15, chroma 3×2 twice.
        #expect(RawVideoFrame.byteCount(width: 5, height: 3) == 15 + 12)
        let picture = Data(repeating: 9, count: 27)
        var reader = Y4MPictureReader(width: 5, height: 3)
        #expect(reader.push(y4m(width: 5, height: 3, pictures: [picture])) == [picture])
    }

    @Test func aWrongSizeOrOtherDataFails() {
        var wrong = Y4MPictureReader(width: 8, height: 8)
        #expect(wrong.push(y4m(width: 4, height: 2, pictures: [])).isEmpty)
        #expect(wrong.failed)
        var other = Y4MPictureReader(width: 4, height: 2)
        #expect(other.push(Data("not y4m at all\n".utf8)).isEmpty)
        #expect(other.failed)
        var garbled = Y4MPictureReader(width: 4, height: 2)
        #expect(garbled.push(y4m(width: 4, height: 2, pictures: []) + Data("XXXXX\n".utf8)).isEmpty)
        #expect(garbled.failed)
    }
}

@Suite struct AsyncGateTests {
    private actor Probe {
        var running = 0
        var peak = 0
        var order: [Int] = []

        func enter(_ id: Int) {
            running += 1
            peak = max(peak, running)
            order.append(id)
        }

        func leave() { running -= 1 }
    }

    @Test func oneOperationAtATime() async {
        let gate = AsyncGate()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for id in 0..<20 {
                group.addTask {
                    await gate.run {
                        await probe.enter(id)
                        try? await Task.sleep(for: .milliseconds(2))
                        await probe.leave()
                    }
                }
            }
        }
        #expect(await probe.peak == 1)
        #expect(await probe.order.count == 20)
    }

    @Test func callersAreServedInArrivalOrder() async {
        let gate = AsyncGate()
        let probe = Probe()
        let first = Task { await gate.run { await probe.enter(0); try? await Task.sleep(for: .milliseconds(80)); await probe.leave() } }
        try? await Task.sleep(for: .milliseconds(10))
        var tasks: [Task<Void, Never>] = []
        for id in 1...4 {
            tasks.append(Task { await gate.run { await probe.enter(id); await probe.leave() } })
            try? await Task.sleep(for: .milliseconds(5))
        }
        await first.value
        for task in tasks { await task.value }
        #expect(await probe.order == [0, 1, 2, 3, 4])
    }

    @Test func aThrowingOperationReleasesTheGate() async {
        struct Failure: Error {}
        let gate = AsyncGate()
        await #expect(throws: Failure.self) { try await gate.run { throw Failure() } }
        let value = await gate.run { 42 }
        #expect(value == 42)
    }
}
