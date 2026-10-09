// Runs the real go2rtc program when CAMERABRIDGE_GO2RTC_DIR names a folder that holds it (Tools/fetch-go2rtc.sh puts it in
// build/helpers). Contacts nothing outside this Mac: the only stream points at a closed loopback port.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TestSupport
import Testing
@testable import CameraAdapters

private let helperDirectory = ProcessInfo.processInfo.environment["CAMERABRIDGE_GO2RTC_DIR"]

@Suite(.timeLimit(.minutes(2)), .serialized) struct Go2RTCRealBinaryTests {
    @Test(.enabled(if: helperDirectory != nil)) func realHelperStartsOnLoopbackWithSecretsOnlyInTheEnvironment() async throws {
        let directory = try TemporaryDirectory(prefix: "Go2RTCReal")
        defer { directory.remove() }
        let launcher = PlatformHelperLauncher(searchDirectories: [URL(filePath: try #require(helperDirectory), directoryHint: .isDirectory)])
        #expect(launcher.locate("go2rtc") != nil)
        let seen = Box<(port: UInt16, password: String?)?>(nil)
        let manager = Go2RTCManager(launcher: launcher, directory: directory.url.appending(path: "go2rtc", directoryHint: .isDirectory),
                                    pickPort: Go2RTCManager.portPicker(transport: PlatformNetworkTransport()),
                                    healthCheck: { port, password in
                                        let ok = await Go2RTCManager.httpHealthCheck(port, password)
                                        if ok { seen.set((port, password)) }
                                        return ok
                                    })
        let secret = "SECRET-KEY-\(UUID().uuidString.prefix(8))"
        let source = try Go2RTCSource(parsing: "rtspx://127.0.0.1:9/\(secret)")
        let url = try await manager.attach(streamID: "cb-real", source: source)
        defer { Task { await manager.stop() } }
        #expect(url.host() == "127.0.0.1" && url.path() == "/cb-real")
        let ports = try #require(await manager.currentPorts)
        #expect(Int(ports.rtsp) == url.port)
        let api = try #require(seen.value)

        // No file the helper's folder holds has the secret, and the configuration is gone.
        let folder = directory.url.appending(path: "go2rtc", directoryHint: .isDirectory)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
            let text = (try? String(contentsOf: folder.appending(path: name), encoding: .utf8)) ?? ""
            #expect(!text.contains(secret), "\(name)")
        }

        // The API wants its password even from this Mac, and answers with it.
        let anonymous = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(3))
        defer { anonymous.invalidate() }
        let (_, denied) = try await anonymous.data(for: URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(api.port)/api"))))
        #expect(denied.statusCode == 401)
        // The stream is configured from the environment variable: the API lists it with the source (go2rtc masks it in its own output).
        let client = AuthenticatingHTTPClient(credentials: HTTPCredentials(username: Go2RTCConfig.apiUsername, password: try #require(api.password)),
                                              timeout: .seconds(3))
        defer { client.invalidate() }
        let (streams, listed) = try await client.data(for: URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(api.port)/api/streams"))))
        #expect(listed.statusCode == 200)
        #expect(String(decoding: streams, as: UTF8.self).contains("cb-real"))
        // Paths outside the allow list are not served.
        let (_, config) = try await client.data(for: URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(api.port)/api/config"))))
        #expect(config.statusCode == 404)
        let (_, exit) = try await client.data(for: URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(api.port)/api/exit?code=0"))))
        #expect(exit.statusCode == 404)

        // Everything the process listens on is loopback.
        let pidText = try String(contentsOf: folder.appending(path: "go2rtc.pid"), encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let listening = try listeningSockets(pid: pid)
        #expect(!listening.isEmpty)
        #expect(listening.allSatisfy { $0.hasPrefix("127.0.0.1:") }, "\(listening)")
        #expect(listening.contains("127.0.0.1:\(ports.api)") && listening.contains("127.0.0.1:\(ports.rtsp)"))

        // Asking for the stream makes the helper dial its source: the refused port is a clean RTSP error, not a hang.
        let factory = RTSPProbing.factory(transport: PlatformNetworkTransport())
        await #expect(throws: (any Error).self) {
            _ = try await RTSPProbing.describe(url: url, credentials: nil, timeout: .seconds(8), factory: factory)
        }
        await manager.stop()
        #expect(await !manager.isRunning)
        #expect(await eventually(timeout: .seconds(5)) { (try? listeningSockets(pid: pid))?.isEmpty ?? true })
    }

    @Test(.enabled(if: helperDirectory != nil)) func realSignInPageServesGo2RTCsOwnPages() async throws {
        let directory = try TemporaryDirectory(prefix: "Go2RTCReal")
        defer { directory.remove() }
        let launcher = PlatformHelperLauncher(searchDirectories: [URL(filePath: try #require(helperDirectory), directoryHint: .isDirectory)])
        let manager = Go2RTCManager(launcher: launcher, directory: directory.url.appending(path: "go2rtc", directoryHint: .isDirectory),
                                    pickPort: Go2RTCManager.portPicker(transport: PlatformNetworkTransport()), healthCheck: Go2RTCManager.httpHealthCheck)
        let url = try await manager.beginSetupSession()
        defer { Task { await manager.stop() } }
        let client = AuthenticatingHTTPClient(credentials: nil, timeout: .seconds(3))
        defer { client.invalidate() }
        let (page, response) = try await client.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).localizedCaseInsensitiveContains("ring"))
        // The pages' account lookups exist; nothing that runs programs does.
        for path in ["/api/ring", "/api/nest", "/api/wyze", "/api/tuya"] {
            let (_, reply) = try await client.data(for: URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(url.port ?? 0)\(path)"))))
            #expect(reply.statusCode != 404, "\(path)")
        }
        for path in ["/api/exit?code=0", "/api/restart", "/api/config"] {
            let (_, reply) = try await client.data(for: URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(url.port ?? 0)\(path)"))))
            #expect(reply.statusCode == 404, "\(path)")
        }
        await manager.endSetupSession()
    }

    /// `host:port` of every TCP listener of `pid`, from lsof.
    private func listeningSockets(pid: Int32) throws -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}
#endif
