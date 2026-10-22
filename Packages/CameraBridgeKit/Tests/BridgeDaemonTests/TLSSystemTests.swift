import BridgeWeb
import Foundation
import Testing
import TestSupport
@testable import BridgeDaemon

/// The secure address on the system's side: `status/tls.json` and the `tls-obtain` request.
@Suite(.timeLimit(.minutes(1))) struct TLSSystemTests {
    private func control(_ rig: Rig, helper: String) -> RequestFileSystemControl {
        RequestFileSystemControl(requestDirectory: rig.requests, statusDirectory: rig.status, product: "p", version: "1", build: "b", tlsHelper: helper)
    }

    @Test func aSystemWithoutTheTLSHelperHasNoTLSFront() async throws {
        let rig = try Rig(helper: nil)
        defer { rig.finish() }
        #expect(await control(rig, helper: "/nonexistent/cb-tls").certificateStatus() == nil)
    }

    @Test func theCertificateStatusIsReadFromTheStatusFile() async throws {
        let rig = try Rig(helper: nil)
        defer { rig.finish() }
        let system = control(rig, helper: "/bin/sh")
        #expect(await system.certificateStatus() == CertificateStatus(state: "none"), "a helper but no file yet")
        let json = #"{"state":"ready","message":"ok","host":"k7f2q9.box.camera-bridge.app","notAfter":"2026-12-21T08:00:00Z","updatedAt":"2026-10-22T08:00:00Z"}"#
        try Data(json.utf8).write(to: rig.status.appending(path: "tls.json"))
        let status = try #require(await system.certificateStatus())
        #expect(status.state == "ready" && status.host == "k7f2q9.box.camera-bridge.app" && status.notAfter == Date(timeIntervalSince1970: 1_797_840_000))
        try Data(#"{"state":"surprise"}"#.utf8).write(to: rig.status.appending(path: "tls.json"))
        #expect(await system.certificateStatus()?.state == "none", "an unknown state is no state")
    }

    @Test func theRequestCarriesOnlyCheckedValuesAndIsPickedUp() async throws {
        let rig = try Rig(helper: nil)
        defer { rig.finish() }
        let system = control(rig, helper: "/bin/sh")
        let pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"
        await #expect(throws: SystemError.self) { try await system.obtainCertificate(name: "k7f2q9", host: "evil.example.com", privateKeyPEM: pem) }
        await #expect(throws: SystemError.self) { try await system.obtainCertificate(name: "K7;rm", host: "k7;rm.box.camera-bridge.app", privateKeyPEM: pem) }
        await #expect(throws: SystemError.self) { try await system.obtainCertificate(name: "k7f2q9", host: "k7f2q9.box.camera-bridge.app", privateKeyPEM: "x") }
        let requests = rig.requests
        let taker = Task {
            let file = requests.appending(path: "tls-obtain.json")
            for _ in 0..<500 {
                if let data = try? Data(contentsOf: file) {
                    try? FileManager.default.removeItem(at: file)
                    return data
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            return Data()
        }
        try await system.obtainCertificate(name: "k7f2q9", host: "k7f2q9.box.camera-bridge.app", privateKeyPEM: pem)
        let body = try #require(try JSONSerialization.jsonObject(with: try await taker.value) as? [String: String])
        #expect(body["name"] == "k7f2q9" && body["host"] == "k7f2q9.box.camera-bridge.app" && body["privateKey"] == pem)
    }
}
