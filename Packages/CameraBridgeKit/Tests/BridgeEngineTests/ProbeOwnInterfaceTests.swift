#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// `probeCamera` for a camera added as ONVIF: the maker's own interface (Hikvision's ISAPI, Reolink's or Dahua's API) is used when it
/// answers with the same credentials, keeping the manufacturer and model it gave. Drivers and the check are fakes.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ProbeOwnInterfaceTests {
    final class Driver: CameraDriver, Sendable {
        let vendor: CameraVendor
        let result: Result<CameraProbeResult, any Error & Sendable>
        init(_ vendor: CameraVendor, manufacturer: String, model: String, failing error: (any Error & Sendable)? = nil) {
            self.vendor = vendor
            result = error.map { .failure($0) } ?? .success(CameraProbeResult(vendor: vendor, manufacturer: manufacturer, model: model, serialNumber: "SN", firmware: "1"))
        }
        func probe() async throws -> CameraProbeResult { try result.get() }
        func makeEventSource() -> (any CameraEventSource)? { nil }
        func snapshot() async throws -> Data? { nil }
        func makeTalkbackSink() -> (any TalkbackSink)? { nil }
        func close() async {}
    }

    private let asked = Box(0)

    private func engine(directory: TemporaryDirectory, onvif: Driver, own: Driver, check: OwnInterfaceCheck) -> BridgeEngine {
        var tuning = EngineTuning.testing
        tuning.driverFactory = { camera, _, _ in camera.vendor == .onvif ? onvif : own }
        tuning.findONVIFPort = { _ in nil }
        let asked = asked
        tuning.findOwnInterface = { _, _ in
            asked.update { $0 += 1 }
            return check
        }
        return BridgeEngine(environment: BridgeEnvironment(dataDirectory: directory.url,
                                                           platform: PlatformServices(transport: ScriptedConnectTransport([], then: .connectionRefused),
                                                                                      advertiser: NullServiceAdvertiser(), secrets: InMemorySecretStore(),
                                                                                      networkChanges: NullNetworkChangeMonitor(), power: NullPowerManager()),
                                                           codecs: AppleMediaCodecs(), loopbackOnly: true, advertise: false),
                            tuning: tuning)
    }

    private func probe(_ engine: BridgeEngine) async throws -> CameraProbeResult {
        try await engine.probeCamera(vendor: .onvif, endpoint: CameraEndpoint(host: "192.168.77.30"), username: "admin", password: "secret",
                                     mainStreamURL: nil, subStreamURL: nil)
    }

    private let onvif = Driver(.onvif, manufacturer: "ANNKE", model: "I91ET")
    private let hikvision = Driver(.hikvision, manufacturer: "Hikvision", model: "")

    @Test func anONVIFCameraThatAnswersISAPIBecomesHikvisionWithItsMaker() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let result = try await probe(engine(directory: directory, onvif: onvif, own: hikvision, check: .found(OwnInterface(vendor: .hikvision, model: "I91ET"))))
        #expect(result.vendor == .hikvision)
        #expect(result.manufacturer == "ANNKE")
        #expect(result.model == "I91ET")
        #expect(result.usedOwnInterface)
    }

    @Test func aCameraWithoutAnInterfaceOfItsOwnStaysONVIF() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let result = try await probe(engine(directory: directory, onvif: onvif, own: hikvision, check: .none))
        #expect(result.vendor == .onvif)
        #expect(!result.usedOwnInterface)
    }

    @Test func aWrongPasswordChangesNothingAndAsksNoOtherInterface() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let refused = Driver(.onvif, manufacturer: "", model: "", failing: CameraAdapterError.unauthorized)
        let engine = engine(directory: directory, onvif: refused, own: hikvision, check: .found(OwnInterface(vendor: .hikvision)))
        await #expect(throws: CameraAdapterError.self) { try await probe(engine) }
        #expect(asked.value == 0)
    }

    @Test func aCameraWhoseONVIFIsOffIsStillFoundThroughItsOwnInterface() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let off = Driver(.onvif, manufacturer: "", model: "", failing: CameraAdapterError.httpStatus(404))
        let result = try await probe(engine(directory: directory, onvif: off, own: Driver(.hikvision, manufacturer: "Hikvision", model: "DS-2CD2143"),
                                            check: .found(OwnInterface(vendor: .hikvision))))
        #expect(result.vendor == .hikvision)
        #expect(result.model == "DS-2CD2143")
    }

    @Test func aRefusalAtTheMakersInterfaceLeavesTheONVIFAnswer() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let result = try await probe(engine(directory: directory, onvif: onvif, own: hikvision, check: .rejected))
        #expect(result.vendor == .onvif)
    }
}
#endif
