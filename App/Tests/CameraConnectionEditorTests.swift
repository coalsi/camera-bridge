import BridgeEngine
import CameraAdapters
import Foundation
import MediaCore
import Testing

/// The camera detail's Connection sheet: a changed address, ports or stream URLs are checked with the camera's stored
/// password, then saved for the same camera (same id: the Home accessory, its pairing and history stay). Before, the
/// only way to change them was to remove the camera and add it again as a new accessory.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CameraConnectionEditorTests {
    final class Recorder {
        var probed: [CameraConfiguration] = []
        var saved: [(endpoint: CameraEndpoint, main: URL?, sub: URL?)] = []
        var result: Result<CameraProbeResult, any Error> = .success(Samples.hikvisionProbe)
        /// Thrown by the save (the engine refused the change).
        var saveError: (any Error)?

        func editor(_ configuration: CameraConfiguration) -> CameraConnectionEditor {
            CameraConnectionEditor(configuration: configuration,
                                   probe: { [self] candidate in
                                       probed.append(candidate)
                                       return try result.get()
                                   },
                                   save: { [self] endpoint, main, sub in
                                       saved.append((endpoint, main, sub))
                                       if let saveError { throw saveError }
                                   })
        }
    }

    static var hikvision: CameraConfiguration {
        var camera = CameraEditorTests.sample
        camera.mainStreamURL = URL(string: "rtsp://192.0.2.21:554/Streaming/Channels/101")
        camera.subStreamURL = URL(string: "rtsp://192.0.2.21:554/Streaming/Channels/102")
        return camera
    }

    @Test func aNewAddressIsCheckedThenSavedForTheSameCamera() async throws {
        let recorder = Recorder()
        var answer = Samples.hikvisionProbe
        answer.mainStream?.url = URL(string: "rtsp://192.0.2.31:554/Streaming/Channels/101")!
        answer.subStream = nil
        recorder.result = .success(answer)
        let camera = Self.hikvision
        let editor = recorder.editor(camera)
        #expect(editor.host == "192.0.2.21" && editor.httpPort == 80 && editor.rtspPort == 554 && editor.onvifPort == nil)
        #expect(editor.mainStreamURLText == "rtsp://192.0.2.21:554/Streaming/Channels/101")
        #expect(!editor.canSave, "nothing changed yet")
        editor.host = " 192.0.2.31 "
        editor.httpPort = 8080
        #expect(editor.canSave && editor.problem == nil)

        #expect(await editor.save())
        let checked = try #require(recorder.probed.last)
        #expect(checked.id == camera.id && checked.vendor == .hikvision && checked.username == "admin")
        #expect(checked.endpoint == CameraEndpoint(host: "192.0.2.31", httpPort: 8080))
        #expect(checked.mainStreamURL == URL(string: "rtsp://192.0.2.31:554/Streaming/Channels/101"), "stream URLs on the old address follow it")
        #expect(checked.subStreamURL == URL(string: "rtsp://192.0.2.31:554/Streaming/Channels/102"))
        let saved = try #require(recorder.saved.last)
        #expect(saved.endpoint == checked.endpoint)
        #expect(saved.main == URL(string: "rtsp://192.0.2.31:554/Streaming/Channels/101"))
        #expect(saved.sub == URL(string: "rtsp://192.0.2.31:554/Streaming/Channels/102"), "kept when the camera reports no sub stream")
        #expect(editor.state == .editing)
    }

    @Test func aFailedCheckSavesNothing() async {
        let recorder = Recorder()
        recorder.result = .failure(CameraAdapterError.unauthorized)
        let editor = recorder.editor(Self.hikvision)
        editor.host = "192.0.2.31"
        #expect(await editor.save() == false)
        #expect(editor.state == .failed("The camera rejected the user name or password."))
        #expect(recorder.saved.isEmpty)
        editor.host = "192.0.2.32"
        #expect(editor.state == .editing, "editing again clears the failure")
    }

    /// Review finding (W4 App): a change that passed the check but that the engine couldn't save said only "The change
    /// couldn’t be saved." in the sheet; the reason went to the window's alert, queued behind the sheet until it closed.
    @Test func aFailedSaveSaysWhyInTheSheet() async {
        let recorder = Recorder()
        recorder.saveError = EngineError.configurationUnavailable("read-only")
        let editor = recorder.editor(Self.hikvision)
        editor.host = "192.0.2.31"
        #expect(await editor.save() == false)
        #expect(editor.state == .failed("Camera Bridge couldn’t read its configuration. The log in Settings has the details."))
        recorder.saveError = nil
        #expect(await editor.save())
        #expect(editor.state == .editing)
    }

    /// Review finding (W4 round 4): Cancel (or Escape) while "Checking the camera…" closed the sheet, but the check went
    /// on and then saved the new address (restarting the camera's runtime, cutting live views and recordings) — also an
    /// address the person cancelled because it was another camera's — and a failure went to a sheet nobody saw. Cancel
    /// stops the check, and nothing is saved after it.
    @Test func cancellingTheCheckSavesNothing() async {
        let recorder = Recorder()
        let gate = Gate()
        let editor = CameraConnectionEditor(configuration: Self.hikvision,
                                            probe: { candidate in
                                                recorder.probed.append(candidate)
                                                await gate.wait()   // like an engine call that doesn't check for cancellation
                                                return Samples.hikvisionProbe
                                            },
                                            save: { endpoint, main, sub in recorder.saved.append((endpoint, main, sub)) })
        editor.host = "192.0.2.31"
        let saving = editor.startSave()
        await settle { !recorder.probed.isEmpty }
        #expect(editor.state == .checking && !editor.canEdit, "the fields stay as checked")
        editor.cancel()
        gate.open()
        #expect(await saving.value == false)
        #expect(recorder.saved.isEmpty, "cancelled: the new address isn't saved")
        #expect(editor.state == .editing && editor.isClosed && !editor.canSave)
        #expect(await editor.save() == false && recorder.probed.count == 1, "a closed sheet checks nothing")
    }

    /// The check itself stops: a probe that honours cancellation (the engine's network calls) ends at once, and its
    /// failure is not reported to the closed sheet.
    @Test func cancellingStopsTheCheck() async {
        let recorder = Recorder()
        let editor = CameraConnectionEditor(configuration: Self.hikvision,
                                            probe: { candidate in
                                                recorder.probed.append(candidate)
                                                try await Task.sleep(for: .seconds(30))
                                                return Samples.hikvisionProbe
                                            },
                                            save: { endpoint, main, sub in recorder.saved.append((endpoint, main, sub)) })
        editor.host = "192.0.2.31"
        let started = ContinuousClock.now
        let saving = editor.startSave()
        await settle { !recorder.probed.isEmpty }
        editor.cancel()
        #expect(await saving.value == false)
        #expect(ContinuousClock.now - started < .seconds(10), "the check was cancelled")
        #expect(recorder.saved.isEmpty && editor.state == .editing)
    }

    /// Review finding (W4 App): Use HTTPS left the port at 80 (TLS to the HTTP port). Switching it moves a default port
    /// with it; a port the person chose stays.
    @Test func useHTTPSMovesTheDefaultPort() {
        let editor = Recorder().editor(Self.hikvision)
        #expect(editor.httpPortTitle == "HTTP Port")
        editor.useHTTPS = true
        #expect(editor.httpPort == 443 && editor.httpPortTitle == "HTTPS Port")
        #expect(editor.candidate?.endpoint == CameraEndpoint(host: "192.0.2.21", httpPort: 443, useHTTPS: true))
        editor.useHTTPS = false
        #expect(editor.httpPort == 80 && !editor.hasChanges)
        editor.httpPort = 8_443
        editor.useHTTPS = true
        #expect(editor.httpPort == 8_443, "a port the person entered stays")
    }

    @Test func plainRTSPCamerasEditTheirStreamURLs() async throws {
        let recorder = Recorder()
        recorder.result = .success(Samples.plainRTSPProbe)
        var camera = CameraConfiguration(name: "Side Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.24", rtspPort: 8554),
                                         username: "")
        camera.mainStreamURL = URL(string: "rtsp://192.0.2.24:8554/live")
        let editor = recorder.editor(camera)
        #expect(!editor.showsAddressFields)
        editor.mainStreamURLText = ""
        #expect(editor.problem == "Enter the main stream URL, starting with rtsp://.")
        editor.mainStreamURLText = "rtsp://viewer:pa55@192.0.2.44:7447/live"
        #expect(await editor.save())
        let checked = try #require(recorder.probed.last)
        #expect(checked.endpoint == CameraEndpoint(host: "192.0.2.44", rtspPort: 7447))
        #expect(checked.mainStreamURL == URL(string: "rtsp://192.0.2.44:7447/live"), "URLs never carry credentials")
        #expect(recorder.saved.last?.main == URL(string: "rtsp://192.0.2.44:7447/live"))
    }

    @Test func entriesAreValidated() {
        let editor = Recorder().editor(Self.hikvision)
        #expect(editor.showsAddressFields && editor.problem == nil)
        editor.host = ""
        #expect(editor.problem == "Enter the camera’s address." && !editor.canSave)
        editor.host = "192.0.2.21"
        editor.rtspPort = 0
        #expect(editor.problem == "Ports must be between 1 and 65535.")
        editor.rtspPort = 554
        editor.onvifPort = 70_000
        #expect(editor.problem == "Ports must be between 1 and 65535.")
        editor.onvifPort = nil
        editor.subStreamURLText = "http://192.0.2.21/sub"
        #expect(editor.problem == "The sub stream URL must start with rtsp://.")
        editor.subStreamURLText = ""
        #expect(editor.problem == nil)
    }

    /// Review finding (W4 round 2): `rtsps://` was accepted, but the engine's RTSP client speaks plain RTSP only. It is
    /// refused here too, and a camera saved with such a URL earlier says why it can't stream.
    @Test func rtspOverTLSIsRefusedWithAReason() {
        let editor = Recorder().editor(Self.hikvision)
        editor.mainStreamURLText = "rtsps://192.0.2.21:7441/live"
        #expect(editor.problem == AddCameraWizardModel.rtspOverTLSUnsupported && !editor.canSave)
        editor.mainStreamURLText = ""
        editor.subStreamURLText = "rtsps://192.0.2.21:7441/sub"
        #expect(editor.problem == AddCameraWizardModel.rtspOverTLSUnsupported)

        var plain = CameraConfiguration(name: "Side Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.24", rtspPort: 7441),
                                        username: "")
        plain.mainStreamURL = URL(string: "rtsps://192.0.2.24:7441/live")
        let rtsp = Recorder().editor(plain)
        #expect(rtsp.problem == AddCameraWizardModel.rtspOverTLSUnsupported)
        #expect(CameraConnectionEditor.unsupportedStreamNotice(for: plain) != nil)
        #expect(CameraConnectionEditor.unsupportedStreamNotice(for: Self.hikvision) == nil)
    }

    /// An ONVIF camera whose device service the check found on another port keeps that port.
    @Test func theONVIFPortTheCheckFoundIsSaved() async {
        let recorder = Recorder()
        var answer = Samples.plainONVIFProbe
        answer.onvifPort = 8000
        recorder.result = .success(answer)
        let camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .onvif, endpoint: CameraEndpoint(host: "192.0.2.32"), username: "admin")
        let editor = recorder.editor(camera)
        editor.host = "192.0.2.33"
        #expect(await editor.save())
        #expect(recorder.saved.last?.endpoint == CameraEndpoint(host: "192.0.2.33", onvifPort: 8000))
    }

    /// Saving goes through the detail form's editor: the camera keeps its id, and an edit in progress isn't lost.
    @Test func theChangeReachesTheEngineForTheSameCamera() async throws {
        let engine = FakeCameraEngine(Self.hikvision)
        let editor = engine.editor()
        editor.draft.name = "Driveway North"
        let endpoint = CameraEndpoint(host: "192.0.2.31", httpPort: 8080)
        let main = URL(string: "rtsp://192.0.2.31:554/Streaming/Channels/101")
        try await editor.changeConnection(endpoint: endpoint, mainStreamURL: main, subStreamURL: nil)
        let update = try #require(engine.updates.last)
        #expect(update.configuration.id == Self.hikvision.id && update.password == nil)
        #expect(update.configuration.endpoint == endpoint && update.configuration.mainStreamURL == main && update.configuration.subStreamURL == nil)
        #expect(update.configuration.name == "Driveway North")
        #expect(editor.draft.endpoint == endpoint && !editor.hasUnsavedEdits)

        engine.failUpdates = true
        await #expect(throws: FakeError.unreachable) {
            try await editor.changeConnection(endpoint: CameraEndpoint(host: "192.0.2.99"), mainStreamURL: nil, subStreamURL: nil)
        }
        #expect(editor.draft.endpoint == endpoint, "not applied: the form shows what the engine has")
        #expect(engine.alerts == 0, "the Connection sheet shows the reason itself, not an alert behind it")
        engine.configuration = nil   // removed meanwhile
        await #expect(throws: EngineError.unknownCamera) {
            try await editor.changeConnection(endpoint: CameraEndpoint(host: "192.0.2.98"), mainStreamURL: nil, subStreamURL: nil)
        }
    }

    /// A connection edit waiting for its turn survives an engine update of other fields.
    @Test func mergeKeepsConnectionEdits() {
        let base = Self.hikvision
        var edited = base
        edited.endpoint.host = "192.0.2.31"
        edited.mainStreamURL = URL(string: "rtsp://192.0.2.31/main")
        var latest = base
        latest.firmware = "V5.8"
        let merged = CameraEditor.merge(base: base, edited: edited, latest: latest)
        #expect(merged.endpoint.host == "192.0.2.31" && merged.mainStreamURL == URL(string: "rtsp://192.0.2.31/main") && merged.firmware == "V5.8")
    }
}
