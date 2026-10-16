#if canImport(Darwin)
import BridgeSupport
import CameraAdapters
import Foundation
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// "Set up for Camera Bridge" through the engine, against a loopback fake Hikvision camera (never a real one): preview, one backup saved
/// before the first change, apply in order with read-back, idempotence, a refusal midway, restore, and folding in Clean picture.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CameraSetupEngineTests {
    /// The ISAPI documents of a camera that needs everything: another time zone, a time server on the internet, its own labels on, H.265
    /// with H.265+ and a long keyframe interval, UPnP and Hik-Connect on. `PUT` replaces a document; ONVIF is not answered.
    final class FakeHikvision: Sendable {
        static let ns = "xmlns=\"http://www.hikvision.com/ver20/XMLSchema\""
        static let originals: [String: String] = [
            "/ISAPI/System/time": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Time version=\"2.0\" \(ns)><timeMode>NTP</timeMode><localTime>2026-10-16T09:12:44+09:00</localTime><timeZone>CST-9:00:00</timeZone></Time>",
            "/ISAPI/System/time/ntpServers/1": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><NTPServer version=\"2.0\" \(ns)><id>1</id><addressingFormatType>hostname</addressingFormatType><hostName>time.windows.com</hostName><portNo>123</portNo><synchronizeInterval>1440</synchronizeInterval></NTPServer>",
            "/ISAPI/System/Network/capabilities": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><NetworkCap version=\"2.0\" \(ns)><isSupportUPnP>true</isSupportUPnP><isSupportEZVIZ>true</isSupportEZVIZ></NetworkCap>",
            "/ISAPI/System/Network/UPnP": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><UPnP version=\"2.0\" \(ns)><enabled>true</enabled><name>Gate</name></UPnP>",
            "/ISAPI/System/Network/EZVIZ": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><EZVIZ version=\"2.0\" \(ns)><enabled>true</enabled><registerStatus>true</registerStatus><verificationCode>QWERTY</verificationCode></EZVIZ>",
            "/ISAPI/System/Video/inputs/channels/1/overlays": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><VideoOverlay version=\"2.0\" \(ns)><DateTimeOverlay><enabled>true</enabled><positionY>544</positionY></DateTimeOverlay><channelNameOverlay><enabled>true</enabled></channelNameOverlay></VideoOverlay>",
            "/ISAPI/Streaming/channels/101": channel("101", codec: "H.265", width: 3840, height: 2160, smart: true),
            "/ISAPI/Streaming/channels/102": channel("102", codec: "H.264", width: 640, height: 480, smart: false),
        ]

        static func channel(_ id: String, codec: String, width: Int, height: Int, smart: Bool) -> String {
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><StreamingChannel version=\"2.0\" \(ns)><id>\(id)</id><Video><videoCodecType>\(codec)</videoCodecType>"
                + "<videoResolutionWidth>\(width)</videoResolutionWidth><videoResolutionHeight>\(height)</videoResolutionHeight><videoQualityControlType>CBR</videoQualityControlType>"
                + "<constantBitRate>4096</constantBitRate><maxFrameRate>2000</maxFrameRate><GovLength>50</GovLength><SmartCodec><enabled>\(smart)</enabled></SmartCodec></Video></StreamingChannel>"
        }

        let port: UInt16
        let documents = Box(FakeHikvision.originals)
        let refusePUT = Box<Set<String>>([])
        let puts = Box<[String]>([])
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

        private static func status(_ code: Int, _ words: String, _ sub: String) -> String {
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ResponseStatus version=\"2.0\" \(ns)><statusCode>\(code)</statusCode><statusString>\(words)</statusString><subStatusCode>\(sub)</subStatusCode></ResponseStatus>"
        }

        private func serve(_ connection: any TCPConnection) async {
            var parser = HTTPRequestParser(maxBodySize: 1 << 20)
            defer { connection.close() }
            while true {
                guard let data = try? await connection.receive(maximumLength: 65_536), let requests = try? parser.feed(data) else { return }
                for (head, body) in requests {
                    let (status, text) = answer(head.method, head.path, String(decoding: body, as: UTF8.self))
                    let wire = HTTPSerializer.response(status: status, headers: HTTPHeaders([("Content-Type", "application/xml")]), body: Data(text.utf8))
                    guard (try? await connection.send(wire)) != nil else { return }
                }
            }
        }

        private func answer(_ method: String, _ path: String, _ body: String) -> (Int, String) {
            switch method {
            case "GET":
                guard let document = documents.value[path] else { return (404, Self.status(4, "Invalid Operation", "notSupport")) }
                return (200, document)
            case "PUT":
                puts.update { $0.append(path) }
                guard documents.value[path] != nil else { return (404, Self.status(4, "Invalid Operation", "notSupport")) }
                if refusePUT.value.contains(path) { return (403, Self.status(4, "Invalid Operation", "notSupport")) }
                documents.update { $0[path] = body }
                return (200, Self.status(1, "OK", "ok"))
            default:
                return (404, "")   // ONVIF's POSTs: this camera has no ONVIF user for the bridge
            }
        }
    }

    private static let interfaces: @Sendable () -> [InterfaceAddress] = {
        [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
         InterfaceAddress(interface: "en0", address: "192.0.2.10", prefixLength: 24)]
    }

    private func fixture(servesTime: Bool = true) async throws -> (EngineFixture, FakeHikvision, CameraConfiguration) {
        var tuning = EngineTuning.testing
        tuning.interfaceAddresses = Self.interfaces
        let fixture = try await EngineFixture(tuning: tuning, servesTime: servesTime)
        let camera = try await FakeHikvision()
        var configuration = CameraConfiguration(name: "Gate", kind: .camera, vendor: .hikvision,
                                                endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.port), onvifPort: Int(camera.port)),
                                                username: "admin")
        configuration.isEnabled = false   // no stream: only the settings are tried
        try await fixture.engine.addCamera(configuration, password: "pa55")
        return (fixture, camera, configuration)
    }

    private var bridgeZone: String? { PosixTimeZone.string(for: TimeZone.current.identifier) }

    private func stored(_ fixture: EngineFixture, _ id: UUID) -> CameraConfiguration? { fixture.engine.configurations.first { $0.id == id } }

    @Test func thePreviewReadsEveryStepAndChangesNothing() async throws {
        let (fixture, camera, configuration) = try await fixture()
        defer { camera.stop(); fixture.directory.remove() }

        let report = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let status = Dictionary(uniqueKeysWithValues: report.steps.map { ($0.id, $0.status) })
        #expect(report.steps.map(\.id) == CameraSetupStepID.allCases)
        if bridgeZone != nil { #expect(status[.timeZone] == .willChange) }
        #expect(status[.timeSource] == .willChange && status[.cleanPicture] == .willChange && status[.streams] == .willChange)
        #expect(status[.upnp] == .willChange && status[.cloud] == .willChange)
        let source = try #require(report.steps.first { $0.id == .timeSource })
        #expect(source.changes == [CameraSetupChange(label: "Time source", now: "NTP from time.windows.com", after: "NTP from the bridge (192.0.2.10)")])
        let streams = try #require(report.steps.first { $0.id == .streams })
        #expect(streams.changes.map(\.label) == ["Smart codec (H.264+ or H.265+)", "Main stream", "Sub stream"])
        #expect(streams.changes[1].now == "H.265, 3840×2160, 20 fps, 4.1 Mbit/s, keyframe every 2.5 s")
        #expect(streams.changes[1].after == "H.264, 3840×2160, 20 fps, 4.1 Mbit/s, keyframe every 2 s", "full size kept, a keyframe every 2 s")
        #expect(camera.puts.value.isEmpty, "a preview never writes")
        #expect(!report.canRestore && stored(fixture, configuration.id)?.setupBackup == nil)
    }

    @Test func theSetupIsAppliedOnceThenChangesNothingAndIsRestoredExactly() async throws {
        let (fixture, camera, configuration) = try await fixture()
        defer { camera.stop(); fixture.directory.remove() }

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.stoppedAt == nil)
        let changed = report.steps.filter { $0.status == .done }.map(\.id)
        #expect(changed == (bridgeZone == nil ? [] : [.timeZone]) + [.timeSource, .cleanPicture, .streams, .upnp, .cloud])
        let documents = camera.documents.value
        #expect(documents["/ISAPI/System/time/ntpServers/1"]?.contains("<ipAddress>192.0.2.10</ipAddress>") == true)
        #expect(documents["/ISAPI/System/Network/UPnP"]?.contains("<enabled>false</enabled>") == true)
        #expect(documents["/ISAPI/System/Network/EZVIZ"]?.contains("<enabled>false</enabled>") == true)
        #expect(documents["/ISAPI/System/Video/inputs/channels/1/overlays"]?.contains("<enabled>true</enabled>") == false)
        #expect(documents["/ISAPI/Streaming/channels/101"]?.contains("<videoCodecType>H.264</videoCodecType>") == true)
        #expect(documents["/ISAPI/Streaming/channels/101"]?.contains("<SmartCodec><enabled>false</enabled>") == true)

        // One backup, saved with the camera, nothing secret in it.
        let saved = try #require(stored(fixture, configuration.id))
        let backup = try #require(saved.setupBackup)
        #expect(backup.timeSource?.hostName == "time.windows.com" && backup.upnp?.enabled == true && backup.cloud?.enabled == true)
        #expect(backup.cleanPicture != nil && backup.streams?.mainEncoder?.encoding == "H265" && backup.streams?.mainSmartCodec == true)
        #expect(!String(decoding: try JSONEncoder().encode(backup), as: UTF8.self).contains("QWERTY"))
        #expect(saved.setupState?.isFinished == true && saved.setupState?.version == CameraSetupState.currentVersion)
        #expect(saved.cleanPictureBackup == nil)

        // Again: everything is right already, nothing is written, the original values stay saved.
        let writes = camera.puts.value.count
        let again = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(again.steps.allSatisfy { $0.status == .alreadyRight || $0.status == .notSupported || $0.status == .notOffered })
        #expect(camera.puts.value.count == writes)
        #expect(stored(fixture, configuration.id)?.setupBackup == backup)

        // Restore: every document as the camera had it, and the record is gone.
        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.allSatisfy { $0.status == .restored } && !restored.canRestore)
        let back = camera.documents.value
        for path in ["/ISAPI/System/Network/UPnP", "/ISAPI/System/Network/EZVIZ", "/ISAPI/System/Video/inputs/channels/1/overlays"] {
            #expect(back[path] == FakeHikvision.originals[path], "\(path) is back")
        }
        #expect(back["/ISAPI/System/time/ntpServers/1"]?.contains("<addressingFormatType>hostname</addressingFormatType>") == true)
        #expect(back["/ISAPI/Streaming/channels/101"]?.contains("<videoCodecType>H.265</videoCodecType>") == true)
        #expect(back["/ISAPI/Streaming/channels/101"]?.contains("<SmartCodec><enabled>true</enabled>") == true)
        if bridgeZone != nil { #expect(back["/ISAPI/System/time"]?.contains("<timeZone>CST-9:00:00</timeZone>") == true) }
        #expect(stored(fixture, configuration.id)?.setupBackup == nil && stored(fixture, configuration.id)?.setupState == nil)
    }

    @Test func aRefusalMidwayStopsTheRunAndRestoreUndoesWhatWasDone() async throws {
        let (fixture, camera, configuration) = try await fixture()
        defer { camera.stop(); fixture.directory.remove() }
        camera.refusePUT.update { $0.insert("/ISAPI/System/Network/UPnP") }

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.stoppedAt == .upnp)
        let upnp = try #require(report.steps.first { $0.id == .upnp })
        #expect(upnp.status == .refused && upnp.detail == "Invalid Operation (notSupport)")
        #expect(report.steps.first { $0.id == .cloud }?.status == .notRun)
        #expect(report.steps.first { $0.id == .streams }?.status == .done, "the steps before it stay done")
        #expect(camera.documents.value["/ISAPI/System/Network/EZVIZ"] == FakeHikvision.originals["/ISAPI/System/Network/EZVIZ"], "the cloud is not touched")
        #expect(report.canRestore)

        let restored = try await fixture.engine.restoreCameraSetup(cameraID: configuration.id)
        #expect(restored.steps.allSatisfy { $0.status == .restored })
        #expect(camera.documents.value["/ISAPI/System/Video/inputs/channels/1/overlays"] == FakeHikvision.originals["/ISAPI/System/Video/inputs/channels/1/overlays"])
        #expect(stored(fixture, configuration.id)?.setupBackup == nil)
    }

    @Test func cleanPictureFromItsSwitchIsFoldedIntoTheOneBackup() async throws {
        let (fixture, camera, configuration) = try await fixture(servesTime: false)
        defer { camera.stop(); fixture.directory.remove() }
        #expect(try await fixture.engine.setCleanPicture(cameraID: configuration.id, clean: true).succeeded)
        let switchBackup = try #require(stored(fixture, configuration.id)?.cleanPictureBackup)

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.steps.first { $0.id == .cleanPicture }?.status == .alreadyRight)
        #expect(report.steps.first { $0.id == .timeSource }?.status == .notOffered, "the Mac app does not serve time")
        #expect(stored(fixture, configuration.id)?.setupBackup?.cleanPicture == switchBackup)
        #expect(stored(fixture, configuration.id)?.cleanPictureBackup == nil)

        // The Clean picture switch still turns it back, from the setup's backup.
        #expect(try await fixture.engine.setCleanPicture(cameraID: configuration.id, clean: false).succeeded)
        #expect(camera.documents.value["/ISAPI/System/Video/inputs/channels/1/overlays"] == FakeHikvision.originals["/ISAPI/System/Video/inputs/channels/1/overlays"])
        #expect(stored(fixture, configuration.id)?.setupBackup?.cleanPicture == nil)
    }

    @Test func camerasTheSetupCannotReachAreRefusedPlainly() async throws {
        let fixture = try await EngineFixture()
        defer { fixture.directory.remove() }
        let demo = EngineFixture.demoCamera()
        try await fixture.engine.addCamera(demo, password: nil)
        await #expect(throws: EngineError.self) { try await fixture.engine.cameraSetupPreview(cameraID: demo.id) }
        await #expect(throws: EngineError.unknownCamera) { try await fixture.engine.applyCameraSetup(cameraID: UUID()) }
        await #expect(throws: EngineError.self) { try await fixture.engine.restoreCameraSetup(cameraID: demo.id) }
    }

    // MARK: Pure pieces

    @Test func theTimeServerIsTheBridgesAddressOnTheCamerasNetwork() {
        let interfaces = [InterfaceAddress(interface: "lo0", address: "127.0.0.1", prefixLength: 8),
                          InterfaceAddress(interface: "utun3", address: "10.8.0.2", prefixLength: 24),
                          InterfaceAddress(interface: "en0", address: "192.0.2.10", prefixLength: 24),
                          InterfaceAddress(interface: "en1", address: "198.51.100.7", prefixLength: 24),
                          InterfaceAddress(interface: "en0", address: "fe80::1", prefixLength: 64)]
        #expect(BridgeEngine.timeServerAddress(cameraHost: "198.51.100.40", interfaces: interfaces) == "198.51.100.7")
        #expect(BridgeEngine.timeServerAddress(cameraHost: "192.0.2.77", interfaces: interfaces) == "192.0.2.10")
        #expect(BridgeEngine.timeServerAddress(cameraHost: "camera.local", interfaces: interfaces) == "192.0.2.10")
        #expect(BridgeEngine.timeServerAddress(cameraHost: "192.0.2.77", interfaces: [interfaces[0]]) == nil)
    }

    @Test func theOldestValueOfEachStepWinsInTheBackup() {
        let created = Date(timeIntervalSince1970: 1_000)
        var existing = CameraSetupBackup(version: 1, created: created)
        existing.upnp = CameraFeatureBackup(path: "/ISAPI/System/Network/UPnP", enabled: true)
        var fresh = CameraSetupBackup(version: 1, created: Date())
        fresh.upnp = CameraFeatureBackup(path: "/ISAPI/System/Network/UPnP", enabled: false)
        fresh.cloud = CameraFeatureBackup(path: "/ISAPI/System/Network/EZVIZ", enabled: true)
        fresh.streams = CameraStreamsBackup(mainEncoder: CameraVideoEncoderSettings(token: "", name: "", encoding: "H264", iFrameInterval: 40))
        let original = CameraVideoEncoderSettings(token: "", name: "", encoding: "H265", iFrameInterval: 100)
        var optimization = HomeKitOptimizationSnapshot()
        optimization.mainEncoder = original
        let clean = CleanPictureBackup(method: .hikvisionISAPI, document: "<VideoOverlay/>")
        let readings: [CameraSetupStepID: CameraSetupReading] = [.upnp: .init(state: .willChange), .cloud: .init(state: .alreadyRight),
                                                                .streams: .init(state: .willChange)]

        let merged = BridgeEngine.mergedSetupBackup(existing: existing, fresh: fresh, readings: readings, cleanPicture: clean, optimization: optimization)
        #expect(merged.upnp?.enabled == true, "an earlier run's value is the original")
        #expect(merged.cloud == nil, "nothing to keep for a step that changes nothing")
        #expect(merged.streams?.mainEncoder == original, "Optimize's undo holds the camera's own settings")
        #expect(merged.cleanPicture == clean && merged.created == created)
    }
}
#endif
