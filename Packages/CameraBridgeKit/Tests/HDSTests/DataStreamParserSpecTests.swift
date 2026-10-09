// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// Port of `lib/datastream/DataStreamParser.spec.ts` to swift-testing.

import Foundation
import Testing
@testable import HDS

@Suite struct DataStreamParserSpecTests {
    // MARK: writeNumber Int32 range check

    @Test func encodesNumbersInInt32RangeAsInt32NotInt64() throws {
        // 100000 is within Int32 range: tag byte (1) + 4 bytes = 5 (as Int64 it would be 1 + 8 = 9).
        let data = try HDSCodec.encode(.int(100_000))
        #expect(data.count == 5)
        #expect(try HDSCodec.decode(data) == .int(100_000))
    }

    @Test func encodesMaxInt32AsInt32() throws {
        let data = try HDSCodec.encode(.int(2_147_483_647))
        #expect(data.count == 5)
        #expect(try HDSCodec.decode(data) == .int(2_147_483_647))
    }

    @Test func encodesMinInt32AsInt32() throws {
        let data = try HDSCodec.encode(.int(-2_147_483_648))
        #expect(data.count == 5)
        #expect(try HDSCodec.decode(data) == .int(-2_147_483_648))
    }

    @Test func encodesNumbersBeyondInt32RangeAsInt64() throws {
        let data = try HDSCodec.encode(.int(2_147_483_648))   // one above Int32 max
        #expect(data.count == 9)
        #expect(try HDSCodec.decode(data) == .int(2_147_483_648))
    }

    // MARK: readFloat64LE reader index advance

    @Test func advancesReaderIndexAfterReadingFloat64() throws {
        var writer = HDSWriter()
        try writer.write(.float(3.14))
        try writer.write(.float(2.71))
        var reader = HDSReader(writer.data)
        let first = try reader.readValue()
        let second = try reader.readValue()
        guard case .float(let a) = first, case .float(let b) = second else {
            Issue.record("expected two floats, got \(first) and \(second)")
            return
        }
        #expect(abs(a - 3.14) < 1e-9)
        #expect(abs(b - 2.71) < 1e-9)
        #expect(abs(b - 3.14) > 0.1)   // if the index did not advance, both would be 3.14
        #expect(reader.isAtEnd)
    }

    // MARK: UTF-8 tag byte length

    @Test func encodesMultiByteUTF8Strings() throws {
        // "é" is 2 bytes in UTF-8 but 1 character.
        let data = try HDSCodec.encode(.string("é"))
        #expect(try HDSCodec.decode(data) == .string("é"))
    }

    @Test func roundTripsShortStringsWithMultiByteCharacters() throws {
        // Mix of ASCII and multi-byte: 5 characters, 6 bytes in UTF-8 (the upstream comment says 7).
        let data = try HDSCodec.encode(.string("hëllo"))
        #expect(data.first == UInt8(0x40 + 6))
        #expect(try HDSCodec.decode(data) == .string("hëllo"))
    }
}
