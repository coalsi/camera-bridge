// A loopback fake camera (the platform transport) and a real engine: macOS.
#if canImport(Darwin)
import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

/// "Change it by hand" as the page gets it from the real engine (`EngineBackend`, not the fake backend): the setup's preview and run, the
/// security check and each camera's status carry it; a restore's report does not (its help would say how to make the change Restore is
/// undoing); the engine's own reports and statuses carry none. And the camera resource says whether the Internet guard watches the camera
/// (`internetWatched`, the engine's verdict). Never a real camera.
@Suite(.timeLimit(.minutes(1))) struct CameraManualHelpBackendTests {
    /// A camera that answers every HTTP request "404 Not Found": it shows none of the settings the setup and the check read.
    final class NothingCamera: Sendable {
        let port: UInt16
        private let listener: any TCPListener
        private let task = Mutex<Task<Void, Never>?>(nil)

        init() async throws {
            listener = try await PlatformNetworkTransport().listen(port: 0, loopbackOnly: true)
            port = listener.port
            let task = Task { [self] in
                for await connection in listener.connections { Task { await serve(connection) } }
            }
            self.task.withLock { $0 = task }
        }

        func stop() {
            listener.close()
            task.withLock { $0?.cancel() }
        }

        private func serve(_ connection: any TCPConnection) async {
            var parser = HTTPRequestParser(maxBodySize: 1 << 20)
            defer { connection.close() }
            while true {
                guard let data = try? await connection.receive(maximumLength: 65_536), let requests = try? parser.feed(data) else { return }
                for _ in requests {
                    let wire = HTTPSerializer.response(status: 404, headers: HTTPHeaders([("Content-Type", "text/plain")]), body: Data("not found".utf8))
                    guard (try? await connection.send(wire)) != nil else { return }
                }
            }
        }
    }

    @MainActor @Test func theBackendAddsTheHelpToThePreviewTheRunTheCheckAndTheStatusButNotToARestore() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fake = try await NothingCamera()
        defer { fake.stop() }
        var camera = CameraConfiguration(name: "Gate", kind: .camera, vendor: .hikvision,
                                         endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(fake.port), onvifPort: Int(fake.port)), username: "admin")
        camera.isEnabled = false   // no stream: only the settings are read
        // An earlier run turned its UPnP off: Restore tries to turn it back on, and the camera no longer shows it.
        camera.setupBackup = CameraSetupBackup(version: 1, created: Date(), upnp: CameraFeatureBackup(path: "/ISAPI/System/Network/UPnP", enabled: true))
        camera.setupState = CameraSetupState(started: Date(), applied: Date(), steps: [.init(id: .upnp, status: .done)])
        try ConfigurationStore(directory: directory.url).save(BridgeConfiguration(cameras: [camera]))
        let engine = BridgeEngine(environment: .testing(directory: directory.url))
        let backend = EngineBackend(engine: engine)
        func couldNotBeDone(_ step: CameraSetupStep) -> Bool { step.status == .notSupported || step.status == .refused }

        let preview = try await backend.cameraSetupPreview(cameraID: camera.id)
        #expect(preview.steps.contains(where: couldNotBeDone))
        #expect(preview.steps.allSatisfy { couldNotBeDone($0) == ($0.manualHelp != nil) }, "\(preview.steps.map { ($0.id, $0.status, $0.manualHelp != nil) })")
        #expect(try await engine.cameraSetupPreview(cameraID: camera.id).steps.allSatisfy { $0.manualHelp == nil }, "the engine's own report has none")

        let applied = try await backend.applyCameraSetup(cameraID: camera.id)
        #expect(applied.steps.contains { couldNotBeDone($0) && $0.manualHelp != nil })

        let restored = try await backend.restoreCameraSetup(cameraID: camera.id)
        #expect(restored.steps.contains { $0.id == .upnp && $0.status == .refused }, "\(restored.steps)")
        #expect(restored.steps.allSatisfy { $0.manualHelp == nil }, "a restore says nothing of how to make the change it undoes")

        let security = try await backend.checkCameraSecurity(cameraID: camera.id)
        #expect(security.findings.contains { $0.manualHelp != nil }, "\(security.findings.map { ($0.feature, $0.state, $0.canChange) })")
        let overview = await backend.overview()
        #expect(overview.cameras.first { $0.id == camera.id }?.security?.findings.contains { $0.manualHelp != nil } == true, "the status the page gets")
        #expect(engine.cameras.first { $0.id == camera.id }?.security?.findings.allSatisfy { $0.manualHelp == nil } == true,
                "the engine's own status has none")
    }

    /// The camera resource says whether the Internet guard watches the camera, as the engine decides it (`BridgeEngine.internetWatchDone`):
    /// the setup's watch, a reading's watch on a camera never set up, and none once a reading found it asking other servers.
    @Test func theCameraResourceCarriesTheEnginesVerdict() throws {
        func watched(_ camera: CameraConfiguration) throws -> Bool? {
            let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.iso.encode(CameraResource(configuration: camera, status: nil)))
                as? [String: Any])
            return object["internetWatched"] as? Bool
        }
        var camera = CameraConfiguration(name: "Doorbell", kind: .doorbell, vendor: .reolink, endpoint: CameraEndpoint(host: "192.168.77.31"), username: "admin")
        #expect(try watched(camera) == false, "always there")
        camera.dnsWatch = CameraDNSWatch(server: "192.168.77.2")
        #expect(try watched(camera) == true, "pointed at the bridge by hand")
        let started = Date(timeIntervalSince1970: 1_792_224_000)
        camera.setupState = CameraSetupState(started: started, applied: started, steps: [.init(id: .internetWatch, status: .done)])
        camera.dnsWatch = CameraDNSWatch(server: nil, setupStarted: started)
        #expect(try watched(camera) == false, "a reading since found it asking other servers")
        camera.dnsWatch = nil
        camera.setupState?.watchedServer = "192.168.77.2"
        #expect(try watched(camera) == true)
    }
}
#endif
