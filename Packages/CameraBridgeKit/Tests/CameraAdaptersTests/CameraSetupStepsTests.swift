// Loopback fake ISAPI and ONVIF cameras (the platform transport): macOS and Linux.
#if os(macOS) || os(Linux)
import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// "Set up for Camera Bridge", the steps on the camera's side: each read (its value is the backup), applied, read back and restored,
/// against fakes only (never a real camera).
@Suite(.timeLimit(.minutes(1))) struct CameraSetupStepsTests {
    private let onvifCredentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)

    private func hikvision(_ camera: FakeSetupCamera) -> CameraSettingsService {
        CameraSettingsService(endpoint: camera.endpoint, credentials: camera.credentials, vendor: .hikvision)
    }

    // MARK: Pure pieces

    @Test func posixZonesBecomeHikvisionsOwnText() {
        #expect(HikvisionTimeZone.isapi(fromPosix: "MST7") == "CST+7:00:00")
        #expect(HikvisionTimeZone.isapi(fromPosix: "CST6CDT,M3.2.0,M11.1.0") == "CST+6:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00")
        #expect(HikvisionTimeZone.isapi(fromPosix: "CET-1CEST,M3.5.0,M10.5.0/3") == "CST-1:00:00DST01:00:00,M3.5.0/02:00:00,M10.5.0/03:00:00")
        #expect(HikvisionTimeZone.isapi(fromPosix: "<+0530>-5:30") == "CST-5:30:00")
        #expect(HikvisionTimeZone.isapi(fromPosix: "AEST-10AEDT,J60,J300") == nil, "Julian-day rules are not written")
        #expect(HikvisionTimeZone.same("CST+6:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00", "CST6CDT,M3.2.0,M11.1.0"))
        #expect(!HikvisionTimeZone.same("CST+7:00:00", "CST6CDT,M3.2.0,M11.1.0"))
        #expect(HikvisionTimeZone.same("CST+7:00:00", "MST7"))
    }

    @Test func zonesAreWrittenAsOffsetsForPeople() {
        #expect(CameraSetupText.zone("MST7") == "UTC−7")
        #expect(CameraSetupText.zone("CST+8:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00") == "UTC−8 with daylight saving")
        #expect(CameraSetupText.zone("<+0530>-5:30") == "UTC+5:30")
        #expect(CameraSetupText.zone("UTC0") == "UTC")
        #expect(CameraSetupText.list(["a", "b", "c"]) == "a, b and c")
        let settings = CameraVideoEncoderSettings(token: "", name: "", encoding: "H265", resolution: .init(width: 3840, height: 2160), frameRate: 20,
                                                  bitrate: 4096, iFrameInterval: 50)
        #expect(CameraSetupText.encoder(settings) == "H.265, 3840×2160, 20 fps, 4.1 Mbit/s, keyframe every 2.5 s")
    }

    @Test func isapiStatusDocumentsAreReadInTheCamerasWords() throws {
        let reboot = try #require(HikvisionISAPI.responseStatus(Data(FakeSetupCamera.status(7, "Reboot Required", sub: "rebootRequired").utf8)))
        #expect(reboot.code == 7 && reboot.words == "Reboot Required (rebootRequired)")
        let refused = try #require(HikvisionISAPI.responseStatus(Data(FakeSetupCamera.status(4, "Invalid Operation", sub: "notSupport").utf8)))
        #expect(refused.code == 4 && refused.isNotSupported)
        #expect(HikvisionISAPI.responseStatus(Data(FakeSetupCamera.upnp.utf8)) == nil)
    }

    @Test func theClockDocumentLosesItsTimeOnlyWhenNTPKeepsTheTime() {
        let ntp = CameraSettingsService.withoutLocalTime(FakeSetupCamera.time)
        #expect(!ntp.contains("localTime") && ntp.contains("<timeZone>"))
        let manual = FakeSetupCamera.time.replacingOccurrences(of: "<timeMode>NTP</timeMode>", with: "<timeMode>manual</timeMode>")
        #expect(CameraSettingsService.withoutLocalTime(manual) == manual)
    }

    @Test func aBackupHoldsAndClearsEachStep() throws {
        var backup = CameraSetupBackup(version: 1, created: Date(timeIntervalSince1970: 0))
        #expect(backup.isEmpty)
        backup.cloud = CameraFeatureBackup(path: "/ISAPI/System/Network/EZVIZ", enabled: true)
        backup.streams = CameraStreamsBackup(mainSmartCodec: true)
        #expect(backup.holds(.cloud) && backup.holds(.streams) && !backup.holds(.timeZone))
        #expect(backup.clearing(.cloud).clearing(.streams).isEmpty)
        #expect(try JSONDecoder().decode(CameraSetupBackup.self, from: JSONEncoder().encode(backup)) == backup)
    }

    // MARK: Hikvision ISAPI

    @Test func theTimeZoneIsReadBackedUpAppliedAndRestored() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = hikvision(camera)

        let (reading, backup) = try await service.readTimeZone(posix: "MST7", zoneName: "America/Phoenix")
        #expect(reading.state == .willChange)
        #expect(reading.changes == [.init(label: "Time zone", now: "UTC−8 with daylight saving", after: "America/Phoenix (UTC−7)")])
        #expect(backup == CameraTimeZoneBackup(method: .hikvisionISAPI, value: "CST+8:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00"))

        let applied = try await service.applyTimeZone(posix: "MST7")
        #expect(applied == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        let put = try #require(camera.puts(to: HikvisionISAPI.timePath).last)
        #expect(put.contains("<timeZone>CST+7:00:00</timeZone>") && put.contains("<timeMode>NTP</timeMode>") && !put.contains("localTime"))
        #expect(try await service.readTimeZone(posix: "MST7", zoneName: "America/Phoenix").0.state == .alreadyRight, "running it again changes nothing")

        let restored = try await service.restoreTimeZone(try #require(backup))
        #expect(restored.succeeded)
        #expect(camera.documents.value[HikvisionISAPI.timePath]?.contains("<timeZone>CST+8:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00</timeZone>") == true)
    }

    @Test func theCameraTakesItsTimeFromTheBridgeAndGivesItBack() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = hikvision(camera)

        let (reading, backup) = try await service.readTimeSource(server: "192.0.2.10")
        #expect(reading.changes == [.init(label: "Time source", now: "NTP from time.windows.com", after: "NTP from the bridge (192.0.2.10)")])
        #expect(backup == CameraTimeSourceBackup(method: .hikvisionISAPI, mode: "NTP", addressing: "hostname", hostName: "time.windows.com", port: "123"))

        #expect(try await service.applyTimeSource(server: "192.0.2.10") == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        let server = try #require(camera.documents.value[HikvisionISAPI.ntpServerPath])
        #expect(server.contains("<addressingFormatType>ipaddress</addressingFormatType>") && server.contains("<ipAddress>192.0.2.10</ipAddress></NTPServer>"))
        #expect(server.contains("<synchronizeInterval>1440</synchronizeInterval>"), "the rest of the document is as the camera had it")
        #expect(camera.puts(to: HikvisionISAPI.timePath).isEmpty, "the clock already kept time by NTP")
        #expect(try await service.readTimeSource(server: "192.0.2.10").0.state == .alreadyRight)

        #expect(try await service.restoreTimeSource(try #require(backup)).succeeded)
        let back = try #require(camera.documents.value[HikvisionISAPI.ntpServerPath])
        #expect(back.contains("<addressingFormatType>hostname</addressingFormatType>") && back.contains("<hostName>time.windows.com</hostName>"))
    }

    @Test func aClockSetByHandIsSwitchedToNTPAndBack() async throws {
        var documents = FakeSetupCamera.defaultDocuments()
        documents[HikvisionISAPI.timePath] = FakeSetupCamera.time.replacingOccurrences(of: "<timeMode>NTP</timeMode>", with: "<timeMode>manual</timeMode>")
        let camera = try await FakeSetupCamera.start(documents: documents)
        defer { camera.stop() }
        let service = hikvision(camera)
        let backup = try #require(try await service.readTimeSource(server: "192.0.2.10").1)
        #expect(backup.mode == "manual")
        #expect(try await service.applyTimeSource(server: "192.0.2.10").succeeded)
        let put = try #require(camera.puts(to: HikvisionISAPI.timePath).last)
        #expect(put.contains("<timeMode>NTP</timeMode>") && !put.contains("localTime"))
        #expect(try await service.restoreTimeSource(backup).succeeded)
        let restored = try #require(camera.puts(to: HikvisionISAPI.timePath).last)
        #expect(restored.contains("<timeMode>manual</timeMode>") && restored.contains("<localTime>"), "a clock set by hand is given a time")
    }

    @Test func rebootRequiredIsNotedAndNotActedOn() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        camera.rebootRequired.update { $0.insert(HikvisionISAPI.ntpServerPath) }
        let outcome = try await hikvision(camera).applyTimeSource(server: "192.0.2.10")
        #expect(outcome == CameraSetupOutcome(succeeded: true, needsRestart: true, detail: "via ISAPI"))
        #expect(!camera.server.requests.contains { $0.path.contains("reboot") }, "the bridge never restarts the camera")
    }

    @Test func theCloudIsTurnedOffWithoutKeepingItsVerificationCode() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let service = hikvision(camera)

        let (reading, backup) = try await service.readFeature(.cloud)
        #expect(reading.changes == [.init(label: "Hik-Connect (the maker’s cloud)", now: "on", after: "off")])
        #expect(backup == CameraFeatureBackup(path: "/ISAPI/System/Network/EZVIZ", enabled: true))
        let saved = String(decoding: try JSONEncoder().encode(backup), as: UTF8.self)
        #expect(!saved.contains(FakeSetupCamera.verificationCode), "the camera's secret is not saved")

        #expect(try await service.setFeature(.cloud, enabled: false, path: backup?.path) == CameraSetupOutcome(succeeded: true, detail: "via ISAPI"))
        let put = try #require(camera.puts(to: "/ISAPI/System/Network/EZVIZ").last)
        #expect(put.contains("<enabled>false</enabled>") && put.contains("<registerStatus>true</registerStatus>"))
        #expect(try await service.readFeature(.cloud).0.state == .alreadyRight)
        #expect(try await service.setFeature(.cloud, enabled: false).detail == "already off", "running it again writes nothing")
        #expect(camera.puts(to: "/ISAPI/System/Network/EZVIZ").count == 1)

        #expect(try await service.setFeature(.cloud, enabled: true, path: backup?.path).succeeded)
        #expect(camera.documents.value["/ISAPI/System/Network/EZVIZ"] == FakeSetupCamera.cloud, "the document is exactly as it was")
    }

    @Test func aRefusalIsReportedInTheCamerasWords() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        camera.refusePUT.update { $0.insert("/ISAPI/System/Network/EZVIZ") }
        let outcome = try await hikvision(camera).setFeature(.cloud, enabled: false)
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: "Invalid Content (badParameters)"))
    }

    @Test func aWriteThatDoesNotStickIsARefusal() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        camera.ignorePUT.update { $0.insert("/ISAPI/System/Network/UPnP") }
        let outcome = try await hikvision(camera).setFeature(.upnp, enabled: false)
        #expect(outcome == CameraSetupOutcome(succeeded: false, detail: "the camera kept it on"))
    }

    @Test func theCloudsPathIsFoundAndAMissingFeatureIsNotSupported() async throws {
        var documents = FakeSetupCamera.defaultDocuments()
        documents["/ISAPI/System/Network/Ezviz"] = documents.removeValue(forKey: "/ISAPI/System/Network/EZVIZ")
        documents[HikvisionISAPI.networkCapabilitiesPath] = FakeSetupCamera.networkCapabilities
            .replacingOccurrences(of: "<isSupportUPnP>true</isSupportUPnP>", with: "<isSupportUPnP>false</isSupportUPnP>")
        let camera = try await FakeSetupCamera.start(documents: documents)
        defer { camera.stop() }
        let service = hikvision(camera)
        #expect(try await service.readFeature(.cloud).1?.path == "/ISAPI/System/Network/Ezviz")
        #expect(try await service.readFeature(.upnp).0.state == .notSupported("not supported by this camera"))
        #expect(camera.server.requests(path: "/ISAPI/System/Network/UPnP").isEmpty, "the capabilities say so: not even asked")
        // A camera without the capabilities document and without the resource.
        camera.documents.update { $0[HikvisionISAPI.networkCapabilitiesPath] = nil; $0["/ISAPI/System/Network/Ezviz"] = nil }
        #expect(try await service.readFeature(.cloud).0.state == .notSupported("not supported by this camera"))
    }

    @Test func otherCamerasHaveNoCloudOrUPnPStep() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)
        #expect(try await service.readFeature(.cloud).0.state == .notSupported("not supported by this camera"))
        #expect(try await service.readFeature(.upnp).0.state == .notSupported("not supported by this camera"))
    }

    @Test func theCamerasOwnLabelsAreListed() async throws {
        let camera = try await FakeSetupCamera.start()
        defer { camera.stop() }
        let reading = try await hikvision(camera).readCleanPicture()
        #expect(reading.changes == [.init(label: "The camera’s own labels", now: "date and time, camera name and text lines", after: "off (the bridge draws its own)")])
        camera.documents.update { $0["/ISAPI/System/Video/inputs/channels/1/overlays"] = FakeSetupCamera.overlays(on: false) }
        #expect(try await hikvision(camera).readCleanPicture().state == .alreadyRight)
    }

    // MARK: ONVIF

    @Test func onvifTimeZoneIsSetAndRestored() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let (reading, backup) = try await service.readTimeZone(posix: "MST7", zoneName: "America/Phoenix")
        #expect(reading.changes == [.init(label: "Time zone", now: "UTC−6 with daylight saving", after: "America/Phoenix (UTC−7)")])
        #expect(backup == CameraTimeZoneBackup(method: .onvifMinimal, value: "CST6CDT,M3.2.0,M11.1.0", daylightSavings: true))
        #expect(try await service.applyTimeZone(posix: "MST7") == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.clock.value.timeZone == "MST7" && !camera.clock.value.daylightSavings)
        #expect(try await service.restoreTimeZone(try #require(backup)).succeeded)
        #expect(camera.clock.value.timeZone == "CST6CDT,M3.2.0,M11.1.0" && camera.clock.value.daylightSavings)
    }

    @Test func onvifTimeSourceIsTheBridgeAndBack() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.clock.update { $0.type = "Manual" }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let (reading, backup) = try await service.readTimeSource(server: "192.0.2.10")
        #expect(reading.changes == [.init(label: "Time source", now: "set by hand", after: "NTP from the bridge (192.0.2.10)")])
        #expect(try await service.applyTimeSource(server: "192.0.2.10") == CameraSetupOutcome(succeeded: true, detail: "via ONVIF"))
        #expect(camera.clock.value.ntpServers == ["192.0.2.10"] && camera.clock.value.type == "NTP")
        #expect(camera.clock.value.timeZone == "CST6CDT,M3.2.0,M11.1.0", "the time zone is kept")
        #expect(try await service.readTimeSource(server: "192.0.2.10").0.state == .alreadyRight)

        #expect(try await service.restoreTimeSource(try #require(backup)).succeeded)
        #expect(camera.clock.value.ntpServers == ["pool.ntp.org"] && camera.clock.value.type == "Manual")
    }

    @Test func onvifRefusalsAndMissingTimeServers() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)
        camera.refuseClockChanges.set(true)
        let refused = try await service.applyTimeSource(server: "192.0.2.10")
        #expect(!refused.succeeded && refused.detail.contains("InvalidArgVal"))
        camera.noNTP.set(true)
        #expect(try await service.readTimeSource(server: "192.0.2.10").0.state == .notSupported("the camera does not show its time servers"))
    }
}
#endif
