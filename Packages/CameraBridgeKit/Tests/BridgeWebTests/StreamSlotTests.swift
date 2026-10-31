import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The live and event slots of the streaming routes are given back when the server does not run the body: a HEAD request, or an answer
/// whose head cannot be sent. Before, 16 `HEAD /api/v1/live` left every later live view refused with 429 until the daemon restarted.
@Suite(.timeLimit(.minutes(1))) struct StreamSlotTests {
    private final class Rig: Sendable {
        let harness: Harness
        let transport = FakeNetworkTransport()
        let server: HTTPServer
        let serverEnds = Box<[FakeTCPConnection]>([])

        init(maximumLive: Int = 2, maximumEvents: Int = 2) throws {
            let harness = try Harness { configuration in
                configuration.maximumLiveStreams = maximumLive
                configuration.maximumEventStreams = maximumEvents
            }
            self.harness = harness
            server = HTTPServer(port: 0, transport: transport) { await harness.app.handle($0) }
        }

        func connect() async throws -> RawClient {
            if transport.listeners.isEmpty { try await server.start() }
            let (client, serverEnd) = FakeTCPConnection.pair(remoteAddress: "192.0.2.77")
            serverEnds.update { $0.append(serverEnd) }
            transport.listeners[0].accept(serverEnd)
            return RawClient(connection: client)
        }

        func camera() async throws -> UUID {
            let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.20"), username: "")
            try await harness.backend.addCamera(camera, password: nil)
            return camera.id
        }
    }

    private func request(_ method: String, _ path: String, cookie: String, accept: String? = nil) -> String {
        "\(method) \(path) HTTP/1.1\r\nHost: camera-bridge.local\r\nCookie: \(cookie)\r\n" + (accept.map { "Accept: \($0)\r\n" } ?? "") + "\r\n"
    }

    @Test func headRequestsLeaveEveryStreamingRouteUsable() async throws {
        let rig = try Rig()
        let session = try await rig.harness.signIn()
        let id = try await rig.camera()
        let routes: [(path: String, accept: String?)] = [
            ("/api/v1/live?cameras=\(id.uuidString)", nil),
            ("/api/v1/cameras/\(id.uuidString)/live", nil),
            ("/api/v1/events", nil),
            ("/api/v1/logs", "text/event-stream"),
        ]
        let client = try await rig.connect()
        for route in routes {
            for _ in 0..<5 {
                try await client.send(request("HEAD", route.path, cookie: session.cookie, accept: route.accept))
                #expect(try await client.reply(hasBody: false)?.status == 200, "\(route.path)")
            }
        }
        for route in routes {
            let viewer = try await rig.connect()
            try await viewer.send(request("GET", route.path, cookie: session.cookie, accept: route.accept))
            #expect(try await viewer.head()?.status == 200, "\(route.path) still has a free slot after the HEAD requests")
            viewer.close()
        }
        await rig.server.stop()
    }

    @Test func anAnswerWhoseHeadCannotBeSentGivesItsSlotBack() async throws {
        let rig = try Rig(maximumLive: 1)
        let session = try await rig.harness.signIn()
        let id = try await rig.camera()
        for _ in 0..<3 {
            let leaving = try await rig.connect()
            rig.serverEnds.value.last?.failSends()   // the browser is gone before the answer starts
            try await leaving.send(request("GET", "/api/v1/live?cameras=\(id.uuidString)", cookie: session.cookie))
            #expect(await eventually { rig.serverEnds.value.last?.isClosed == true })
        }
        let viewer = try await rig.connect()
        try await viewer.send(request("GET", "/api/v1/live?cameras=\(id.uuidString)", cookie: session.cookie))
        #expect(try await viewer.head()?.status == 200)
        viewer.close()
        await rig.server.stop()
    }
}
