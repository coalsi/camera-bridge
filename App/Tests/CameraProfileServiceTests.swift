import BridgeEngine
import CameraAdapters
import Foundation
import Testing

@Suite @MainActor struct CameraProfileServiceTests {
    private let feedJSON = Data(#"{"version": 2, "profiles": [{"vendor": "acme", "modelPattern": "X", "preferredConfigMethod": "onvifFull"}]}"#.utf8)

    private final class Server {
        var requests: [URLRequest] = []
        var status = 200
        var etag: String? = "\"v2\""
        var body = Data()
        func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            var headers: [String: String] = [:]
            if let etag { headers["ETag"] = etag }
            let url = request.url ?? CameraBridgeService.baseURL
            return (status == 200 ? body : Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    private func makeService(_ server: Server, directory: URL, now: @escaping () -> Date) -> CameraProfileService {
        CameraProfileService(directory: directory, bundle: Bundle(for: FakeSetupService.self), fetch: { try await server.respond($0) }, now: now)
    }

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CameraProfileServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func fetchesCachesAndAppliesTheFeed() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        server.body = feedJSON
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let service = makeService(server, directory: directory) { clock }

        let feed = await service.refreshIfDue()
        #expect(feed?.version == "2")
        #expect(server.requests.count == 1)
        #expect(server.requests[0].url == CameraBridgeService.cameraProfilesEndpoint)
        #expect(server.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(service.currentFeed().version == "2", "the cached copy is used from now on")
        #expect(service.metadata.etag == "\"v2\"")

        clock += 3600
        #expect(await service.refreshIfDue() == nil)
        #expect(server.requests.count == 1, "at most one request per 24 hours")

        clock += 86_400
        server.status = 304
        #expect(await service.refreshIfDue() == nil)
        #expect(server.requests.count == 2)
        #expect(server.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"v2\"")
        #expect(service.currentFeed().version == "2", "a 304 keeps the cached feed")
    }

    @Test func aBadAnswerChangesNothing() async {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server()
        server.body = Data("<html>oops</html>".utf8)
        let service = makeService(server, directory: directory) { Date() }
        #expect(await service.refreshIfDue() == nil)
        #expect(service.currentFeed() == service.bundledFeed())
        server.status = 500
        #expect(await CameraProfileService(directory: directory, bundle: .main, fetch: { try await server.respond($0) }).refreshIfDue() == nil)
    }
}
