// Loopback mock ISAPI, Reolink and ONVIF cameras (PlatformApple transport): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

/// Hiding a camera's own on-screen date/time (so only the CameraBridge timestamp shows) and putting it back: Hikvision
/// ISAPI, Reolink and ONVIF OSD, each read-modify-write with the previous state remembered, through the method chain.
@Suite(.timeLimit(.minutes(1))) struct CameraClockTests {
    private let isapiCredentials = HTTPCredentials(username: "admin", password: "pa55")
    private let reolinkCredentials = HTTPCredentials(username: "admin", password: "secret")
    private let onvifCredentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)

    /// An OSD element's children (serialized, each with its own namespace declaration) as a tree.
    private static func parse(_ children: String) throws -> XMLTree {
        try XMLTree.parse(Data("<root xmlns:tt=\"http://www.onvif.org/ver10/schema\">\(children)</root>".utf8))
    }

    // MARK: Pure pieces

    @Test func theDateTimeOverlayIsFlippedAndNothingElseInTheDocument() throws {
        let document = MockHikvisionCamera.overlayDocument(dateTimeEnabled: true)
        let edited = try #require(HikvisionISAPI.replacingEnabled(inSection: "DateTimeOverlay", in: document, enabled: false))
        let after = try XMLTree.parse(Data(edited.utf8))
        #expect(after.firstDescendant("DateTimeOverlay")?.string("enabled") == "false")
        #expect(after.firstDescendant("channelNameOverlay")?.string("enabled") == "true", "the channel name overlay keeps showing")
        #expect(edited.contains("<positionY>544</positionY>") && edited.contains("<displayWeek>true</displayWeek>"))
        #expect(edited.replacingOccurrences(of: "<enabled>false</enabled><positionX>0", with: "<enabled>true</enabled><positionX>0") == document)
        // And back.
        #expect(HikvisionISAPI.replacingEnabled(inSection: "DateTimeOverlay", in: edited, enabled: true) == document)
        #expect(HikvisionISAPI.replacingEnabled(inSection: "DateTimeOverlay", in: MockHikvisionCamera.overlayDocument(dateTimeEnabled: nil), enabled: false) == nil)
    }

    @Test func theVideoInputIsTheStreamingChannelsHundreds() {
        #expect(HikvisionISAPI.inputChannel(streamingChannelID: "101") == 1)
        #expect(HikvisionISAPI.inputChannel(streamingChannelID: "102") == 1)
        #expect(HikvisionISAPI.inputChannel(streamingChannelID: "402") == 4)
        #expect(HikvisionISAPI.inputChannel(streamingChannelID: "3") == 3)
        #expect(HikvisionISAPI.inputChannel(streamingChannelID: "junk") == 1)
        #expect(HikvisionISAPI.overlaysPath(inputChannel: 1) == "/ISAPI/System/Video/inputs/channels/1/overlays")
    }

    @Test func theMethodChainIsTheVendorsApiThenONVIFWithTheRememberedOneFirst() {
        #expect(CameraConfigMethod.clockOrder(vendor: .hikvision) == [.hikvisionISAPI, .onvifMinimal])
        #expect(CameraConfigMethod.clockOrder(vendor: .reolink) == [.reolinkAPI, .onvifMinimal])
        #expect(CameraConfigMethod.clockOrder(vendor: .onvif) == [.onvifMinimal])
        #expect(CameraConfigMethod.clockOrder(vendor: nil) == [.onvifMinimal])
        #expect(CameraConfigMethod.clockOrder(vendor: .hikvision, preferred: .onvifMinimal) == [.onvifMinimal, .hikvisionISAPI])
        #expect(CameraConfigMethod.clockOrder(vendor: .hikvision, preferred: .onvifFull) == [.onvifMinimal, .hikvisionISAPI], "the encoder's full/minimal split does not apply")
        #expect(CameraConfigMethod.clockOrder(vendor: .onvif, preferred: .hikvisionISAPI) == [.onvifMinimal])
        #expect(CameraConfigMethod.onvifFull.clockDisplayName == "ONVIF" && CameraConfigMethod.hikvisionISAPI.clockDisplayName == "ISAPI")
    }

    @Test func onvifOSDElementsAreParsedAndOnlyClocksAreRecognised() throws {
        let tree = try XMLTree.parse(Data("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>\
        <trt:GetOSDsResponse><trt:OSDs token="A">\(MockONVIFCamera.osdChildren(textType: "DateAndTime", text: nil))</trt:OSDs>\
        <trt:OSDs token="B">\(MockONVIFCamera.osdChildren(textType: "Time", text: nil))</trt:OSDs>\
        <trt:OSDs token="C">\(MockONVIFCamera.osdChildren(textType: "Plain", text: "Gate"))</trt:OSDs>\
        <trt:OSDs token="D"><tt:Type>Image</tt:Type></trt:OSDs></trt:GetOSDsResponse></s:Body></s:Envelope>
        """.utf8))
        let osds = (tree.firstDescendant("GetOSDsResponse")?.children("OSDs") ?? []).compactMap(ONVIFClient.parseOSD)
        #expect(osds.map(\.token) == ["A", "B", "C", "D"])
        #expect(osds.map(\.showsClock) == [true, true, false, false])
        #expect(osds[0].textType == "DateAndTime" && osds[3].textType == nil)
        let blank = try #require(ONVIFClient.blanked(children: osds[0].children))
        let blanked = try Self.parse(blank)
        #expect(blanked.child("TextString")?.string("Type") == "Plain" && !blank.contains("DateAndTime") && blanked.child("Position")?.string("Type") == "UpperLeft")
        #expect(ONVIFClient.blanked(children: "<tt:Type>Image</tt:Type>") == nil)
    }

    @Test func aHiddenClockRoundTripsThroughJSON() throws {
        let hidden = HiddenCameraClock(method: .onvifMinimal, wasShown: nil,
                                       removedOSDs: [.init(token: "OSD_1", children: "<tt:Type>Text</tt:Type>", how: .blanked)])
        #expect(try JSONDecoder().decode(HiddenCameraClock.self, from: JSONEncoder().encode(hidden)) == hidden)
        #expect(try JSONDecoder().decode(HiddenCameraClock.self, from: JSONEncoder().encode(HiddenCameraClock(method: .reolinkAPI, wasShown: false)))
            == HiddenCameraClock(method: .reolinkAPI, wasShown: false))
    }

    // MARK: Hikvision ISAPI

    @Test func hikvisionHidesTheClockByReadModifyWriteAndRemembersItWasShown() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: isapiCredentials, vendor: .hikvision)

        let change = try await service.hideCameraClock()

        #expect(change.succeeded && change.method == .hikvisionISAPI && change.failures.isEmpty)
        #expect(change.backup == HiddenCameraClock(method: .hikvisionISAPI, wasShown: true))
        #expect(change.summary == "via ISAPI")
        let put = try #require(camera.putOverlayDocuments.value.first)
        #expect(camera.putOverlayDocuments.value.count == 1 && put.input == "1")
        #expect(put.body.contains("<DateTimeOverlay><enabled>false</enabled>") && put.body.contains("<channelNameOverlay><enabled>true</enabled>"))
        #expect(put.body.contains("<normalizedScreenWidth>704</normalizedScreenWidth>"), "the whole document goes back, as read")
    }

    @Test func hikvisionPutsTheClockBackWhenToggledBack() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        let original = try #require(camera.overlayDocuments.value["1"])
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: isapiCredentials, vendor: .hikvision)
        let backup = try #require(try await service.hideCameraClock().backup)

        let restored = try await service.restoreCameraClock(backup)

        #expect(restored.succeeded && restored.method == .hikvisionISAPI)
        #expect(camera.overlayDocuments.value["1"] == original, "the camera's document is exactly as it was")
        #expect(camera.putOverlayDocuments.value.count == 2)
    }

    @Test func aClockTheCameraAlreadyHidIsLeftOffWhenRestored() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        camera.overlayDocuments.update { $0["1"] = MockHikvisionCamera.overlayDocument(dateTimeEnabled: false) }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: isapiCredentials, vendor: .hikvision)

        let change = try await service.hideCameraClock()
        let backup = try #require(change.backup)
        #expect(change.succeeded && backup.wasShown == false)
        #expect(camera.putOverlayDocuments.value.isEmpty, "nothing to write: it was already off")
        #expect(try await service.restoreCameraClock(backup).succeeded)
        #expect(camera.putOverlayDocuments.value.isEmpty, "and it stays off: the person had turned it off themselves")
    }

    @Test func aNVRChannelUsesItsOwnVideoInput() async throws {
        let camera = try await MockHikvisionCamera.start()
        defer { camera.stop() }
        camera.overlayDocuments.update { $0["4"] = MockHikvisionCamera.overlayDocument(dateTimeEnabled: true) }
        let url = URL(string: "rtsp://10.0.0.5:554/ISAPI/Streaming/channels/402")
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: isapiCredentials, vendor: .hikvision, mainStreamURL: url)

        #expect(try await service.hideCameraClock().succeeded)
        #expect(camera.putOverlayDocuments.value.map(\.input) == ["4"])
        #expect(camera.overlayDocuments.value["1"]?.contains("<DateTimeOverlay><enabled>true</enabled>") == true, "input 1 is not touched")
    }

    @Test func aCameraWithNoDateTimeOverlayIsNotSupportedGracefully() async throws {
        let camera = try await MockHikvisionCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { camera.stop(); onvif.stop() }
        camera.overlayDocuments.update { $0["1"] = MockHikvisionCamera.overlayDocument(dateTimeEnabled: nil) }
        onvif.osds.set([("OSD_Caption", MockONVIFCamera.osdChildren(textType: "Plain", text: "Gate"))])
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.server.port), onvifPort: Int(onvif.server.port))
        let service = CameraSettingsService(endpoint: endpoint, credentials: HTTPCredentials(username: "admin", password: MockONVIFCamera.password), vendor: .hikvision)

        let change = try await service.hideCameraClock()

        #expect(!change.succeeded && change.isUnsupported)
        #expect(change.failures.map(\.method) == [.hikvisionISAPI, .onvifMinimal])
        #expect(change.summary == "not supported by this camera")
        #expect(camera.putOverlayDocuments.value.isEmpty && !onvif.osdCalls.value.contains { $0.hasPrefix("DeleteOSD") })
    }

    @Test func aChangeTheCameraIgnoresIsNotReportedAsDoneAndTheChainGoesOn() async throws {
        let isapi = try await MockHikvisionCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { isapi.stop(); onvif.stop() }
        isapi.ignoreOverlayPUT.set(true)
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(isapi.server.port), onvifPort: Int(onvif.server.port))
        let service = CameraSettingsService(endpoint: endpoint, credentials: HTTPCredentials(username: "admin", password: MockONVIFCamera.password), vendor: .hikvision)

        let change = try await service.hideCameraClock()

        #expect(change.succeeded && change.method == .onvifMinimal, "ISAPI answered success but the document read back unchanged, so ONVIF did it")
        #expect(change.failures.map(\.failure) == [.didNotStick])
        #expect(onvif.osdCalls.value.contains("DeleteOSD:OSD_DateTime"))
    }

    @Test func theRememberedMethodGoesFirst() async throws {
        let isapi = try await MockHikvisionCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { isapi.stop(); onvif.stop() }
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(isapi.server.port), onvifPort: Int(onvif.server.port))
        let service = CameraSettingsService(endpoint: endpoint, credentials: HTTPCredentials(username: "admin", password: MockONVIFCamera.password),
                                            vendor: .hikvision, preferredMethod: .onvifMinimal)
        let change = try await service.hideCameraClock()
        #expect(change.method == .onvifMinimal && isapi.putOverlayDocuments.value.isEmpty)
    }

    // MARK: Reolink

    @Test func reolinkHidesAndRestoresTheTimeKeepingTheRestOfTheOsd() async throws {
        let camera = try await MockReolinkCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: reolinkCredentials, vendor: .reolink)

        let change = try await service.hideCameraClock()

        #expect(change.succeeded && change.method == .reolinkAPI && change.backup == HiddenCameraClock(method: .reolinkAPI, wasShown: true))
        let sent = try #require(camera.setOsdBodies.value.first)
        let body = try JSONValue.parse(Data(sent.utf8))
        let osd = try #require(body[0]?["param"]?["Osd"])
        #expect(osd["osdTime"]?["enable"]?.int == 0 && osd["osdTime"]?["pos"]?.string == "Top Center")
        #expect(osd["osdChannel"]?["enable"]?.int == 1 && osd["osdChannel"]?["name"]?.string == "Camera1" && osd["watermark"]?.int == 1)
        #expect(camera.logouts.value.count >= 1, "the API session is ended")

        let backup = try #require(change.backup)
        #expect(try await service.restoreCameraClock(backup).succeeded)
        let after = try JSONValue.parse(Data(try #require(camera.osd.value).utf8))
        #expect(after["osdTime"]?["enable"]?.int == 1)
    }

    @Test func reolinkReadsBackAndFallsThroughWhenSetOsdDoesNotStick() async throws {
        let reolink = try await MockReolinkCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { reolink.stop(); onvif.stop() }
        reolink.ignoreSetOsd.set(true)
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(reolink.server.port), onvifPort: Int(onvif.server.port))
        let service = CameraSettingsService(endpoint: endpoint, credentials: HTTPCredentials(username: "admin", password: MockONVIFCamera.password), vendor: .reolink)
        // The Reolink mock only knows its own password: the API fails on login, and ONVIF takes over.
        let change = try await service.hideCameraClock()
        #expect(change.succeeded && change.method == .onvifMinimal)
        #expect(change.failures.first?.method == .reolinkAPI)
    }

    @Test func reolinkWithoutOsdSupportIsNotSupported() async throws {
        let reolink = try await MockReolinkCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { reolink.stop(); onvif.stop() }
        reolink.osd.set(nil)
        onvif.osds.set([])
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(reolink.server.port), onvifPort: Int(onvif.server.port))
        let service = CameraSettingsService(endpoint: endpoint, credentials: reolinkCredentials, vendor: .reolink)

        let change = try await service.hideCameraClock()
        #expect(!change.succeeded && change.isUnsupported && change.summary == "not supported by this camera")
    }

    // MARK: ONVIF OSD

    @Test func onvifDeletesOnlyTheClockAndRecreatesItWhenToggledBack() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let change = try await service.hideCameraClock()

        #expect(change.succeeded && change.method == .onvifMinimal && change.summary == "via ONVIF")
        let backup = try #require(change.backup)
        #expect(backup.removedOSDs.map(\.token) == ["OSD_DateTime"] && backup.removedOSDs.first?.how == .deleted)
        #expect(try Self.parse(try #require(backup.removedOSDs.first).children).child("TextString")?.string("Type") == "DateAndTime")
        #expect(camera.osds.value.map(\.token) == ["OSD_Caption"], "the caption stays")
        #expect(camera.osdCalls.value.filter { $0.hasPrefix("DeleteOSD") } == ["DeleteOSD:OSD_DateTime"])

        let restored = try await service.restoreCameraClock(backup)
        #expect(restored.succeeded && restored.method == .onvifMinimal)
        #expect(camera.osdCalls.value.contains("CreateOSD"))
        let tokens = camera.osds.value.map(\.token)
        #expect(tokens.count == 2 && tokens.contains("OSD_Caption"))
        let created = try #require(camera.osds.value.first { $0.token != "OSD_Caption" })
        let element = try Self.parse(created.children)
        #expect(element.child("TextString")?.string("Type") == "DateAndTime" && element.child("Position")?.string("Type") == "UpperLeft",
                "the camera's own element, as it was")
    }

    @Test func aCameraThatWillNotDeleteItsClockHasItBlankedAndRestored() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.osdMode.set(.refuseDelete)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let change = try await service.hideCameraClock()

        let backup = try #require(change.backup)
        #expect(change.succeeded && backup.removedOSDs.first?.how == .blanked)
        #expect(camera.osdCalls.value.contains("DeleteOSD:OSD_DateTime") && camera.osdCalls.value.contains("SetOSD:OSD_DateTime"))
        let blankedElement = try #require(camera.osds.value.first { $0.token == "OSD_DateTime" })
        #expect(try Self.parse(blankedElement.children).child("TextString")?.string("Type") == "Plain" && !blankedElement.children.contains("DateAndTime"))

        #expect(try await service.restoreCameraClock(backup).succeeded)
        let back = try #require(camera.osds.value.first { $0.token == "OSD_DateTime" })
        #expect(back.children.contains("DateAndTime"))
    }

    @Test func aChangeTheCameraIgnoresFailsAndLeavesNothingRemoved() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.osdMode.set(.ignoreChanges)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let change = try await service.hideCameraClock()

        #expect(!change.succeeded && change.backup == nil && change.failures.map(\.failure) == [.didNotStick])
        #expect(camera.osds.value.count == 2)
    }

    @Test func aCameraThatRefusesEveryChangeReportsWhyNotThatItIsUnsupported() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.osdMode.set(.refuseAll)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let change = try await service.hideCameraClock()

        #expect(!change.succeeded && !change.isUnsupported)
        #expect(change.summary == "ONVIF: InvalidArgVal")
    }

    @Test func aCameraWithNoClockElementIsNotSupported() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.osds.set([("OSD_Caption", MockONVIFCamera.osdChildren(textType: "Plain", text: "Gate"))])
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let change = try await service.hideCameraClock()
        #expect(change.isUnsupported && change.summary == "not supported by this camera")
        #expect(!camera.osdCalls.value.contains { $0.hasPrefix("DeleteOSD") || $0.hasPrefix("SetOSD") })
    }

    @Test func aRejectedLoginEndsTheChainAndLaterCallsSendNothing() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: "127.0.0.1:\(camera.server.port)") }
        camera.rejectCredentials.set(true)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let change = try await service.hideCameraClock()
        // The camera refused the login (and the login guard now holds ONVIF logins to this host back): a credential
        // problem, which ends the chain.
        #expect(!change.succeeded && change.failures.count == 1 && change.failures.first?.failure.stopsChain == true)
        let seen = camera.actions.value.count
        let again = try await service.hideCameraClock()
        #expect(again.failures.first?.failure.stopsChain == true)
        #expect(camera.actions.value.count == seen, "no further login attempts: they would only lock the camera")
    }

    @Test func aLockedOutCameraIsNotTriedAtAll() async throws {
        let camera = try await MockONVIFCamera.start()
        let host = "127.0.0.1:\(camera.server.port)"
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        let until = ONVIFLoginGuard.shared.recordLockout(host: host)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: onvifCredentials, vendor: .onvif)

        let change = try await service.hideCameraClock()
        #expect(!change.succeeded && change.failures.map(\.failure) == [.lockedOut(until: until)])
        #expect(!camera.actions.value.contains("GetOSDs"))
        let restore = try await service.restoreCameraClock(HiddenCameraClock(method: .onvifMinimal))
        #expect(!restore.succeeded && restore.failures.first?.failure.stopsChain == true)
    }

    @Test func aBackupMadeThroughONVIFIsRestoredThroughONVIFOnAHikvisionCamera() async throws {
        let isapi = try await MockHikvisionCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { isapi.stop(); onvif.stop() }
        isapi.overlayDocuments.update { $0["1"] = MockHikvisionCamera.overlayDocument(dateTimeEnabled: nil) }
        let endpoint = CameraEndpoint(host: "127.0.0.1", httpPort: Int(isapi.server.port), onvifPort: Int(onvif.server.port))
        let service = CameraSettingsService(endpoint: endpoint, credentials: HTTPCredentials(username: "admin", password: MockONVIFCamera.password), vendor: .hikvision)
        let backup = try #require(try await service.hideCameraClock().backup)
        #expect(backup.method == .onvifMinimal, "ISAPI has no date/time overlay on this camera, so ONVIF hid it")
        #expect(try await service.restoreCameraClock(backup).method == .onvifMinimal)
        #expect(isapi.putOverlayDocuments.value.isEmpty)
    }
}
#endif
