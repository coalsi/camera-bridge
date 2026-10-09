import Foundation
import Testing
@testable import HAPCore

@Suite struct SetupPayloadTests {
    @Test func setupURIGoldens() throws {
        let code = try #require(SetupCode("031-45-154"))
        #expect(SetupPayload.uri(code: code, setupID: "7OSX", category: .ipCamera) == "X-HM://00GW95DQA7OSX")
        #expect(SetupPayload.uri(code: code, setupID: "7OSX", category: .videoDoorbell) == "X-HM://00HVRPEPU7OSX")
    }

    @Test func setupHashGolden() throws {
        let deviceID = try #require(DeviceID("CC:22:3D:E3:CE:F3"))
        #expect(SetupPayload.setupHash(setupID: "7OSX", deviceID: deviceID) == "7JWHTA==")
        // Device IDs are uppercased before hashing.
        let lower = try #require(DeviceID("cc:22:3d:e3:ce:f3"))
        #expect(SetupPayload.setupHash(setupID: "7OSX", deviceID: lower) == "7JWHTA==")
    }

    @Test func randomSetupIDIsFourUppercaseAlphanumerics() {
        for _ in 0..<200 {
            let id = SetupPayload.randomSetupID()
            #expect(id.count == 4)
            #expect(id.allSatisfy { ("0"..."9").contains($0) || ("A"..."Z").contains($0) })
        }
    }

    @Test func uriIsAlwaysNinePayloadCharsPlusSetupID() throws {
        let code = try #require(SetupCode("000-00-001"))
        let uri = SetupPayload.uri(code: code, setupID: "ABCD", category: .bridge)
        #expect(uri.hasPrefix("X-HM://"))
        #expect(uri.count == 7 + 9 + 4)
    }
}

@Suite struct SetupCodeTests {
    @Test func acceptsBothForms() throws {
        let a = try #require(SetupCode("031-45-154"))
        let b = try #require(SetupCode("03145154"))
        #expect(a == b)
        #expect(a.digits == "03145154")
        #expect(a.formatted == "031-45-154")
        #expect(a.description == "031-45-154")
    }

    @Test func rejectsMalformed() {
        for bad in ["", "1234567", "123456789", "12a-45-678", "1234-5678", "123-456-78", " 12345678", "１２３４５６７８"] {
            #expect(SetupCode(bad) == nil, "\(bad)")
        }
    }

    @Test func detectsTrivialCodes() throws {
        for trivial in ["00000000", "11111111", "99999999", "12345678", "87654321", "01234567", "23456789", "98765432", "76543210"] {
            #expect(try #require(SetupCode(trivial)).isTrivial, "\(trivial)")
        }
        for fine in ["03145154", "12345679", "10293847"] {
            #expect(try #require(SetupCode(fine)).isTrivial == false, "\(fine)")
        }
    }

    @Test func randomCodesAreNeverTrivialAndWellFormed() {
        for _ in 0..<2_000 {
            let code = SetupCode.random()
            #expect(!code.isTrivial)
            #expect(code.digits.count == 8 && code.digits.allSatisfy(\.isASCII) && code.digits.allSatisfy(\.isNumber))
            #expect(SetupCode(code.formatted) == code)
        }
    }

    @Test func codableUsesFormattedString() throws {
        let code = try #require(SetupCode("03145154"))
        let json = try JSONEncoder().encode(code)
        #expect(String(decoding: json, as: UTF8.self) == "\"031-45-154\"")
        #expect(try JSONDecoder().decode(SetupCode.self, from: json) == code)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SetupCode.self, from: Data("\"nope\"".utf8)) }
    }
}

@Suite struct DeviceIDTests {
    @Test func parsesAndNormalizes() throws {
        let id = try #require(DeviceID("cc:22:3d:e3:ce:f3"))
        #expect(id.description == "CC:22:3D:E3:CE:F3")
        #expect(DeviceID("CC:22:3D:E3:CE") == nil)
        #expect(DeviceID("CC-22-3D-E3-CE-F3") == nil)
        #expect(DeviceID("GG:22:3D:E3:CE:F3") == nil)
        #expect(DeviceID("C:22:3D:E3:CE:F3") == nil)
    }

    @Test func randomIsValidAndDistinct() throws {
        let a = DeviceID.random(), b = DeviceID.random()
        #expect(DeviceID(a.description) == a)
        #expect(a != b)
    }

    @Test func codableRoundTrip() throws {
        let id = try #require(DeviceID("CC:22:3D:E3:CE:F3"))
        let json = try JSONEncoder().encode(id)
        #expect(String(decoding: json, as: UTF8.self) == "\"CC:22:3D:E3:CE:F3\"")
        #expect(try JSONDecoder().decode(DeviceID.self, from: json) == id)
    }

    @Test func categoriesHaveHAPValues() {
        #expect(AccessoryCategory.bridge.rawValue == 2)
        #expect(AccessoryCategory.sensor.rawValue == 10)
        #expect(AccessoryCategory.ipCamera.rawValue == 17)
        #expect(AccessoryCategory.videoDoorbell.rawValue == 18)
    }
}
