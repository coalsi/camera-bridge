import CameraAdapters
import Testing
@testable import BridgeEngine

/// A camera's ONVIF can name the wrong codec: a Jennov JM800S5 answered H.264 for both streams while its RTSP streams were H.265 (the
/// bridge measured "hevc"). The streams step of "Set up for Camera Bridge" (and Optimize, which plans the same way) must plan from the
/// codec the bridge really receives, and the check after the setup must say when the camera still sends something else.
@MainActor @Suite struct CameraSetupMeasuredCodecTests {
    private func settings(_ encoding: String, width: Int, height: Int, fps: Double = 20, bitrate: Int = 3000, gov: Int = 40) -> CameraVideoEncoderSettings {
        CameraVideoEncoderSettings(token: "enc", name: "enc", encoding: encoding, resolution: CameraResolution(width: width, height: height),
                                   frameRate: fps, bitrate: bitrate, iFrameInterval: gov)
    }

    @Test func aMainStreamThatSaysH264ButSendsH265IsPlannedAsACodecChange() {
        let main = settings("H264", width: 3840, height: 2160)
        let plans = BridgeEngine.plannedEncoderFixes(main: main, mainProfile: nil, sub: nil, subProfile: nil, mainHasBFrames: false,
                                                     mainMeasuredCodec: "HEVC")
        let plan = try? #require(plans.first { !$0.isSub })
        #expect(plan?.fixes.contains("codec") == true)
        #expect(plan?.edit.desired.encoding == "H264")
        #expect(plan?.before.encoding == "H264", "what Restore writes back stays what the camera reported")
        #expect(plan?.edit.rewriteCodec == true, "the codec is written although the camera already names it")
    }

    @Test func aMeasuredH264OrNoMeasurementPlansAsBefore() {
        let main = settings("H264", width: 3840, height: 2160)
        #expect(BridgeEngine.plannedEncoderFixes(main: main, mainProfile: nil, sub: nil, subProfile: nil, mainHasBFrames: false,
                                                 mainMeasuredCodec: "H264").isEmpty)
        #expect(BridgeEngine.plannedEncoderFixes(main: main, mainProfile: nil, sub: nil, subProfile: nil, mainHasBFrames: false,
                                                 mainMeasuredCodec: nil).isEmpty)
    }

    @Test func aSubStreamThatSaysH264ButSendsH265IsPlannedToo() {
        let sub = settings("H264", width: 720, height: 480)
        let plans = BridgeEngine.plannedEncoderFixes(main: nil, mainProfile: nil, sub: sub, subProfile: nil, mainHasBFrames: false,
                                                     subMeasuredCodec: "HEVC")
        #expect(plans.count == 1)
        #expect(plans.first?.isSub == true)
        #expect(plans.first?.edit.desired.encoding == "H264")
        #expect(plans.first?.edit.rewriteCodec == true)
    }

    @Test func aCameraWithoutH264IsNotAskedForItBecauseOfTheMeasurement() {
        let options = [CameraVideoEncoderOptions(encoding: "H265", resolutions: [CameraResolution(width: 3840, height: 2160)])]
        let profile = CameraVideoProfile(id: "p", name: "p", settings: settings("H265", width: 3840, height: 2160), options: options)
        let plans = BridgeEngine.plannedEncoderFixes(main: settings("H265", width: 3840, height: 2160), mainProfile: profile, sub: nil, subProfile: nil,
                                                     mainHasBFrames: false, mainMeasuredCodec: "HEVC")
        #expect(plans.first?.fixes.contains("codec") != true)
    }

    @Test func thePreviewShowsTheCodecTheCameraReallySends() {
        #expect(BridgeEngine.measuredCodecMismatch(reported: "H264", measured: "HEVC") == "H.265")
        #expect(BridgeEngine.measuredCodecMismatch(reported: "H.264", measured: "H264") == nil)
        #expect(BridgeEngine.measuredCodecMismatch(reported: "H264", measured: nil) == nil)
        #expect(BridgeEngine.measuredCodecMismatch(reported: "H265", measured: "HEVC") == nil)
        #expect(BridgeEngine.measuredCodecMismatch(reported: "H265", measured: "H264") == "H.264")
    }

    @Test func theCheckAfterTheSetupSaysWhenTheCameraStillSendsH265() {
        let main = settings("H264", width: 3840, height: 2160)
        let sub = settings("H264", width: 720, height: 480)
        let plans = BridgeEngine.plannedEncoderFixes(main: main, mainProfile: nil, sub: sub, subProfile: nil, mainHasBFrames: false,
                                                     mainMeasuredCodec: "HEVC", subMeasuredCodec: "HEVC")
        #expect(BridgeEngine.streamsStillWrong(planned: plans, measuredMain: "H264", measuredSub: "H264") == nil)
        #expect(BridgeEngine.streamsStillWrong(planned: plans, measuredMain: "HEVC", measuredSub: "H264")
            == "The camera says its main stream is H.264 but still sends H.265.")
        #expect(BridgeEngine.streamsStillWrong(planned: plans, measuredMain: "HEVC", measuredSub: "HEVC")
            == "The camera says its main and sub streams are H.264 but still sends H.265.")
        #expect(BridgeEngine.streamsStillWrong(planned: plans, measuredMain: nil, measuredSub: nil) == nil, "nothing measured yet: not a failure")
    }

    @Test func theCheckIgnoresStreamsThatWereNotChanged() {
        let main = settings("H264", width: 3840, height: 2160, gov: 80)   // only the keyframe interval changes
        let plans = BridgeEngine.plannedEncoderFixes(main: main, mainProfile: nil, sub: nil, subProfile: nil, mainHasBFrames: false)
        #expect(plans.count == 1)
        #expect(BridgeEngine.streamsStillWrong(planned: plans, measuredMain: "H264", measuredSub: "HEVC") == nil)
    }
}

#if canImport(Darwin)
import BridgeSupport
import Foundation
import Synchronization

/// The same through the engine, against the loopback fake Hikvision of `CameraSetupEngineTests` changed to report an H.264 main stream
/// with a 2 s keyframe and no smart codec (right by its own settings), while the bridge measures H.265 (`EngineTuning.measuredStreamFacts`).
@MainActor @Suite(.timeLimit(.minutes(1))) struct CameraSetupMeasuredCodecEngineTests {
    typealias FakeHikvision = CameraSetupEngineTests.FakeHikvision

    /// `takesTheCodec`: whether the camera sends H.264 once the setup has written its main stream's settings (else it keeps H.265);
    /// `lateBy`: how many measurements after the write still show H.265 (a camera that switches a few seconds later); `mainSize`: the
    /// measured main stream's size (nil: not measured).
    private func fixture(takesTheCodec: Bool, lateBy: Int = 0, mainSize: (Int, Int)? = (3840, 2160), wait: Duration = .seconds(1)) async throws
        -> (EngineFixture, FakeHikvision, CameraConfiguration) {
        let camera = try await FakeHikvision()
        let afterWrite = Mutex(0)
        var tuning = EngineTuning.testing
        tuning.interfaceAddresses = { [InterfaceAddress(interface: "en0", address: "192.0.2.10", prefixLength: 24)] }
        tuning.cameraSetupMeasureWait = wait
        tuning.measuredStreamFacts = { _ in
            let written = camera.puts.value.contains { $0.contains("/ISAPI/Streaming/channels/101") }
            let seen = written ? afterWrite.withLock { count in count += 1; return count } : 0
            let h264 = written && takesTheCodec && seen > lateBy
            return (MeasuredStreamFacts(codec: h264 ? "H264" : "HEVC", width: mainSize?.0, height: mainSize?.1), MeasuredStreamFacts(codec: "H264"))
        }
        let fixture = try await EngineFixture(tuning: tuning, servesTime: false)
        camera.documents.update {
            $0["/ISAPI/Streaming/channels/101"] = FakeHikvision.channel("101", codec: "H.264", width: 3840, height: 2160, smart: false)
                .replacingOccurrences(of: "<GovLength>50</GovLength>", with: "<GovLength>40</GovLength>")
            $0["/ISAPI/Streaming/channels/102"] = FakeHikvision.channel("102", codec: "H.264", width: 640, height: 480, smart: false)
                .replacingOccurrences(of: "<GovLength>50</GovLength>", with: "<GovLength>40</GovLength>")
        }
        var configuration = CameraConfiguration(name: "Gate", kind: .camera, vendor: .hikvision,
                                                endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.port), onvifPort: Int(camera.port)),
                                                username: "admin")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: "pa55")
        return (fixture, camera, configuration)
    }

    @Test func aStreamThatIsRightByItsSettingsButSendsH265IsChangedAndThePreviewSaysWhy() async throws {
        let (fixture, camera, configuration) = try await fixture(takesTheCodec: true)
        defer { camera.stop(); fixture.directory.remove() }

        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let streams = try #require(preview.steps.first { $0.id == .streams })
        #expect(streams.status == .willChange)
        #expect(streams.changes.map(\.label) == ["Main stream"])
        #expect(streams.changes.first?.now.hasPrefix("H.265, 3840×2160") == true, "the codec it really sends")
        #expect(streams.changes.first?.after.hasPrefix("H.264, 3840×2160") == true)
        #expect(streams.detail?.contains("The camera says its main stream is H.264, but it sends H.265.") == true)

        // The camera takes the setting and the bridge then receives H.264: done.
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let done = report.steps.first { $0.id == .streams }
        #expect(done?.status == .done, "\(String(describing: done?.status)) \(done?.detail ?? "") puts: \(camera.puts.value)")
        #expect(done?.detail?.contains("but it sends") != true, "the note about the camera before the change goes once it is changed")
        #expect(report.mayNeedRecordingReEnabled)
        #expect(camera.documents.value["/ISAPI/Streaming/channels/101"]?.contains("<videoCodecType>H.264</videoCodecType>") == true)
    }

    @Test func aCameraThatSwitchesAFewSecondsLaterIsDone() async throws {
        let (fixture, camera, configuration) = try await fixture(takesTheCodec: true, lateBy: 2, wait: .seconds(10))
        defer { camera.stop(); fixture.directory.remove() }

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(report.steps.first { $0.id == .streams }?.status == .done)
    }

    @Test func aMeasurementOfAnotherSizeIsNotTakenForTheStream() async throws {
        // A camera whose profiles are matched to the wrong stream (Dahua's addresses differ only in their query): the measurement is
        // 640×480 while the planned main stream is 3840×2160, so it says nothing about that stream.
        let (fixture, camera, configuration) = try await fixture(takesTheCodec: false, mainSize: (640, 480))
        defer { camera.stop(); fixture.directory.remove() }

        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        #expect(preview.steps.first { $0.id == .streams }?.status == .alreadyRight)
    }

    @Test func noCodecChangeMeansNoWait() async throws {
        // Only the sub stream's keyframe interval changes: nothing is waited for, even with a long wait and nothing measured.
        let (fixture, camera, configuration) = try await fixture(takesTheCodec: true, mainSize: nil, wait: .seconds(30))
        defer { camera.stop(); fixture.directory.remove() }
        camera.documents.update {
            $0["/ISAPI/Streaming/channels/102"] = FakeHikvision.channel("102", codec: "H.264", width: 640, height: 480, smart: false)
        }
        let started = ContinuousClock.now
        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(report.steps.first { $0.id == .streams }?.status == .done)
    }

    @Test func aCameraThatStillSendsH265AfterTheSetupIsReportedNotDone() async throws {
        let (fixture, camera, configuration) = try await fixture(takesTheCodec: false)
        defer { camera.stop(); fixture.directory.remove() }

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        let streams = try #require(report.steps.first { $0.id == .streams })
        #expect(streams.status == .refused)
        #expect(streams.detail == "The camera says its main stream is H.264 but still sends H.265.")
        let saved = fixture.engine.configurations.first { $0.id == configuration.id }?.setupState
        #expect(saved?.steps.first { $0.id == .streams }?.status == .refused, "the camera page shows it too")
        #expect(report.canRestore, "the old settings are kept for Restore")
        #expect(!report.mayNeedRecordingReEnabled, "the recordings' codec did not change")
    }

    /// Through ONVIF (the Jennov's way): the Tapo fake's main stream is right by its settings (H.264, a keyframe every 2 s), the bridge
    /// measures H.265, so the setup writes the main stream's encoder configuration although only the codec it already names is in it.
    @Test func throughONVIFTheCodecIsWrittenAlthoughTheCameraAlreadyNamesIt() async throws {
        var tuning = EngineTuning.testing
        tuning.measuredStreamFacts = { _ in (MeasuredStreamFacts(codec: "HEVC"), MeasuredStreamFacts(codec: "H264")) }
        tuning.cameraSetupMeasureWait = .seconds(1)
        let fixture = try await EngineFixture(tuning: tuning)
        let camera = try await CameraSetupJPEGProfileTests.FakeTapo()
        defer { camera.stop(); fixture.directory.remove() }
        var configuration = CameraConfiguration(name: "Patio", kind: .camera, vendor: .onvif,
                                                endpoint: CameraEndpoint(host: "127.0.0.1", httpPort: Int(camera.port), onvifPort: Int(camera.port)),
                                                username: "admin")
        configuration.mainStreamURL = URL(string: "rtsp://127.0.0.1:554/stream1")
        configuration.subStreamURL = URL(string: "rtsp://127.0.0.1:554/stream2")
        configuration.isEnabled = false
        try await fixture.engine.addCamera(configuration, password: "pa55")

        let preview = try await fixture.engine.cameraSetupPreview(cameraID: configuration.id)
        let streams = try #require(preview.steps.first { $0.id == .streams })
        #expect(streams.changes.first { $0.label == "Main stream" }?.now.hasPrefix("H.265, 2560×1440") == true)

        let report = try await fixture.engine.applyCameraSetup(cameraID: configuration.id)
        #expect(camera.encoderWrites.value.contains("000"), "the main stream's configuration is written")
        // The fake keeps sending what the measurement says (H.265): the setup says so instead of "done".
        #expect(report.steps.first { $0.id == .streams }?.status == .refused)
    }
}
#endif
