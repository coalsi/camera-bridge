import BridgeSupport
import Foundation
import HAPCore
import Testing
@testable import HAP

@Suite struct HAPTypeTests {
    @Test func permissionsJSONOrder() {
        let all: HAPPermissions = [.writeResponse, .events, .pairedRead, .pairedWrite, .timedWrite, .hidden, .additionalAuthorization]
        #expect(all.jsonStrings == ["pr", "pw", "ev", "aa", "tw", "hd", "wr"])
        #expect(CharacteristicType.setupDataStreamTransport.permissions.jsonStrings == ["pr", "pw", "wr"])
        #expect(CharacteristicType.recordingAudioActive.permissions.jsonStrings == ["pr", "pw", "ev", "tw"])
    }

    @Test func fullUUIDs() {
        #expect(CharacteristicType.motionDetected.fullUUID == "00000022-0000-1000-8000-0026BB765291")
        #expect(CharacteristicType.homeKitCameraActive.fullUUID == "0000021B-0000-1000-8000-0026BB765291")
        #expect(ServiceType.cameraOperatingMode.fullUUID == "0000021A-0000-1000-8000-0026BB765291")
        let custom = CharacteristicType(uuid: "e863f10a-079e-48ff-8f27-9c2605a29f52", name: "Custom", format: .uint32, permissions: [.pairedRead])
        #expect(custom.fullUUID == "E863F10A-079E-48FF-8F27-9C2605A29F52")
    }

    @Test func valueAccessors() {
        #expect(HAPValue.int(1).boolValue == true)
        #expect(HAPValue.bool(true).intValue == 1)
        #expect(HAPValue.uint(UInt64.max).intValue == nil)
        #expect(HAPValue.uint(5).doubleValue == 5)
        #expect(HAPValue.string("x").stringValue == "x")
        #expect(HAPValue.data(Data([1])).dataValue == Data([1]))
        #expect(HAPValue.null.boolValue == nil)
    }

    @Test func statusCodes() {
        #expect(HAPStatus.insufficientPrivileges.rawValue == -70401)
        #expect(HAPStatus.notAllowedInCurrentState.rawValue == -70412)
    }

    @Test func persistentStateDefaultsAndIdentityCodable() throws {
        let state = HAPPersistentState()
        #expect(state.configNumber == 1 && state.nextIID == 2 && state.nextAID == 2 && state.pairings.isEmpty)
        let identity = HAPIdentity.generate()
        #expect(!identity.setupCode.isTrivial && identity.setupID.count == 4 && identity.longTermKey.count == 32)
        let decoded = try JSONDecoder().decode(HAPIdentity.self, from: JSONEncoder().encode(identity))
        #expect(decoded.deviceID == identity.deviceID && decoded.setupCode == identity.setupCode && decoded.longTermKey == identity.longTermKey)
    }
}
