#if os(macOS)
import BridgeSupport
import CameraAdapters
import Foundation
import HAP
import HAPCore
import PlatformApple
import Testing
import TestSupport
@testable import BridgeEngine

extension EndToEndTests {
    /// Review findings (W4): the engine's "Reset pairing" recovery path (cameras running or not, and the sensors bridge)
    /// and the sensors bridge on the wire (its own pairing, bridged aids, sensor events, unreachable cameras) had no
    /// engine-level test: removing either wiring passed every suite.
    @Suite struct PairingAndSensors {
        static func webhook(_ engine: BridgeEngine, camera: UUID, event: String) async throws -> Int? {
            let port = try #require(await engine.webhook?.boundPort)
            var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/cameras/\(camera.uuidString)/\(event)")))
            request.httpMethod = "POST"
            request.setValue("Bearer \(await engine.settings.webhookToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        }

        @MainActor @Test(.timeLimit(.minutes(2)))
        func resetPairingUnpairsRunningAndStoppedCamerasAndTheSensorsBridge() async throws {
            let advertiser = RecordingAdvertiser()
            let fixture = try await EndToEndEngine(tuning: .smallDemo, advertiser: advertiser)
            let engine = fixture.engine
            var camera = EndToEndEngine.demoCamera(name: "Porch")
            try await engine.addCamera(camera, password: nil)
            await engine.start()

            // A running camera: the controller loses its pairing, the accessory announces "unpaired" and pairs afresh.
            let status = try await fixture.waitUntilServing(camera.id)
            let port = try #require(status.hapPort)
            let identity = HAPControllerIdentity.generate()
            let controller = try await HAPTestController.connect(port: port, identity: identity)
            let pairing = try await controller.pairSetup(setupCode: status.setupCode)
            try await controller.pairVerify()
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.isPaired == true })
            #expect(await eventually(timeout: .seconds(5)) { advertiser.statusFlags(port: port).last == "0" }, "\(advertiser.statusFlags(port: port))")
            try await engine.resetPairing(cameraID: camera.id)
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.isPaired == false })
            #expect(await eventually(timeout: .seconds(5)) { advertiser.statusFlags(port: port).last == "1" }, "\(advertiser.statusFlags(port: port))")
            await #expect(throws: (any Error).self) {
                let stale = try await HAPTestController.connectVerified(host: "127.0.0.1", port: port, transport: AppleNetworkTransport(),
                                                                        identity: identity, pairing: pairing)
                await stale.close()
            }
            await controller.close()
            // Review finding (W4 round 3): the reset kept the identity, so the old setup code (shared, or seen on screen)
            // paired again although the app promised a new one. The camera is a new accessory with a new code now.
            let reset = try await fixture.waitUntilServing(camera.id)
            #expect(reset.setupCode != status.setupCode)
            #expect(reset.setupURI != status.setupURI)
            await #expect(throws: (any Error).self, "the old setup code pairs nothing") {
                let old = try await HAPTestController.paired(port: port, setupCode: status.setupCode)
                await old.close()
            }
            let again = try await HAPTestController.paired(port: port, setupCode: reset.setupCode)
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.isPaired == true })
            await again.close()

            // A disabled camera (no runtime): its HAP store forgets the pairing, and it pairs afresh once enabled.
            camera = try #require(engine.configurations.first)
            camera.isEnabled = false
            try await engine.updateCamera(camera, password: nil)
            #expect(await eventually(timeout: .seconds(10)) { fixture.status(camera.id)?.connection == .disabled && fixture.status(camera.id)?.isPaired == true })
            let disabledCode = try #require(fixture.status(camera.id)?.setupCode)
            try await engine.resetPairing(cameraID: camera.id)
            #expect(fixture.status(camera.id)?.isPaired == false)
            #expect(fixture.status(camera.id)?.setupCode != disabledCode, "a stopped camera gets a new code too")
            camera.isEnabled = true
            try await engine.updateCamera(camera, password: nil)
            let enabled = try await fixture.waitUntilServing(camera.id)
            #expect(!enabled.isPaired)
            let fresh = try await HAPTestController.paired(port: try #require(enabled.hapPort), setupCode: enabled.setupCode)
            await fresh.close()

            // The sensors bridge.
            let bridgeStatus = try #require(engine.sensorsBridge)
            let bridgePort = try #require(await engine.bridge?.server.port)
            let bridgeController = try await HAPTestController.paired(port: bridgePort, setupCode: bridgeStatus.setupCode)
            #expect(await eventually(timeout: .seconds(10)) { engine.sensorsBridge?.isPaired == true })
            try await engine.resetSensorsBridgePairing()
            #expect(await eventually(timeout: .seconds(10)) { engine.sensorsBridge?.isPaired == false })
            let resetBridge = try #require(engine.sensorsBridge)
            #expect(resetBridge.setupCode != bridgeStatus.setupCode)
            let resetPort = try #require(await engine.bridge?.server.port)   // port 0 here: the restarted bridge has another
            #expect(await eventually(timeout: .seconds(5)) { advertiser.statusFlags(port: resetPort).last == "1" })
            await #expect(throws: (any Error).self, "the bridge's old setup code pairs nothing") {
                let old = try await HAPTestController.paired(port: resetPort, setupCode: bridgeStatus.setupCode)
                await old.close()
            }
            let bridgeAgain = try await HAPTestController.paired(port: resetPort, setupCode: resetBridge.setupCode)
            #expect(await eventually(timeout: .seconds(10)) { engine.sensorsBridge?.isPaired == true })
            await bridgeAgain.close()
            await bridgeController.close()
            await fixture.tearDown()
        }

        @MainActor @Test(.timeLimit(.minutes(2)))
        func theSensorsBridgePairsAndReportsDerivedSensors() async throws {
            let fixture = try await EndToEndEngine(tuning: .smallDemo) { $0.webhookEnabled = true }
            let engine = fixture.engine
            var garden = EndToEndEngine.demoCamera(name: "Garden")
            garden.motionSource = .webhook
            garden.sensors.person = true
            // A camera that never answers (nothing listens on its RTSP port): its bridged sensor is unreachable.
            var shed = CameraConfiguration(name: "Shed", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "127.0.0.1", rtspPort: 9),
                                           username: "")
            shed.mainStreamURL = URL(string: "rtsp://127.0.0.1:9/stream")
            shed.sensors.person = true
            try await engine.addCamera(garden, password: nil)
            try await engine.addCamera(shed, password: nil)
            await engine.start()
            _ = try await fixture.waitUntilServing(garden.id)
            #expect(await eventually(timeout: .seconds(15)) {
                if case .offline = fixture.status(shed.id)?.connection { true } else { false }
            })

            let bridgeStatus = try #require(engine.sensorsBridge)
            let bridgePort = try #require(await engine.bridge?.server.port)
            let controller = try await HAPTestController.paired(port: bridgePort, setupCode: bridgeStatus.setupCode)
            let database = try await controller.accessories()
            #expect(database.accessories.map(\.aid).sorted() == [1, 2, 3], "the bridge plus one occupancy sensor per camera")
            let occupancy = database.accessories.compactMap { accessory -> (name: String?, id: HAPCharacteristicID)? in
                guard let characteristic = accessory.characteristic(.occupancyDetected) else { return nil }
                return (accessory.information(.name), characteristic.id)
            }
            let gardenPerson = try #require(occupancy.first { $0.name?.hasPrefix("Garden") == true }?.id)
            let shedPerson = try #require(occupancy.first { $0.name?.hasPrefix("Shed") == true }?.id)

            // A person through the webhook reaches the controller as an OccupancyDetected event.
            try await controller.subscribe([gardenPerson])
            #expect(try await Self.webhook(engine, camera: garden.id, event: "person") == 204)
            #expect(try await controller.nextEvent(for: gardenPerson, timeout: .seconds(5)).value == .int(1))

            // The offline camera's sensor answers "No Response" (-70402).
            let reads = try await controller.read([shedPerson, gardenPerson])
            #expect(reads.first { $0.id == shedPerson }?.status == HAPStatus.serviceCommunicationFailure.rawValue)
            #expect(reads.first { $0.id == gardenPerson }?.status == 0)
            await controller.close()
            await fixture.tearDown()
        }
    }
}
#endif
