#if os(macOS)
import BridgeEngine
import BridgeSupport
import Foundation
import Testing
import TestSupport
@testable import BridgeDaemon

/// The whole daemon on this Mac: the real engine (demo camera, real encoders), the web interface on a loopback port, a throwaway data
/// directory, nothing advertised and no Keychain. Driven over real HTTP.
@Suite(.serialized, .timeLimit(.minutes(2))) struct DaemonTests {
    private struct Client {
        let base: URL
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.timeoutIntervalForRequest = 30
            return configuration
        }())
        var cookie: String?
        var csrf: String?

        init(port: UInt16) { base = URL(string: "http://127.0.0.1:\(port)")! }

        @discardableResult
        mutating func send(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> (status: Int, data: Data, headers: [AnyHashable: Any]) {
            var request = URLRequest(url: URL(string: path, relativeTo: base)!)
            request.httpMethod = method
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if method != "GET", let csrf { request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
            if let json {
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            let http = response as! HTTPURLResponse
            if let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"), setCookie.hasPrefix("cb_session=") {
                cookie = String(setCookie.split(separator: ";")[0])
            }
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let token = object["csrfToken"] as? String { csrf = token }
            return (http.statusCode, data, http.allHeaderFields)
        }

        func object(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }
    }

    @MainActor
    private func makeDaemon(directory: TemporaryDirectory, extra: [String] = []) throws -> Daemon {
        var options = try DaemonOptions.parse(arguments: ["--dev", "--data-dir", directory.url.path] + extra)
        options.port = 0
        options.hapBasePort = UInt16.random(in: 31_000...37_000)
        options.sensorsBridgePort = 0
        options.staticDirectory = nil
        return Daemon(options: options, environment: [:])
    }

    @Test @MainActor func theWholeBridgeWorksOverHTTP() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        let daemon = try makeDaemon(directory: directory)
        let port = try await daemon.start()
        var client = Client(port: port)

        // First run.
        #expect(try await client.send("GET", "/api/v1/status").status == 200)
        #expect(client.object(try await client.send("GET", "/api/v1/status").data)["setupRequired"] as? Bool == true)
        #expect(try await client.send("POST", "/api/v1/auth/setup", json: ["password": "daemon test password", "bridgeName": "Test bridge"]).status == 201)
        #expect(client.cookie != nil)

        // A demo camera, through the real engine.
        let added = try await client.send("POST", "/api/v1/cameras", json: ["type": "demo", "name": "Test pattern"])
        #expect(added.status == 201, "\(String(decoding: added.data, as: UTF8.self))")
        let id = try #require(client.object(added.data)["id"] as? String)
        var online = false
        for _ in 0..<80 {
            let camera = client.object(try await client.send("GET", "/api/v1/cameras/\(id)").data)
            if (camera["status"] as? [String: Any])?["connection"] as? String == "online" { online = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(online, "the demo camera comes online")

        // A real JPEG from the real engine.
        var jpeg: Data?
        for _ in 0..<40 {
            let snapshot = try await client.send("GET", "/api/v1/cameras/\(id)/snapshot")
            if snapshot.status == 200 { jpeg = snapshot.data; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let picture = try #require(jpeg, "a snapshot arrives")
        #expect(Array(picture.prefix(3)) == [0xFF, 0xD8, 0xFF])
        #expect(picture.count > 5_000)

        // Pairing: a code and a QR code.
        var pairing: [String: Any] = [:]
        for _ in 0..<40 {
            pairing = client.object(try await client.send("GET", "/api/v1/cameras/\(id)/pairing").data)
            if pairing["setupCode"] != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let code = try #require(pairing["setupCode"] as? String)
        #expect(code.wholeMatch(of: /\d{3}-\d{2}-\d{3}/) != nil)
        #expect((pairing["setupURI"] as? String)?.hasPrefix("X-HM://") == true)
        #expect((pairing["qrSVG"] as? String)?.hasPrefix("<svg") == true)

        // Changes reach the engine and persist.
        let renamed = try await client.send("PATCH", "/api/v1/cameras/\(id)", json: ["name": "Porch", "timestampOverlay": ["enabled": true, "position": "bottomLeft"]])
        #expect(renamed.status == 200)
        #expect(client.object(renamed.data)["name"] as? String == "Porch")
        let saved = try String(contentsOf: directory.url.appending(path: "config.json"), encoding: .utf8)
        #expect(saved.contains("Porch"))
        #expect(!saved.contains("daemon test password"))

        // Settings and the diagnostics bundle.
        #expect(try await client.send("PATCH", "/api/v1/settings", json: ["motionShadowTest": true]).status == 200)
        let diagnostics = try await client.send("GET", "/api/v1/diagnostics")
        let text = String(decoding: diagnostics.data, as: UTF8.self)
        #expect(text.contains("Camera Bridge OS"))
        #expect(text.contains("Porch"))
        #expect(!text.contains(code.replacingOccurrences(of: "-", with: "")), "no setup codes in the diagnostics")
        #expect(!text.contains("daemon test password"))

        // The test motion event and the log.
        #expect(try await client.send("POST", "/api/v1/cameras/\(id)/test-motion").status == 204)
        let log = String(decoding: try await client.send("GET", "/api/v1/logs?limit=200").data, as: UTF8.self)
        #expect(log.contains("Porch"))

        // Remove it again.
        #expect(try await client.send("DELETE", "/api/v1/cameras/\(id)").status == 204)
        #expect(try await client.send("GET", "/api/v1/cameras/\(id)").status == 404)
        #expect((client.object(try await client.send("GET", "/api/v1/status").data)["cameras"] as? [String: Int])?["total"] == 0)
        await daemon.stop()
    }

    @Test @MainActor func updatesReachTheRootHelperThroughTheRequestFolder() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        // The folders Camera Bridge OS has: with a stand-in for the root side watching them.
        let rig = try Rig(helper: FakeRootHelper.image(latest: "0.2", current: "0.1"))
        defer { rig.finish() }
        let daemon = try makeDaemon(directory: directory, extra: ["--os-request-dir", rig.requests.path, "--os-status-dir", rig.status.path])
        let port = try await daemon.start()
        var client = Client(port: port)
        // Health probe of the image: no sign-in needed.
        let open = try await client.send("GET", "/api/v1/status")
        #expect(open.status == 200)
        #expect(client.object(open.data)["setupRequired"] as? Bool == true)
        #expect(try await client.send("POST", "/api/v1/auth/setup", json: ["password": "daemon test password"]).status == 201)

        let system = client.object(try await client.send("GET", "/api/v1/system").data)
        #expect(system["mode"] as? String == "installed" && system["canUpdate"] as? Bool == true && system["canManage"] as? Bool == true)
        let check = try await client.send("POST", "/api/v1/system/update", json: ["action": "check"])
        #expect(check.status == 200, "\(String(decoding: check.data, as: UTF8.self))")
        #expect(client.object(check.data)["latest"] as? String == "0.2" && client.object(check.data)["available"] as? Bool == true)
        #expect(rig.helper?.names() == ["update-check"], "the request reached the root side, as a request file")
        #expect(try await client.send("POST", "/api/v1/system/ssh", json: ["enabled": true, "authorizedKeys": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE"]).status == 200)
        #expect(client.object(try await client.send("GET", "/api/v1/system").data)["sshEnabled"] as? Bool == true)
        #expect(try await client.send("POST", "/api/v1/system/reboot", json: ["confirm": true]).status == 202)
        #expect(rig.helper?.names().last == "reboot")
        await daemon.stop()
    }

    @Test @MainActor func withoutTheFoldersItIsADevelopmentSystem() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        let daemon = try makeDaemon(directory: directory, extra: ["--run-dir", directory.file("no-such-run-folder").path])
        let port = try await daemon.start()
        var client = Client(port: port)
        _ = try await client.send("POST", "/api/v1/auth/setup", json: ["password": "daemon test password"])
        #expect(client.object(try await client.send("GET", "/api/v1/system").data)["mode"] as? String == "development")
        let refused = try await client.send("POST", "/api/v1/system/update", json: ["action": "check"])
        #expect(refused.status == 409)
        #expect(!FileManager.default.fileExists(atPath: directory.file("no-such-run-folder").path), "nothing was created")
        await daemon.stop()
    }

    @Test @MainActor func stoppingClosesThePortAndTheEngine() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        let daemon = try makeDaemon(directory: directory)
        let port = try await daemon.start()
        #expect(await daemon.isHealthy())
        await daemon.stop()
        #expect(!(await daemon.isHealthy()))
        var client = Client(port: port)
        do {
            _ = try await client.send("GET", "/api/v1/status")
            Issue.record("the port should be closed")
        } catch {
            // refused: the web interface is gone
        }
    }

    @Test @MainActor func thePreviewServesTheSampleBridge() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        let daemon = try makeDaemon(directory: directory, extra: ["--preview"])
        let port = try await daemon.start()
        var client = Client(port: port)
        _ = try await client.send("POST", "/api/v1/auth/setup", json: ["password": "preview password"])
        let list = client.object(try await client.send("GET", "/api/v1/cameras").data)
        let cameras = try #require(list["cameras"] as? [[String: Any]])
        #expect(cameras.count == 5)
        let hosts = cameras.compactMap { ($0["endpoint"] as? [String: Any])?["host"] as? String }
        #expect(hosts.allSatisfy { $0 == "localhost" || $0.hasPrefix("192.0.2.") }, "only documentation addresses")
        await daemon.stop()
    }

    @Test @MainActor func theMacAppsDataIsNeverUsed() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in ["Library/Application Support/CameraBridge", "Library/Containers/com.coreysilvia.CameraBridge/Data"] {
            var options = DaemonOptions()
            options.dataDirectory = home.appending(path: path)
            #expect(throws: Daemon.Failure.self) { try Daemon.dataDirectory(for: options) }
        }
        #expect(throws: Daemon.Failure.self) { try Daemon.dataDirectory(for: DaemonOptions()) }   // no default on a Mac
    }

    @Test @MainActor func aPortThatIsTakenIsAFailureNotAHang() async throws {
        let directory = try TemporaryDirectory(prefix: "cb-daemon")
        defer { directory.remove() }
        let first = try makeDaemon(directory: directory)
        let port = try await first.start()
        let other = try TemporaryDirectory(prefix: "cb-daemon")
        defer { other.remove() }
        var options = try DaemonOptions.parse(arguments: ["--dev", "--data-dir", other.url.path, "--preview"])
        options.port = port
        let second = Daemon(options: options, environment: [:])
        await #expect(throws: Daemon.Failure.self) { try await second.start() }
        await first.stop()
    }
}
#endif
