import BridgeSupport
import Foundation
import Testing
@testable import HDS

// Goldens generated from HAP-NodeJS 2.2.3, the pinned Interop version (Interop/node/goldens.mjs hds-codec / hds-frames,
// plan task W1-9): Fixtures/hds-codec.json and Fixtures/hds-frames.json, read via #filePath (the target excludes
// Fixtures from its sources). Each file's `notes` say what HDSCodec / HDSFrameCodec must do with every case; the
// inline goldens in HDSCodecTests / HDSFrameCodecTests stay as hand-checked spot cases.

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")
}

private func bytes(_ hex: String) throws -> Data { try #require(Data(hex: hex), "bad hex \(hex)") }

/// The fixtures' value JSON: `{type, value}`; ints are decimal strings (full int64), floats float64 numbers, data hex,
/// uuids uppercase, dates seconds since 2001-01-01T00:00:00Z, dictionaries ordered `[{key, value}]` pairs.
struct HDSFixtureValue: Decodable, Sendable {
    let value: HDSValue

    private enum CodingKeys: String, CodingKey { case type, value }

    private struct Pair: Decodable {
        var key: String
        var value: HDSFixtureValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        func corrupt(_ what: String) -> DecodingError {
            .dataCorruptedError(forKey: .value, in: container, debugDescription: "\(type): \(what)")
        }
        switch type {
        case "null":
            value = .null
        case "bool":
            value = .bool(try container.decode(Bool.self, forKey: .value))
        case "int":
            let text = try container.decode(String.self, forKey: .value)
            guard let number = Int64(text) else { throw corrupt(text) }
            value = .int(number)
        case "float":
            value = .float(try container.decode(Double.self, forKey: .value))
        case "string":
            value = .string(try container.decode(String.self, forKey: .value))
        case "data":
            let text = try container.decode(String.self, forKey: .value)
            guard let data = Data(hex: text) else { throw corrupt(text) }
            value = .data(data)
        case "uuid":
            let text = try container.decode(String.self, forKey: .value)
            guard let uuid = UUID(uuidString: text) else { throw corrupt(text) }
            value = .uuid(uuid)
        case "date":
            value = .date(Date(timeIntervalSinceReferenceDate: try container.decode(Double.self, forKey: .value)))
        case "array":
            value = .array(try container.decode([HDSFixtureValue].self, forKey: .value).map(\.value))
        case "dictionary":
            value = .dictionary(HDSDictionary(try container.decode([Pair].self, forKey: .value).map { ($0.key, $0.value.value) }))
        default:
            throw corrupt("unknown type")
        }
    }
}

/// The fixture `type` of a value.
private func typeName(_ value: HDSValue) -> String {
    switch value {
    case .null: "null"
    case .bool: "bool"
    case .int: "int"
    case .float: "float"
    case .string: "string"
    case .data: "data"
    case .uuid: "uuid"
    case .date: "date"
    case .array: "array"
    case .dictionary: "dictionary"
    }
}

// MARK: - hds-codec.json

/// `values` and `decodeOnly` cases (a `decodeOnly` case's bytes are never what the canonical encoder writes).
struct HDSCodecCase: Decodable, Sendable, CustomTestStringConvertible {
    var name: String
    var value: HDSFixtureValue
    var encoded: String
    var testDescription: String { name }
}

struct HDSCodecInvalidCase: Decodable, Sendable, CustomTestStringConvertible {
    var name: String
    var encoded: String
    var testDescription: String { name }
}

private struct HDSCodecFixture: Decodable {
    var values: [HDSCodecCase]
    var decodeOnly: [HDSCodecCase]
    var invalid: [HDSCodecInvalidCase]

    static func load() throws -> HDSCodecFixture {
        try JSONDecoder().decode(HDSCodecFixture.self, from: Data(contentsOf: fixtureURL("hds-codec.json")))
    }

    static let shared = try? load()
}

@Suite struct HDSCodecFixtureTests {
    @Test func fixtureIsPresent() throws {
        let fixture = try HDSCodecFixture.load()   // not `shared`, so a decoding error is reported
        #expect(fixture.values.count >= 69)
        #expect(fixture.decodeOnly.count >= 21)
        #expect(fixture.invalid.count >= 11)
        // Every value type and the brief §3.8 cases where HAP-NodeJS is wrong are among them.
        let types = Set(fixture.values.map { typeName($0.value.value) })
        #expect(types == ["null", "bool", "int", "float", "string", "data", "uuid", "date", "array", "dictionary"])
        #expect(fixture.values.contains { $0.encoded == "2f" && $0.value.value == .int(39) })
        #expect(fixture.values.contains { $0.encoded == "70" && $0.value.value == .data(Data()) })
        #expect(fixture.decodeOnly.contains { $0.encoded.contains("a0") && $0.name.contains("back-reference") })
    }

    @Test(arguments: HDSCodecFixture.shared?.values ?? [])
    func encodesAndDecodesTheCanonicalForm(_ testCase: HDSCodecCase) throws {
        let encoded = try bytes(testCase.encoded)
        #expect(try HDSCodec.encode(testCase.value.value).hexString == testCase.encoded)
        #expect(try HDSCodec.decode(encoded) == testCase.value.value)
    }

    @Test(arguments: HDSCodecFixture.shared?.decodeOnly ?? [])
    func decodesNonCanonicalForms(_ testCase: HDSCodecCase) throws {
        #expect(try HDSCodec.decode(try bytes(testCase.encoded)) == testCase.value.value)
        // The canonical encoder writes something else, which still reads back as the same value.
        let canonical = try HDSCodec.encode(testCase.value.value)
        #expect(canonical.hexString != testCase.encoded)
        #expect(try HDSCodec.decode(canonical) == testCase.value.value)
    }

    @Test(arguments: HDSCodecFixture.shared?.invalid ?? [])
    func rejectsInvalidEncodings(_ testCase: HDSCodecInvalidCase) throws {
        let encoded = try bytes(testCase.encoded)
        #expect(throws: HDSCodecError.self) { try HDSCodec.decode(encoded) }
    }
}

// MARK: - hds-frames.json

struct HDSFrameMessageCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Message: Decodable, Sendable {
        var kind: String
        var `protocol`: String
        var topic: String
        var id: Int64?
        var status: Int64?
        var body: HDSFixtureValue
    }

    var name: String
    var direction: String
    var message: Message
    var header: String
    var payload: String
    var testDescription: String { name }

    func hdsMessage() throws -> HDSMessage {
        guard case .dictionary(let body) = message.body.value else { throw FixtureCaseError("\(name): body is not a dictionary") }
        let kind: HDSMessage.Kind
        switch message.kind {
        case "event":
            kind = .event
        case "request":
            kind = .request(id: try #require(message.id))
        case "response":
            let status = try #require(message.status)
            kind = .response(id: try #require(message.id), status: try #require(HDSStatus(rawValue: status), "status \(status)"))
        default:
            throw FixtureCaseError("\(name): unknown kind \(message.kind)")
        }
        return HDSMessage(kind: kind, protocolName: message.protocol, topic: message.topic, body: body)
    }
}

struct HDSFrameKeyCase: Decodable, Sendable, CustomTestStringConvertible {
    var name: String
    var sharedSecret: String
    var controllerKeySalt: String
    var accessoryKeySalt: String
    var accessoryToControllerKey: String
    var controllerToAccessoryKey: String
    var testDescription: String { name }
}

struct HDSSealedFrameCase: Decodable, Sendable, CustomTestStringConvertible {
    var name: String
    /// Name of the `messages` case whose payload this frame carries.
    var message: String
    var direction: String
    /// Name of the `keys` case whose key for `direction` seals it.
    var keySet: String
    var key: String
    var counter: UInt64
    var payload: String
    var frame: String
    var testDescription: String { name }
}

struct FixtureCaseError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private struct HDSFramesFixture: Decodable {
    var messages: [HDSFrameMessageCase]
    var keys: [HDSFrameKeyCase]
    var frames: [HDSSealedFrameCase]

    static func load() throws -> HDSFramesFixture {
        try JSONDecoder().decode(HDSFramesFixture.self, from: Data(contentsOf: fixtureURL("hds-frames.json")))
    }

    static let shared = try? load()
}

@Suite struct HDSFrameCodecFixtureTests {
    @Test func fixtureIsPresent() throws {
        let fixture = try HDSFramesFixture.load()   // not `shared`, so a decoding error is reported
        #expect(fixture.messages.count >= 10)
        #expect(fixture.keys.count >= 2)
        #expect(fixture.frames.count >= 6)
        // The brief §3.8 hello-response header golden (also inline in HDSFrameCodecTests) is among them.
        #expect(fixture.messages.contains { $0.header == FrameGoldens.helloResponseHeader })
        #expect(Set(fixture.messages.map(\.message.kind)) == ["event", "request", "response"])
        #expect(Set(fixture.frames.map(\.direction)) == ["accessoryToController", "controllerToAccessory"])
        #expect(fixture.frames.contains { $0.counter > UInt64(UInt32.max) })
    }

    @Test(arguments: HDSFramesFixture.shared?.messages ?? [])
    func payloadMatchesHAPNodeJS(_ testCase: HDSFrameMessageCase) throws {
        let message = try testCase.hdsMessage()
        let payload = try bytes(testCase.payload)
        #expect(try HDSFrameCodec.encodePayload(message).hexString == testCase.payload)
        #expect(try HDSFrameCodec.decodePayload(payload) == message)
        // [header length u8][header][body], the body in its canonical form.
        let header = try bytes(testCase.header)
        let body = try HDSCodec.encode(.dictionary(message.body))
        #expect(payload == Data([UInt8(header.count)]) + header + body)
    }

    @Test(arguments: HDSFramesFixture.shared?.keys ?? [])
    func keysMatchHAPNodeJS(_ testCase: HDSFrameKeyCase) throws {
        let keys = HDSFrameCodec.deriveKeys(sharedSecret: try bytes(testCase.sharedSecret),
                                            controllerKeySalt: try bytes(testCase.controllerKeySalt),
                                            accessoryKeySalt: try bytes(testCase.accessoryKeySalt))
        #expect(keys.accessoryToController.hexString == testCase.accessoryToControllerKey)
        #expect(keys.controllerToAccessory.hexString == testCase.controllerToAccessoryKey)
    }

    @Test(arguments: HDSFramesFixture.shared?.frames ?? [])
    func sealedFrameMatchesHAPNodeJS(_ testCase: HDSSealedFrameCase) throws {
        let fixture = try #require(HDSFramesFixture.shared)
        // The case is consistent with the rest of the file: its key is its key set's key for its direction, and its
        // payload is its message's payload.
        let keySet = try #require(fixture.keys.first { $0.name == testCase.keySet }, "key set \(testCase.keySet)")
        switch testCase.direction {
        case "accessoryToController": #expect(testCase.key == keySet.accessoryToControllerKey)
        case "controllerToAccessory": #expect(testCase.key == keySet.controllerToAccessoryKey)
        default: Issue.record("unknown direction \(testCase.direction)")
        }
        let message = try #require(fixture.messages.first { $0.name == testCase.message }, "message \(testCase.message)")
        #expect(message.payload == testCase.payload)
        #expect(message.direction == testCase.direction)

        let key = try bytes(testCase.key)
        let payload = try bytes(testCase.payload)
        #expect(try HDSFrameCodec.sealFrame(payload, key: key, counter: testCase.counter).hexString == testCase.frame)
        let frame = Array(try bytes(testCase.frame))
        let opened = try HDSFrameCodec.openFrame(header: Data(frame[..<4]), body: Data(frame[4...]), key: key, counter: testCase.counter)
        #expect(opened == payload)
    }
}
