import BridgeEngine
import BridgeSupport
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The media routes over a real connection (the in-memory transport): what the browser's `fetch` meets on the wire.
@Suite(.timeLimit(.minutes(1))) struct NVRWireTests {
    @Test func fragmentsTravelWithTheirLengthOnOneKeptConnectionAndErrorsHaveTheirPhrases() async throws {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 3)
        archive.files = [file]
        let app = rig.harness.app
        let transport = FakeNetworkTransport()
        let server = HTTPServer(port: 0, transport: transport) { request in await app.handle(request) }
        try await server.start()
        let (client, serverEnd) = FakeTCPConnection.pair(remoteAddress: "192.0.2.50")
        transport.listeners[0].accept(serverEnd)
        let raw = RawClient(connection: client)
        func get(_ path: String) async throws -> RawClient.Reply {
            try await raw.send("GET /api/v1/\(path) HTTP/1.1\r\nHost: camera-bridge.local\r\nCookie: \(rig.session.cookie)\r\n\r\n")
            return try #require(try await raw.reply())
        }
        let base = "nvr/cameras/\(rig.cameraID)"
        for index in 0..<3 {
            let reply = try await get("\(base)/fragments/\(file.fragments[index].id)")
            #expect(reply.status == 200 && reply.headers["Content-Type"] == "video/mp4")
            #expect(reply.headers["Content-Length"] == String(file.stored[index].count - 32) && reply.body == file.stored[index].dropFirst(32))
            #expect(reply.headers["Cache-Control"] == "no-store" && reply.headers["Connection"] != "close")
        }
        let initSegment = try await get("\(base)/fragments/\(file.fragments[0].id)/init")
        #expect(initSegment.body == file.initData)
        let key = try await get("\(base)/keyframe?at=\(rig.ms(500))")
        #expect(key.status == 200 && key.headers["X-CB-Part"]?.contains("\"initId\":\"\(file.fragments[0].id)\"") == true)
        let gone = try await get("\(base)/fragments/aaaaaaaaaaaa.9")
        #expect(gone.status == 410)
        let gap = try await get("\(base)/keyframe?at=\(rig.ms(99_000))")
        #expect(gap.status == 404)
        #expect(await server.connectionCount == 1, "the same connection served all of it")
        // The status lines carry the reason phrases.
        try await raw.send("GET /api/v1/\(base)/fragments/aaaaaaaaaaaa.9 HTTP/1.1\r\nHost: camera-bridge.local\r\nCookie: \(rig.session.cookie)\r\nConnection: close\r\n\r\n")
        let line = try await client.receive(maximumLength: 64 * 1024).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(line.hasPrefix("HTTP/1.1 410 Gone\r\n"), "\(line.prefix(40))")
        await server.stop()
    }
}
