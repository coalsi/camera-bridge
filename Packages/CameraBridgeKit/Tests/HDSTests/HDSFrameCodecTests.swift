import BridgeSupport
import Foundation
import Testing
@testable import HDS

// Key and frame goldens come from Node 24's `crypto` (hkdfSync SHA-512, chacha20-poly1305), independent of the
// Swift implementation; payload/header goldens marked [HN-run] from HAP-NodeJS 2.1.6's DataStreamParser. The full
// golden set from the pinned HAP-NodeJS 2.2.3 (Fixtures/hds-frames.json) is checked in HDSFixtureGoldenTests.
enum FrameGoldens {
    static let sharedSecret = Data(0..<32)
    static let controllerKeySalt = Data(repeating: 0xC1, count: 32)
    static let accessoryKeySalt = Data(repeating: 0xA5, count: 32)
    static let accessoryToControllerKey = "31606663d7722e2f0114b6cc01213efa99d57284758a6b53c8120e86dca7adff"
    static let controllerToAccessoryKey = "2e6ae62fcd455e227f8cc7af47ca35bf828fa8b09bd6353f2fb337a8a5712c1d"
    /// `{protocol:"dataSend",event:"data"}` event with an empty message.
    static let eventPayload = "1ee24870726f746f636f6c486461746153656e64456576656e744464617461e0"
    static let eventFrameA2CCounter0 =
        "010000201d8455bb7277ce242591cf62e0e73fb2f07af86354d4187d5b6f00da92484445fa57b6c42bd9677b102f1d7864168919"
    static let eventFrameC2ACounter5 =
        "010000208d0c7fde1f5a3973a10167042a59406e0500d444a817900e8a42971af7ade4de4bad4b1ad2030c13ba4dcc5c8316ad45"
    /// Brief §3.8 golden: hello response header with id 1234 [HN-run].
    static let helloResponseHeader =
        "e44870726f746f636f6c47636f6e74726f6c48726573706f6e73654568656c6c6f42696433d20400000000000046737461747573330000000000000000"
    static let openRequestHeader = "e34870726f746f636f6c486461746153656e644772657175657374446f70656e426964330700000000000000"
    static let openRequestMessage =
        "e3467461726765744a636f6e74726f6c6c6572447479706552697063616d6572612e7265636f7264696e674873747265616d496409"
}

@Suite struct HDSFrameCodecTests {
    let keys = HDSFrameCodec.deriveKeys(sharedSecret: FrameGoldens.sharedSecret, controllerKeySalt: FrameGoldens.controllerKeySalt,
                                        accessoryKeySalt: FrameGoldens.accessoryKeySalt)

    @Test func keyDerivationMatchesNodeHKDF() {
        #expect(keys.accessoryToController.hexString == FrameGoldens.accessoryToControllerKey)
        #expect(keys.controllerToAccessory.hexString == FrameGoldens.controllerToAccessoryKey)
    }

    @Test func keyDerivationSaltOrderMatters() {
        let swapped = HDSFrameCodec.deriveKeys(sharedSecret: FrameGoldens.sharedSecret, controllerKeySalt: FrameGoldens.accessoryKeySalt,
                                               accessoryKeySalt: FrameGoldens.controllerKeySalt)
        #expect(swapped.accessoryToController != keys.accessoryToController)
        #expect(swapped.controllerToAccessory != keys.controllerToAccessory)
    }

    @Test func sealMatchesNodeChaChaPoly() throws {
        let payload = try #require(Data(hex: FrameGoldens.eventPayload))
        let a2c = try HDSFrameCodec.sealFrame(payload, key: keys.accessoryToController, counter: 0)
        #expect(a2c.hexString == FrameGoldens.eventFrameA2CCounter0)
        let c2a = try HDSFrameCodec.sealFrame(payload, key: keys.controllerToAccessory, counter: 5)
        #expect(c2a.hexString == FrameGoldens.eventFrameC2ACounter5)
    }

    @Test func frameLayoutIsTypeLength24CiphertextTag() throws {
        let payload = Data(repeating: 0x5A, count: 0x012345)
        let frame = try HDSFrameCodec.sealFrame(payload, key: keys.accessoryToController, counter: 9)
        #expect(Array(frame.prefix(4)) == [0x01, 0x01, 0x23, 0x45])
        #expect(frame.count == 4 + payload.count + 16)
        let opened = try HDSFrameCodec.openFrame(header: frame.prefix(4), body: frame.dropFirst(4), key: keys.accessoryToController, counter: 9)
        #expect(opened == payload)
    }

    @Test func openRejectsWrongCounterKeyHeaderOrTag() throws {
        let payload = try #require(Data(hex: FrameGoldens.eventPayload))
        let frame = try HDSFrameCodec.sealFrame(payload, key: keys.controllerToAccessory, counter: 5)
        let header = frame.prefix(4)
        let body = frame.dropFirst(4)
        #expect(try HDSFrameCodec.openFrame(header: header, body: body, key: keys.controllerToAccessory, counter: 5) == payload)
        #expect(throws: HDSFrameError.authenticationFailed) {
            try HDSFrameCodec.openFrame(header: header, body: body, key: keys.controllerToAccessory, counter: 4)
        }
        #expect(throws: HDSFrameError.authenticationFailed) {
            try HDSFrameCodec.openFrame(header: header, body: body, key: keys.accessoryToController, counter: 5)
        }
        var tamperedBody = Data(body)
        tamperedBody[3] ^= 0x01
        #expect(throws: HDSFrameError.authenticationFailed) {
            try HDSFrameCodec.openFrame(header: header, body: tamperedBody, key: keys.controllerToAccessory, counter: 5)
        }
        #expect(throws: HDSFrameError.unsupportedFrameType(0x02)) {
            try HDSFrameCodec.openFrame(header: Data([0x02]) + header.dropFirst(), body: body, key: keys.controllerToAccessory, counter: 5)
        }
        #expect(throws: HDSFrameError.lengthMismatch) {
            try HDSFrameCodec.openFrame(header: header, body: body.dropLast(), key: keys.controllerToAccessory, counter: 5)
        }
        #expect(throws: HDSFrameError.invalidFrameHeader) {
            try HDSFrameCodec.openFrame(header: header.prefix(3), body: body, key: keys.controllerToAccessory, counter: 5)
        }
        #expect(throws: HDSFrameError.payloadTooLarge(0x100000)) {
            try HDSFrameCodec.openFrame(header: Data([0x01, 0x10, 0x00, 0x00]), body: body, key: keys.controllerToAccessory, counter: 5)
        }
    }

    @Test func sealEnforcesMaximumPayloadAndKeyLength() throws {
        #expect(HDSFrameCodec.maximumPayloadLength == 0xFFFFF)
        let largest = try HDSFrameCodec.sealFrame(Data(count: 0xFFFFF), key: keys.accessoryToController, counter: 0)
        #expect(Array(largest.prefix(4)) == [0x01, 0x0F, 0xFF, 0xFF])
        #expect(throws: HDSFrameError.payloadTooLarge(0x100000)) {
            try HDSFrameCodec.sealFrame(Data(count: 0x100000), key: keys.accessoryToController, counter: 0)
        }
        #expect(throws: HDSFrameError.invalidKeyLength) { try HDSFrameCodec.sealFrame(Data([1]), key: Data(count: 16), counter: 0) }
        #expect(throws: HDSFrameError.invalidKeyLength) {
            try HDSFrameCodec.openFrame(header: Data([1, 0, 0, 0]), body: Data(count: 16), key: Data(count: 31), counter: 0)
        }
    }
}

@Suite struct HDSPayloadCodecTests {
    @Test func eventPayloadIsHeaderLengthHeaderMessage() throws {
        let message = HDSMessage(kind: .event, protocolName: "dataSend", topic: "data")
        #expect(try HDSFrameCodec.encodePayload(message).hexString == FrameGoldens.eventPayload)
        #expect(try HDSFrameCodec.decodePayload(try #require(Data(hex: FrameGoldens.eventPayload))) == message)
    }

    /// Brief §3.8: the hello response header is byte-exact, with `id` and `status` always written as int64.
    @Test func helloResponseHeaderGolden() throws {
        let response = HDSMessage(kind: .response(id: 1234, status: .success), protocolName: "control", topic: "hello")
        let payload = try HDSFrameCodec.encodePayload(response)
        let header = try #require(Data(hex: FrameGoldens.helloResponseHeader))
        #expect(payload.first == UInt8(header.count))
        #expect(payload.dropFirst().prefix(header.count) == header)
        #expect(payload.dropFirst(1 + header.count).hexString == "e0")
        #expect(try HDSFrameCodec.decodePayload(payload) == response)
    }

    @Test func requestPayloadMatchesHAPNodeJS() throws {
        let body = HDSDictionary([("target", .string("controller")), ("type", .string("ipcamera.recording")), ("streamId", .int(1))])
        let request = HDSMessage(kind: .request(id: 7), protocolName: "dataSend", topic: "open", body: body)
        let header = FrameGoldens.openRequestHeader
        let expected = String(format: "%02x", header.count / 2) + header + FrameGoldens.openRequestMessage
        let payload = try HDSFrameCodec.encodePayload(request)
        #expect(payload.hexString == expected)
        #expect(try HDSFrameCodec.decodePayload(payload) == request)
    }

    @Test func responsesCarryStatusAndLargeIDs() throws {
        for status in [HDSStatus.success, .outOfMemory, .timeout, .headerError, .payloadError, .missingProtocol, .protocolSpecificError] {
            let message = HDSMessage(kind: .response(id: 0x1_2345_6789, status: status), protocolName: "dataSend", topic: "open",
                                     body: HDSDictionary([("status", .int(HDSProtocolReason.busy.rawValue))]))
            #expect(try HDSFrameCodec.decodePayload(try HDSFrameCodec.encodePayload(message)) == message)
        }
    }

    @Test func decodeAcceptsCanonicalIntegersAndIgnoresTrailingBytes() throws {
        // A controller may write id/status in any integer form: {protocol:"control",response:"hello",id:9,status:0} {}.
        let header = try HDSCodec.encode(.dictionary(HDSDictionary([
            ("protocol", .string("control")), ("response", .string("hello")), ("id", .int(9)), ("status", .int(0)),
        ])))
        let payload = Data([UInt8(header.count)]) + header + Data([0xE0, 0x04, 0x04])
        #expect(try HDSFrameCodec.decodePayload(payload) ==
            HDSMessage(kind: .response(id: 9, status: .success), protocolName: "control", topic: "hello"))
        // An absent message part is an empty dictionary.
        #expect(try HDSFrameCodec.decodePayload(Data([UInt8(header.count)]) + header).body == HDSDictionary())
    }

    @Test func malformedPayloadsThrow() throws {
        func payload(_ header: HDSValue, message: Data = Data([0xE0])) throws -> Data {
            let encoded = try HDSCodec.encode(header)
            return Data([UInt8(encoded.count)]) + encoded + message
        }
        func header(_ pairs: (String, HDSValue)...) -> HDSValue { .dictionary(HDSDictionary(pairs)) }
        #expect(throws: HDSFrameError.truncatedPayload) { try HDSFrameCodec.decodePayload(Data()) }
        #expect(throws: HDSFrameError.truncatedPayload) { try HDSFrameCodec.decodePayload(Data([0x05, 0xE0])) }
        #expect(throws: HDSFrameError.invalidHeader("header")) { try HDSFrameCodec.decodePayload(try payload(.int(1))) }
        #expect(throws: HDSFrameError.invalidHeader("protocol")) {
            try HDSFrameCodec.decodePayload(try payload(header(("event", .string("data")))))
        }
        #expect(throws: HDSFrameError.invalidHeader("protocol")) {
            try HDSFrameCodec.decodePayload(try payload(header(("protocol", .int(1)), ("event", .string("data")))))
        }
        #expect(throws: HDSFrameError.invalidHeader("topic")) {
            try HDSFrameCodec.decodePayload(try payload(header(("protocol", .string("dataSend")))))
        }
        #expect(throws: HDSFrameError.invalidHeader("id")) {
            try HDSFrameCodec.decodePayload(try payload(header(("protocol", .string("dataSend")), ("request", .string("open")))))
        }
        #expect(throws: HDSFrameError.invalidHeader("status")) {
            try HDSFrameCodec.decodePayload(try payload(header(("protocol", .string("dataSend")), ("response", .string("open")), ("id", .int(1)))))
        }
        #expect(throws: HDSFrameError.invalidStatus(99)) {
            try HDSFrameCodec.decodePayload(try payload(header(("protocol", .string("dataSend")), ("response", .string("open")),
                                                                 ("id", .int(1)), ("status", .int(99)))))
        }
        #expect(throws: HDSFrameError.invalidMessage) {
            try HDSFrameCodec.decodePayload(try payload(header(("protocol", .string("a")), ("event", .string("b"))), message: Data([0x08])))
        }
        #expect(throws: HDSFrameError.codec(.invalidTag(0))) {
            try HDSFrameCodec.decodePayload(try payload(header(("protocol", .string("a")), ("event", .string("b"))), message: Data([0x00])))
        }
        #expect(throws: HDSFrameError.codec(.truncated)) { try HDSFrameCodec.decodePayload(Data([0x02, 0xE1, 0x41])) }
    }

    /// A header with repeated keys is read like HAP-NodeJS reads it: the last value of each key wins.
    @Test func repeatedHeaderKeysUseTheLastValue() throws {
        let header = try HDSCodec.encode(.dictionary(HDSDictionary([
            ("protocol", .string("control")), ("request", .string("hello")), ("id", .int(1)),
            ("protocol", .string("dataSend")), ("request", .string("open")), ("id", .int(2)),
        ])))
        let decoded = try HDSFrameCodec.decodePayload(Data([UInt8(header.count)]) + header + Data([0xE0]))
        #expect(decoded == HDSMessage(kind: .request(id: 2), protocolName: "dataSend", topic: "open"))
    }

    @Test func headerLongerThan255BytesIsRejected() throws {
        let message = HDSMessage(kind: .event, protocolName: String(repeating: "p", count: 250), topic: "data")
        #expect(throws: HDSFrameError.headerTooLong(273)) { try HDSFrameCodec.encodePayload(message) }
    }
}

@Suite struct HDSFrameAssemblerTests {
    let key = Data(repeating: 7, count: 32)

    @Test func reassemblesFramesSplitAcrossReadsAndSkipsUnknownTypes() throws {
        let first = try HDSFrameCodec.sealFrame(Data("one".utf8), key: key, counter: 0)
        let second = try HDSFrameCodec.sealFrame(Data("two".utf8), key: key, counter: 1)
        let unknownType = Data([0x02, 0x00, 0x00, 0x02, 0xAA, 0xBB]) + Data(repeating: 0, count: 16)
        let stream = first + unknownType + second
        var assembler = HDSFrameAssembler()
        var opened: [String] = []
        var counter: UInt64 = 0
        for byte in stream {
            assembler.append(Data([byte]))
            while let frame = try assembler.nextFrame() {
                opened.append(String(decoding: try HDSFrameCodec.openFrame(header: frame.header, body: frame.body, key: key, counter: counter),
                                     as: UTF8.self))
                counter += 1
            }
        }
        #expect(opened == ["one", "two"])
        #expect(assembler.bufferedByteCount == 0)

        var whole = HDSFrameAssembler()
        whole.append(stream + first.prefix(2))
        #expect(try whole.nextFrame() != nil)
        #expect(try whole.nextFrame() != nil)
        #expect(try whole.nextFrame() == nil)
        #expect(whole.bufferedByteCount == 2)
    }

    @Test func rejectsOversizedLengths() throws {
        var assembler = HDSFrameAssembler()
        assembler.append(Data([0x01, 0x10, 0x00, 0x00]))
        #expect(throws: HDSFrameError.payloadTooLarge(0x100000)) { try assembler.nextFrame() }
        var bounded = HDSFrameAssembler()
        bounded.append(Data([0x01, 0x00, 0x04, 0x01]))
        #expect(throws: HDSFrameError.payloadTooLarge(0x401)) { try bounded.nextFrame(maximumPayloadLength: 0x400) }
        var atBound = HDSFrameAssembler()
        atBound.append(Data([0x01, 0x00, 0x04, 0x00]) + Data(count: 0x400 + 16))
        #expect(try atBound.nextFrame(maximumPayloadLength: 0x400)?.body.count == 0x400 + 16)
    }

    /// 200,000 minimal frames in one read. Shifting the buffer once per frame would move ~400 GB (quadratic).
    @Test(.timeLimit(.minutes(1))) func manySmallFramesInOneReadAreSplitInLinearTime() throws {
        let frame = Data([0x01, 0x00, 0x00, 0x00]) + Data(count: 16)
        let count = 200_000
        var chunk = Data(capacity: frame.count * count + 3)
        for _ in 0..<count { chunk.append(frame) }
        chunk.append(frame.prefix(3))
        var assembler = HDSFrameAssembler()
        assembler.append(chunk)
        let start = ContinuousClock.now
        var frames = 0
        while try assembler.nextFrame() != nil { frames += 1 }
        #expect(frames == count)
        #expect(assembler.bufferedByteCount == 3)
        #expect(ContinuousClock.now - start < .seconds(10))
        assembler.append(frame.suffix(from: 3))
        #expect(try assembler.nextFrame() == HDSRawFrame(header: frame.prefix(4), body: Data(count: 16)))
        #expect(assembler.bufferedByteCount == 0)
        #expect(try assembler.nextFrame() == nil)
    }
}
