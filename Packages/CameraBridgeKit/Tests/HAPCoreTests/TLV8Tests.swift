import BridgeSupport
import Foundation
import Testing
@testable import HAPCore

@Suite struct TLV8Tests {
    @Test func fragments300ByteValueGolden() throws {
        let value = Data((0..<300).map { UInt8(truncatingIfNeeded: $0) })
        let encoded = TLV8.encode([TLV8.Item(5, value)])
        #expect(encoded.count == 304)
        #expect(encoded[0] == 0x05 && encoded[1] == 0xFF)
        #expect(encoded[257] == 0x05 && encoded[258] == 0x2D)
        #expect(encoded[2..<257] == value[0..<255])
        let decoded = try TLV8.decode(encoded)
        #expect(decoded == [TLV8.Item(5, value)])
    }

    @Test func exactly255BytesIsOneItem() throws {
        let value = Data(repeating: 0xAA, count: 255)
        let encoded = TLV8.encode([TLV8.Item(9, value), TLV8.Item(1, Data([1]))])
        #expect(encoded.count == 2 + 255 + 3)
        #expect(try TLV8.decode(encoded) == [TLV8.Item(9, value), TLV8.Item(1, Data([1]))])
    }

    @Test func emptyValueEncodesZeroLength() throws {
        #expect(TLV8.encode([TLV8.Item(6, Data())]) == Data([0x06, 0x00]))
        #expect(try TLV8.decode(Data([0x06, 0x00])) == [TLV8.Item(6, Data())])
    }

    @Test func consecutiveShortItemsAreNotMerged() throws {
        // Merging only continues a 255-byte fragment.
        let decoded = try TLV8.decode(Data([0x01, 0x01, 0xAA, 0x01, 0x01, 0xBB]))
        #expect(decoded == [TLV8.Item(1, Data([0xAA])), TLV8.Item(1, Data([0xBB]))])
    }

    @Test func decodeRejectsTruncatedInput() {
        #expect(throws: TLV8Error.truncated) { try TLV8.decode(Data([0x01])) }
        #expect(throws: TLV8Error.invalidLength(0x03)) { try TLV8.decode(Data([0x03, 0x05, 0x00])) }
    }

    @Test func splitListOnFF00() throws {
        // Pairing list: {1:id1, 3:pk1, 11:1} FF00 {1:id2, 3:pk2, 11:0}
        let bytes = Data(hex: "0103616263 0302aabb 0b0101 ff00 0103646566 0302ccdd 0b0100")
        let items = try TLV8.decode(try #require(bytes))
        let groups = TLV8.splitList(items)
        #expect(groups.count == 2)
        #expect(groups[0].map(\.type) == [1, 3, 11])
        #expect(groups[1].first?.value == Data("def".utf8))
        #expect(TLV8.splitList([]) == [])
    }

    @Test func splitListWithZeroSeparator() {
        let items = [TLV8.Item(1, Data([0])), TLV8.Item(0, Data()), TLV8.Item(1, Data([1]))]
        #expect(TLV8.splitList(items, separator: 0x00).map { $0.count } == [1, 1])
    }
}

@Suite struct TLVBuilderReaderTests {
    @Test func buildsSupportedVideoStreamConfigurationGolden() throws {
        // Research brief §3.5 golden (1080p30 + 720p30, all profiles and levels).
        var params = TLVBuilder()
        for (i, profile) in [UInt8(0), 1, 2].enumerated() {
            if i > 0 { params.addSeparator(type: 0x00) }
            params.add(1, uint8: profile)
        }
        for (i, level) in [UInt8(0), 1, 2].enumerated() {
            if i > 0 { params.addSeparator(type: 0x00) }
            params.add(2, uint8: level)
        }
        params.add(3, uint8: 0)
        func attributes(_ w: UInt16, _ h: UInt16, _ fps: UInt8) -> TLVBuilder {
            var b = TLVBuilder(); b.add(1, uint16LE: w); b.add(2, uint16LE: h); b.add(3, uint8: fps); return b
        }
        var codec = TLVBuilder()
        codec.add(1, uint8: 0)
        codec.add(2, tlv: params)
        codec.add(3, tlv: attributes(1920, 1080, 30))
        codec.addSeparator(type: 0x00)
        codec.add(3, tlv: attributes(1280, 720, 30))
        var root = TLVBuilder()
        root.add(1, tlv: codec)
        #expect(root.data.hexString == "013e010100021d0101000000010101000001010202010000000201010000020102030100030b010280070202380403011e0000030b010200050202d00203011e")
    }

    @Test func smallGoldens() {
        var rtp = TLVBuilder(); rtp.add(2, uint8: 0)
        #expect(rtp.data.hexString == "020100")                                   // SupportedRTPConfiguration
        var inner = TLVBuilder(); inner.add(1, uint8: 0)
        var dst = TLVBuilder(); dst.add(1, tlv: inner)
        #expect(dst.data.hexString == "0103010100")                               // SupportedDataStreamTransportConfiguration
        var sep = TLVBuilder(); sep.add(1, string: "a"); sep.addSeparator(); sep.add(1, string: "b")
        #expect(sep.data.hexString == "010161ff00010162")
        #expect(sep.items.count == 3)
    }

    @Test func readerRoundTripsEveryScalar() throws {
        var nested = TLVBuilder(); nested.add(1, string: "hello")
        var b = TLVBuilder()
        b.add(1, uint8: 7)
        b.add(2, uint16LE: 0x1234)
        b.add(3, uint32LE: 0xDEADBEEF)
        b.add(4, uint64LE: 0x0102030405060708)
        b.add(5, float32LE: 0.5)
        b.add(6, string: "Pair-Setup")
        b.add(7, tlv: nested)
        b.add(8, Data([0xAB]))
        let r = try TLVReader(b.data)
        #expect(r.uint8(1) == 7)
        #expect(r.uint16LE(2) == 0x1234)
        #expect(r.uint32LE(3) == 0xDEADBEEF)
        #expect(r.uint64LE(4) == 0x0102030405060708)
        #expect(r.float32LE(5) == 0.5)
        #expect(r.string(6) == "Pair-Setup")
        #expect(try r.nested(7)?.string(1) == "hello")
        #expect(try r.nested(99) == nil)
        #expect(r.data(8) == Data([0xAB]))
        #expect(r.data(99) == nil)
        #expect(try r.require(8) == Data([0xAB]))
        #expect(throws: TLV8Error.missing(42)) { try r.require(42) }
    }

    @Test func uint32AcceptsShortEncodings() throws {
        let r = TLVReader(items: [TLV8.Item(1, Data([0x05])), TLV8.Item(2, Data([0x34, 0x12])), TLV8.Item(3, Data([1, 2, 3]))])
        #expect(r.uint32LE(1) == 5)
        #expect(r.uint32LE(2) == 0x1234)
        #expect(r.uint32LE(3) == nil)
        #expect(r.uint64LE(2) == 0x1234)
        #expect(r.uint8(2) == nil)
        #expect(r.uint16LE(1) == 5)
    }

    @Test func allReturnsEveryValueOfType() throws {
        let r = TLVReader(items: [TLV8.Item(1, Data([1])), TLV8.Item(2, Data()), TLV8.Item(1, Data([2]))])
        #expect(r.all(1) == [Data([1]), Data([2])])
        #expect(r.items.count == 3)
    }
}
