import BridgeSupport
import Foundation
import Testing
@testable import HDS

// Expected bytes marked [HN-run] were produced by running HAP-NodeJS 2.1.6's `DataStreamParser` (dist JS, Node 24)
// on the same values; the others are computed by hand from the tag table in research brief §3.8 (cases where HN
// is buggy or differs by design: int64 > 2^32, arrays of 13–14 items, lengths ≥ 64 KiB). The full golden set from the
// pinned HAP-NodeJS 2.2.3 (Fixtures/hds-codec.json) is checked in HDSFixtureGoldenTests.

func hex(_ value: HDSValue) throws -> String {
    try HDSCodec.encode(value).hexString
}

func decodeHex(_ text: String) throws -> HDSValue {
    try HDSCodec.decode(try #require(Data(hex: text)))
}

func dict(_ pairs: (String, HDSValue)...) -> HDSValue {
    .dictionary(HDSDictionary(pairs))
}

@Suite struct HDSCodecEncodingTests {
    @Test(arguments: [
        (Int64(-1), "07"), (0, "08"), (1, "09"), (38, "2e"), (39, "2f"), (40, "3028"), (-2, "30fe"), (127, "307f"),
        (-128, "3080"), (128, "318000"), (-129, "317fff"), (32767, "31ff7f"), (-32768, "310080"),
        (32768, "3200800000"), (-32769, "32ff7fffff"), (2_147_483_647, "32ffffff7f"), (-2_147_483_648, "3200000080"),
        (2_147_483_648, "330000008000000000"), (4_294_967_295, "33ffffffff00000000"),   // [HN-run] up to here
        (-2_147_483_649, "33ffffff7fffffffff"), (4_294_967_301, "330500000001000000"),   // HN cannot write > 2^32
        (Int64.max, "33ffffffffffffff7f"), (Int64.min, "330000000000000080"),
    ])
    func integersUseTheSmallestCanonicalForm(value: Int64, expected: String) throws {
        #expect(try hex(.int(value)) == expected)
        #expect(try decodeHex(expected) == .int(value))
    }

    @Test func scalars() throws {
        #expect(try hex(.null) == "04")                              // [HN-run]
        #expect(try hex(.bool(true)) == "01")
        #expect(try hex(.bool(false)) == "02")
        #expect(try hex(.float(1.5)) == "36000000000000f83f")        // [HN-run] always float64
        #expect(try hex(.float(-0.25)) == "36000000000000d0bf")
        let uuid = try #require(UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0"))
        #expect(try hex(.uuid(uuid)) == "05123456789abcdef0123456789abcdef0")   // [HN-run] big-endian
        #expect(try hex(.date(Date(timeIntervalSinceReferenceDate: 1234.5))) == "0600000000004a9340")   // [HN-run]
    }

    @Test func stringsUseShortFormUpTo32BytesThenLengthPrefixes() throws {
        #expect(try hex(.string("")) == "40")                                                  // [HN-run]
        #expect(try hex(.string("dataSend")) == "486461746153656e64")                          // [HN-run]
        #expect(try hex(.string(String(repeating: "a", count: 32))) == "60" + String(repeating: "61", count: 32))
        #expect(try hex(.string(String(repeating: "b", count: 33))) == "6121" + String(repeating: "62", count: 33))
        #expect(try hex(.string(String(repeating: "c", count: 255))) == "61ff" + String(repeating: "63", count: 255))
        #expect(try hex(.string(String(repeating: "d", count: 256))) == "620001" + String(repeating: "64", count: 256))
        #expect(try hex(.string(String(repeating: "e", count: 65535))) == "62ffff" + String(repeating: "65", count: 65535))
        #expect(try hex(.string(String(repeating: "f", count: 65536))) == "6300000100" + String(repeating: "66", count: 65536))
    }

    @Test func stringLengthCountsUTF8Bytes() throws {
        #expect(try hex(.string("é")) == "42c3a9")                  // [HN-run]
        #expect(try hex(.string("hëllo")) == "4668c3ab6c6c6f")      // [HN-run]
        // 16 two-byte characters = 32 bytes (short form); 17 = 34 bytes (length-prefixed).
        #expect(try hex(.string(String(repeating: "é", count: 16))).hasPrefix("60c3a9"))
        #expect(try hex(.string(String(repeating: "é", count: 17))).hasPrefix("6122c3a9"))
    }

    @Test func dataUsesShortFormUpTo32BytesThenLengthPrefixes() throws {
        #expect(try hex(.data(Data())) == "70")                                                      // [HN-run]
        #expect(try hex(.data(Data([1, 2, 3]))) == "73010203")                                       // [HN-run]
        #expect(try hex(.data(Data(repeating: 0x11, count: 32))) == "90" + String(repeating: "11", count: 32))
        #expect(try hex(.data(Data(repeating: 0x22, count: 33))) == "9121" + String(repeating: "22", count: 33))
        #expect(try hex(.data(Data(repeating: 0x33, count: 300))) == "922c01" + String(repeating: "33", count: 300))
        #expect(try hex(.data(Data(repeating: 0x44, count: 65536))) == "9300000100" + String(repeating: "44", count: 65536))
    }

    @Test func arraysUseCountFormUpTo14ItemsThenTerminated() throws {
        func ints(_ n: Int) -> HDSValue { .array((0..<n).map { .int(Int64($0)) }) }
        func items(_ n: Int) -> String { (0..<n).map { String(format: "%02x", 8 + $0) }.joined() }
        #expect(try hex(.array([])) == "d0")
        #expect(try hex(.array([.int(1), .string("x"), .bool(false)])) == "d309417802")   // [HN-run]
        #expect(try hex(ints(12)) == "dc" + items(12))                                     // [HN-run]
        #expect(try hex(ints(13)) == "dd" + items(13))   // HN switches to the terminated form after 12
        #expect(try hex(ints(14)) == "de" + items(14))
        #expect(try hex(ints(15)) == "df" + items(15) + "03")
    }

    @Test func dictionariesUseCountFormUpTo14EntriesThenTerminated() throws {
        func entries(_ n: Int) -> HDSValue { .dictionary(HDSDictionary((0..<n).map { ("k\($0)", .int(Int64($0))) })) }
        #expect(try hex(.dictionary(HDSDictionary())) == "e0")
        #expect(try hex(entries(14)) ==   // [HN-run]
            "ee426b3008426b3109426b320a426b330b426b340c426b350d426b360e426b370f426b3810426b3911436b313012436b313113436b313214436b313315")
        #expect(try hex(entries(15)) ==   // [HN-run]
            "ef426b3008426b3109426b320a426b330b426b340c426b350d426b360e426b370f426b3810426b3911436b313012436b313113436b313214436b313315436b31341603")
    }

    @Test func dictionaryKeepsInsertionOrder() throws {
        #expect(try hex(dict(("b", .int(1)), ("a", .int(2)))) == "e241620941610a")
        #expect(try hex(dict(("a", .int(2)), ("b", .int(1)))) == "e241610a416209")
    }

    /// Brief §3.8 golden [HN-run; SW*].
    @Test func eventHeaderGolden() throws {
        let header = dict(("protocol", .string("dataSend")), ("event", .string("data")))
        #expect(try hex(header) == "e24870726f746f636f6c486461746153656e64456576656e744464617461")
    }

    /// A recording `dataSend/data` event body [HN-run].
    @Test func nestedDataSendBodyMatchesHAPNodeJS() throws {
        let body = dict(
            ("streamId", .int(1)),
            ("packets", .array([dict(
                ("data", .data(Data([0xDE, 0xAD]))),
                ("metadata", dict(
                    ("dataType", .string("mediaFragment")), ("dataSequenceNumber", .int(2)), ("dataChunkSequenceNumber", .int(1)),
                    ("isLastDataChunk", .bool(true)), ("dataTotalSize", .int(100_000)))))])),
            ("endOfStream", .bool(false)))
        let expected = "e34873747265616d496409477061636b657473d1e2446461746172dead486d65746164617461e54864617461547970654d6d65646961467261676d656e74526461746153657175656e63654e756d6265720a57646174614368756e6b53657175656e63654e756d626572094f69734c617374446174614368756e6b014d64617461546f74616c53697a6532a08601004b656e644f6653747265616d02"
        #expect(try hex(body) == expected)
        #expect(try decodeHex(expected) == body)
    }

    /// Repeated values are written out again: the encoder never emits the A0–CF back-reference tags.
    @Test func neverEmitsBackReferences() throws {
        let repeated = HDSValue.array([.string("abc"), .string("abc"), .int(1000), .int(1000), .data(Data([1])), .data(Data([1]))])
        #expect(try hex(repeated) == "d6" + "43616263" + "43616263" + "31e803" + "31e803" + "7101" + "7101")
    }

    @Test func nestingDepthIsBounded() throws {
        var value = HDSValue.int(0)
        for _ in 0..<HDSCodec.maximumDepth { value = .array([value]) }
        let encoded = try HDSCodec.encode(value)
        #expect(try HDSCodec.decode(encoded) == value)
        #expect(throws: HDSCodecError.nestingTooDeep) { try HDSCodec.encode(.array([value])) }
    }
}

@Suite struct HDSCodecDecodingTests {
    @Test func constantsAndSmallIntegers() throws {
        #expect(try decodeHex("01") == .bool(true))
        #expect(try decodeHex("02") == .bool(false))
        #expect(try decodeHex("04") == .null)
        #expect(try decodeHex("07") == .int(-1))
        #expect(try decodeHex("08") == .int(0))
        #expect(try decodeHex("2e") == .int(38))
        #expect(try decodeHex("2f") == .int(39))   // HN throws "unknown tag" (brief §3.8 bug)
    }

    @Test func fixedWidthIntegersAreSignedLittleEndian() throws {
        #expect(try decodeHex("30ff") == .int(-1))
        #expect(try decodeHex("3005") == .int(5))   // non-canonical forms are accepted
        #expect(try decodeHex("31feff") == .int(-2))
        #expect(try decodeHex("32fdffffff") == .int(-3))
        #expect(try decodeHex("33fcffffffffffffff") == .int(-4))
        #expect(try decodeHex("330500000001000000") == .int(4_294_967_301))
        #expect(try decodeHex("33ffffffffffffff7f") == .int(.max))
    }

    @Test func floatsAndDates() throws {
        #expect(try decodeHex("350000c03f") == .float(1.5))   // float32
        #expect(try decodeHex("36000000000000f83f") == .float(1.5))
        #expect(try decodeHex("0600000000004a9340") == .date(Date(timeIntervalSinceReferenceDate: 1234.5)))
        let uuid = try #require(UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0"))
        #expect(try decodeHex("05123456789abcdef0123456789abcdef0") == .uuid(uuid))
    }

    @Test func everyStringForm() throws {
        #expect(try decodeHex("40") == .string(""))
        #expect(try decodeHex("4568656c6c6f") == .string("hello"))
        #expect(try decodeHex("60" + String(repeating: "61", count: 32)) == .string(String(repeating: "a", count: 32)))
        #expect(try decodeHex("610568656c6c6f") == .string("hello"))
        #expect(try decodeHex("62050068656c6c6f") == .string("hello"))
        #expect(try decodeHex("630500000068656c6c6f") == .string("hello"))
        #expect(try decodeHex("64050000000000000068656c6c6f") == .string("hello"))
        #expect(try decodeHex("6f68656c6c6f00") == .string("hello"))   // NUL-terminated
        #expect(try decodeHex("6f00") == .string(""))
    }

    @Test func everyDataForm() throws {
        #expect(try decodeHex("70") == .data(Data()))
        #expect(try decodeHex("73010203") == .data(Data([1, 2, 3])))   // HN returns undefined (brief §3.8 bug)
        #expect(try decodeHex("90" + String(repeating: "ab", count: 32)) == .data(Data(repeating: 0xAB, count: 32)))
        #expect(try decodeHex("9103010203") == .data(Data([1, 2, 3])))
        #expect(try decodeHex("920300010203") == .data(Data([1, 2, 3])))
        #expect(try decodeHex("9303000000010203") == .data(Data([1, 2, 3])))
        #expect(try decodeHex("940300000000000000010203") == .data(Data([1, 2, 3])))
        #expect(try decodeHex("9f01020403") == .data(Data([1, 2, 4])))   // terminated by 0x03
    }

    @Test func arraysAndDictionaries() throws {
        #expect(try decodeHex("d0") == .array([]))
        #expect(try decodeHex("d20809") == .array([.int(0), .int(1)]))
        #expect(try decodeHex("de" + String(repeating: "04", count: 14)) == .array(Array(repeating: .null, count: 14)))
        #expect(try decodeHex("df080903") == .array([.int(0), .int(1)]))
        #expect(try decodeHex("df03") == .array([]))
        #expect(try decodeHex("e0") == dict())
        #expect(try decodeHex("e1416108") == dict(("a", .int(0))))
        #expect(try decodeHex("ef41610841620903") == dict(("a", .int(0)), ("b", .int(1))))
        #expect(try decodeHex("ef03") == dict())
        #expect(try decodeHex("e2416108416109") == dict(("a", .int(0)), ("a", .int(1))))   // duplicates are kept in order
    }

    /// A0–CF refer to earlier decoded scalars (HAP-NodeJS reader semantics: booleans, integers, floats, dates,
    /// strings, data and UUIDs are remembered in order; null, containers and back-references are not).
    @Test func backReferencesResolveEarlierValues() throws {
        #expect(try decodeHex("d243616263a0") == .array([.string("abc"), .string("abc")]))
        #expect(try decodeHex("d3 01 4161 a1") == .array([.bool(true), .string("a"), .string("a")]))
        #expect(try decodeHex("d3 04 4161 a0") == .array([.null, .string("a"), .string("a")]))   // null is not remembered
        #expect(try decodeHex("d4 04 4161 7101 a1") == .array([.null, .string("a"), .data(Data([1])), .data(Data([1]))]))
        #expect(try decodeHex("d3 31e803 a0 a0") == .array([.int(1000), .int(1000), .int(1000)]))   // references are not
        #expect(try decodeHex("d2 d108 a0") == .array([.array([.int(0)]), .int(0)]))              // containers are not
        #expect(try decodeHex("d2 0600000000004a9340 a0") ==
            .array([.date(Date(timeIntervalSinceReferenceDate: 1234.5)), .date(Date(timeIntervalSinceReferenceDate: 1234.5))]))
        // A repeated dictionary key (typical for arrays of dictionaries).
        #expect(try decodeHex("d2 e1 4178 08 e1 a0 09") == .array([dict(("x", .int(0))), dict(("x", .int(1)))]))
    }

    @Test func malformedInputThrowsTypedErrors() throws {
        let cases: [(String, HDSCodecError)] = [
            ("", .truncated), ("00", .invalidTag(0x00)), ("03", .unexpectedTerminator),
            ("34", .invalidTag(0x34)), ("37", .invalidTag(0x37)), ("3f", .invalidTag(0x3F)), ("65", .invalidTag(0x65)),
            ("6e", .invalidTag(0x6E)), ("95", .invalidTag(0x95)), ("9e", .invalidTag(0x9E)), ("f0", .invalidTag(0xF0)),
            ("ff", .invalidTag(0xFF)),
            ("a0", .invalidBackReference(0)), ("d2 08 a1", .invalidBackReference(1)), ("cf", .invalidBackReference(47)),
            ("d1 03", .unexpectedTerminator), ("e1 4161 03", .unexpectedTerminator), ("ef 4161 03", .unexpectedTerminator),
            ("e1 08 08", .nonStringKey), ("ef 08 08 03", .nonStringKey), ("e1 04 08", .nonStringKey),
            ("ef 4161 08", .truncated), ("df 08", .truncated), ("d2 08", .truncated),
            ("4568", .truncated), ("61", .truncated), ("6105 6869", .truncated), ("62 05", .truncated),
            ("64 ffffffffffffffff", .truncated), ("94 ffffffffffffffff", .truncated), ("93 ffffffff", .truncated),
            ("6f 6869", .truncated), ("9f 0102", .truncated),
            ("05 00112233445566778899aabbccddee", .truncated), ("06 00000000000000", .truncated), ("30", .truncated),
            ("31 00", .truncated), ("32 000000", .truncated), ("33 00000000000000", .truncated), ("35 000000", .truncated),
            ("36 00000000000000", .truncated),
            ("08 08", .trailingBytes(1)), ("e0 0000", .trailingBytes(2)),
        ]
        for (input, expected) in cases {
            let data = try #require(Data(hex: input))
            #expect(throws: expected, "input \(input)") { try HDSCodec.decode(data) }
        }
    }

    /// Like HAP-NodeJS (`Buffer.toString("utf8")`, outputs checked with Node 24), invalid UTF-8 in strings and keys
    /// decodes with U+FFFD replacement characters instead of failing the whole message.
    @Test func invalidUTF8DecodesWithReplacementCharacters() throws {
        #expect(try decodeHex("42 c328") == .string("\u{FFFD}("))
        #expect(try decodeHex("6f c328 00") == .string("\u{FFFD}("))
        #expect(try decodeHex("61 01 ff") == .string("\u{FFFD}"))
        #expect(try decodeHex("43 41ff42") == .string("A\u{FFFD}B"))
        #expect(try decodeHex("42 e282") == .string("\u{FFFD}"))
        #expect(try decodeHex("43 f09f98") == .string("\u{FFFD}"))
        #expect(try decodeHex("e1 41ff 08") == dict(("\u{FFFD}", .int(0))))
        #expect(try decodeHex("d2 42c328 a0") == .array([.string("\u{FFFD}("), .string("\u{FFFD}(")]))   // remembered as decoded
    }

    @Test func deepNestingIsRejectedWithoutRecursingUnboundedly() throws {
        let limit = HDSCodec.maximumDepth
        let ok = Data(repeating: 0xD1, count: limit) + Data([0x08])
        #expect(throws: Never.self) { try HDSCodec.decode(ok) }
        let tooDeep = Data(repeating: 0xD1, count: limit + 1) + Data([0x08])
        #expect(throws: HDSCodecError.nestingTooDeep) { try HDSCodec.decode(tooDeep) }
        let hostile = Data(repeating: 0xDF, count: 100_000)
        #expect(throws: HDSCodecError.nestingTooDeep) { try HDSCodec.decode(hostile) }
    }

    @Test func decodesSlicesWithNonZeroStartIndex() throws {
        let buffer = try #require(Data(hex: "ffff e1416108 ff"))
        #expect(try HDSCodec.decode(buffer[2..<6]) == dict(("a", .int(0))))
    }
}

/// Deterministic pseudo-random generator for round-trip tests (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct HDSCodecRoundTripTests {
    /// Large strings/data and wide containers only at the top level, so a value stays small.
    static func randomValue(_ rng: inout SplitMix64, depth: Int) -> HDSValue {
        func pick<T>(_ options: [T]) -> T { options[Int.random(in: 0..<options.count, using: &rng)] }
        let kind = Int.random(in: 0..<(depth < 3 ? 11 : 9), using: &rng)
        switch kind {
        case 0: return .null
        case 1: return .bool(Bool.random(using: &rng))
        case 2:
            let bound = pick([40, 128, 32768, 1 << 31, 1 << 40, Int64.max])
            return .int(Int64.random(in: -bound...bound, using: &rng))
        case 3: return .float(Double.random(in: -1e9...1e9, using: &rng))
        case 4:
            let length = depth == 0 ? pick([0, 5, 32, 33, 300, 70000]) : pick([0, 5, 32, 33])
            let scalars = ["a", "é", "中", "🙂", "z"]
            return .string((0..<length).map { _ in pick(scalars) }.joined())
        case 5:
            let length = depth == 0 ? pick([0, 1, 32, 33, 256, 70000]) : pick([0, 1, 32, 33])
            return .data(Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        case 6: return .uuid(UUID())
        case 7: return .date(Date(timeIntervalSinceReferenceDate: Double(Int.random(in: 0...1_000_000_000, using: &rng)) / 8))
        case 8: return .int(Int64.random(in: -1...39, using: &rng))
        case 9:
            let count = depth == 0 ? pick([0, 3, 14, 15, 40]) : pick([0, 2, 14, 15])
            return .array((0..<count).map { _ in randomValue(&rng, depth: depth + 1) })
        default:
            let count = depth == 0 ? pick([0, 3, 14, 15, 40]) : pick([0, 2, 14, 15])
            return .dictionary(HDSDictionary((0..<count).map { ("key\($0)", randomValue(&rng, depth: depth + 1)) }))
        }
    }

    @Test func randomValuesRoundTrip() throws {
        var rng = SplitMix64(state: 0xC0FFEE)
        for _ in 0..<300 {
            let value = Self.randomValue(&rng, depth: 0)
            let encoded = try HDSCodec.encode(value)
            #expect(try HDSCodec.decode(encoded) == value)
        }
    }
}
