#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// Driveway (Hikvision, 192.0.2.79): "ONVIF device information unavailable (unauthorized)", then "lockedOut", with the
/// lock guard working but a new ONVIF attempt at every opening of the camera page. After ONVIF refuses the credentials
/// the page asks again only after 10 minutes (or when the person asks to check again, or changes the camera), and the
/// HomeKit Readiness card says what to do.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ONVIFRefusalMemoryTests {
    /// An ONVIF device service on loopback that tells its time to anyone and rejects every login (401).
    final class RejectingONVIFCamera: Sendable {
        let port: UInt16
        let requests = Box(0)
        let logins = Box(0)
        private let listener: any TCPListener
        private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

        init() async throws {
            listener = try await AppleNetworkTransport().listen(port: 0, loopbackOnly: true)
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
                guard let data = try? await connection.receive(maximumLength: 65_536) else { return }
                guard let parsed = try? parser.feed(data) else { return }
                for (_, body) in parsed {
                    requests.update { $0 += 1 }
                    let text = String(decoding: body, as: UTF8.self)
                    let wire: Data
                    if text.contains("GetSystemDateAndTime") {
                        wire = HTTPSerializer.response(status: 200, headers: HTTPHeaders([("Content-Type", "application/soap+xml; charset=utf-8")]),
                                                       body: Data(Self.dateAndTime().utf8))
                    } else {
                        logins.update { $0 += 1 }
                        wire = HTTPSerializer.response(status: 401, headers: HTTPHeaders([("Content-Type", "text/plain")]), body: Data("Unauthorized".utf8))
                    }
                    guard (try? await connection.send(wire)) != nil else { return }
                }
            }
        }

        static func dateAndTime() -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
            return """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" \
            xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body><tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime>\
            <tt:DateTimeType>NTP</tt:DateTimeType><tt:UTCDateTime><tt:Time><tt:Hour>\(c.hour ?? 0)</tt:Hour><tt:Minute>\(c.minute ?? 0)</tt:Minute>\
            <tt:Second>\(c.second ?? 0)</tt:Second></tt:Time><tt:Date><tt:Year>\(c.year ?? 2026)</tt:Year><tt:Month>\(c.month ?? 1)</tt:Month>\
            <tt:Day>\(c.day ?? 1)</tt:Day></tt:Date></tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>
            """
        }
    }

    private func fixture(memory: Duration = .seconds(600)) async throws -> (EngineFixture, RejectingONVIFCamera, CameraConfiguration) {
        var tuning = EngineTuning.testing
        tuning.onvifRefusalMemory = memory
        let fixture = try await EngineFixture(tuning: tuning)
        let camera = try await RejectingONVIFCamera()
        var configuration = CameraConfiguration(name: "Driveway", kind: .camera, vendor: .onvif,
                                                endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.port), onvifPort: Int(camera.port)),
                                                username: "bridge")
        configuration.isEnabled = true
        try await fixture.engine.addCamera(configuration, password: "wrong")
        return (fixture, camera, configuration)
    }

    @Test func theCameraPageAsksONVIFOnceAndThenRemembersTheRefusalForTenMinutes() async throws {
        let (fixture, camera, configuration) = try await fixture()
        defer { camera.stop(); fixture.directory.remove() }

        let first = try await fixture.engine.cameraSettings(cameraID: configuration.id)
        #expect(!first.supportsONVIF)
        #expect(first.onvifLoginRejected == true)
        let asked = camera.requests.value
        #expect(asked >= 2 && camera.logins.value >= 1, "the first opening does ask: \(asked) requests")

        // The page is opened again and again (and the readiness card loads each time).
        for _ in 0..<5 {
            let again = try await fixture.engine.cameraSettings(cameraID: configuration.id)
            #expect(!again.supportsONVIF && again.onvifLoginRejected == true)
            _ = try await fixture.engine.homeKitReadiness(cameraID: configuration.id)
        }
        #expect(camera.requests.value == asked, "no ONVIF attempt for a remembered refusal: \(camera.requests.value) requests, \(asked) before")

        // The person asks to check again: the camera is asked.
        _ = try await fixture.engine.cameraSettings(cameraID: configuration.id, recheck: true)
        #expect(camera.requests.value > asked)
    }

    @Test func theMemoryEndsAfterItsLifetimeAndWhenTheCameraIsChanged() async throws {
        let (fixture, camera, configuration) = try await fixture(memory: .milliseconds(400))
        defer { camera.stop(); fixture.directory.remove() }

        _ = try await fixture.engine.cameraSettings(cameraID: configuration.id)
        let asked = camera.requests.value
        _ = try await fixture.engine.cameraSettings(cameraID: configuration.id)
        #expect(camera.requests.value == asked)
        try await Task.sleep(for: .milliseconds(500))
        _ = try await fixture.engine.cameraSettings(cameraID: configuration.id)
        #expect(camera.requests.value > asked, "asked again once the memory ran out")

        // A new password (an ONVIF user was added): the next opening asks at once.
        let afterRefusal = camera.requests.value
        _ = try await fixture.engine.cameraSettings(cameraID: configuration.id)
        #expect(camera.requests.value == afterRefusal)
        try await fixture.engine.updateCamera(configuration, password: "new-password")
        _ = try await fixture.engine.cameraSettings(cameraID: configuration.id)
        #expect(camera.requests.value > afterRefusal, "changing the camera forgets the refusal")
    }

    @Test func theReadinessCardTellsThePersonToAddAnONVIFUser() async throws {
        let (fixture, camera, configuration) = try await fixture()
        defer { camera.stop(); fixture.directory.remove() }

        for _ in 0..<2 {   // the first answer comes from the camera, the second from memory: the same card
            let report = try await fixture.engine.homeKitReadiness(cameraID: configuration.id)
            let check = try #require(report.checks.first { $0.id == "onvif" })
            #expect(check.status == .problem)
            #expect(check.explanation.hasPrefix("Add an ONVIF user on this camera"))
            #expect(check.recommendedValue == "Add an ONVIF user on this camera")
        }
    }
}
#endif
