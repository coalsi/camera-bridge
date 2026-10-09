import Foundation
import Testing
@testable import CameraAdapters

@Test func probeResultCodable() throws {
    let result = CameraProbeResult(vendor: .hikvision, manufacturer: "Hikvision", model: "DS-2CD2387G2", serialNumber: "X", firmware: "V5.7",
                                   capabilities: CameraCapabilities(events: [.motion, .person], twoWayAudio: true, snapshotAPI: true))
    #expect(try JSONDecoder().decode(CameraProbeResult.self, from: JSONEncoder().encode(result)) == result)
}
