// Loopback mock ONVIF and ISAPI cameras (PlatformApple transport): macOS only.
#if os(macOS)
import BridgeSupport
import Foundation
import Testing
@testable import CameraAdapters

/// Encoder changes that try several methods (`CameraConfigMethod`), read each change back, and report which worked.
@Suite(.timeLimit(.minutes(1))) struct CameraConfigMethodTests {
    private let credentials = HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password)

    /// The main stream (ONVIF configuration "000") with only its keyframe interval and codec to reach.
    private func edit(gov: Int, options: [CameraVideoEncoderOptions] = []) -> CameraEncoderEdit {
        CameraEncoderEdit(isSub: false, desired: CameraVideoEncoderSettings(token: "000", name: "VideoEncoderConfig_main", encoding: "H264",
                                                                              iFrameInterval: gov), options: options)
    }

    private func hikvisionEndpoint(_ isapi: MockHikvisionCamera, _ onvif: MockONVIFCamera) -> CameraEndpoint {
        CameraEndpoint(host: "127.0.0.1", httpPort: Int(isapi.server.port), onvifPort: Int(onvif.server.port))
    }

    private func govLength(_ onvif: MockONVIFCamera, token: String = "000") async throws -> Int? {
        let service = CameraSettingsService(endpoint: onvif.endpoint, credentials: credentials)
        let snapshot = try await service.fetchSnapshot()
        return (token == "000" ? snapshot.mainProfile : snapshot.subProfile)?.settings.iFrameInterval
    }

    // MARK: Order and failures

    @Test func attemptOrderPerVendor() {
        #expect(CameraConfigMethod.attemptOrder(vendor: .hikvision) == [.hikvisionISAPI, .onvifMinimal, .onvifFull])
        #expect(CameraConfigMethod.attemptOrder(vendor: .reolink) == [.reolinkAPI, .onvifMinimal, .onvifFull])
        #expect(CameraConfigMethod.attemptOrder(vendor: .onvif) == [.onvifMinimal, .onvifFull])
        #expect(CameraConfigMethod.attemptOrder(vendor: nil) == [.onvifMinimal, .onvifFull])
        // The remembered method goes first (when the vendor has it); the rest keep their order.
        #expect(CameraConfigMethod.attemptOrder(vendor: .hikvision, preferred: .onvifFull) == [.onvifFull, .hikvisionISAPI, .onvifMinimal])
        #expect(CameraConfigMethod.attemptOrder(vendor: .onvif, preferred: .hikvisionISAPI) == [.onvifMinimal, .onvifFull])
    }

    @Test func onlyCredentialProblemsStopTheChain() {
        #expect(CameraConfigFailure.unauthorized.stopsChain)
        #expect(CameraConfigFailure.lockedOut(until: .now).stopsChain)
        for failure in [CameraConfigFailure.unsupported("x"), .rejected("InvalidArgVal"), .network("x"), .didNotStick] {
            #expect(!failure.stopsChain)
        }
        #expect(CameraConfigFailure.from(CameraAdapterError.soapFault("InvalidArgVal: the parameter value is illegal")) ==
            .rejected("InvalidArgVal: the parameter value is illegal"))
        #expect(CameraConfigFailure.from(CameraAdapterError.soapFault("ActionNotSupported: nope")) == .unsupported("ActionNotSupported: nope"))
        #expect(CameraConfigFailure.from(CameraAdapterError.httpStatus(404)) == .unsupported("HTTP 404"))
        #expect(CameraConfigFailure.from(CameraAdapterError.unauthorized) == .unauthorized)
        #expect(CameraConfigFailure.from(CameraAdapterError.soapFault("InvalidArgVal: x")).summary == "InvalidArgVal")
    }

    @Test func methodsDecodeFromTheirRawValueAndUnknownOnesDoNot() throws {
        #expect(CameraConfigMethod(rawValue: "hikvisionISAPI") == .hikvisionISAPI)
        #expect(CameraConfigMethod(rawValue: "somethingNewer") == nil)
        let data = try JSONEncoder().encode([CameraConfigMethod.onvifMinimal])
        #expect(try JSONDecoder().decode([CameraConfigMethod].self, from: data) == [.onvifMinimal])
    }

    // MARK: ONVIF minimal and full

    @Test func onvifFullRejectedThenMinimalSucceedsAndKeepsEveryOtherElement() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.setEncoderMode.set(.rejectSparseRequest)
        // The camera's last good method was the full request (so it is tried first).
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .onvif, preferredMethod: .onvifFull)

        let results = try await service.applyEncoder([edit(gov: 60)])

        let result = try #require(results.first)
        #expect(result.succeeded)
        #expect(result.method == .onvifMinimal)
        #expect(result.failures.map(\.method) == [.onvifFull])
        #expect(result.failures.first?.failure == .rejected("InvalidArgVal: the parameter value is illegal"))
        #expect(result.summary == "via ONVIF minimal")
        #expect(await service.memoryUpdate == .remember(.onvifMinimal))
        #expect(try await govLength(camera) == 60)

        // The minimal request is the camera's own configuration with only GovLength changed.
        let body = try #require(camera.setEncoderBodies.value.last)
        #expect(camera.setEncoderBodies.value.count == 2)
        // (each echoed element declares its own namespace, so match from the closing of the start tag)
        #expect(body.contains(">1</tt:UseCount>"))
        #expect(body.contains(">4</tt:Quality>"))
        #expect(body.contains(">000</tt:SourceToken>"))
        #expect(body.contains(">High</tt:H264Profile>"))
        #expect(body.contains(">3072</tt:BitrateLimit>"))
        #expect(body.contains(">60</tt:GovLength>"))
        #expect(body.contains("<trt:ForcePersistence>true</trt:ForcePersistence>"))
    }

    @Test func minimalIsTriedFirstWithoutAPreferenceAndTriesPersistenceFalseWhenTrueIsRefused() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.setEncoderMode.set(.rejectForcePersistenceTrue)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .onvif)

        let result = try #require(try await service.applyEncoder([edit(gov: 45)]).first)

        #expect(result.succeeded && result.method == .onvifMinimal && result.failures.isEmpty)
        #expect(camera.setEncoderBodies.value.count == 2)
        #expect(camera.setEncoderBodies.value[0].contains("<trt:ForcePersistence>true<"))
        #expect(camera.setEncoderBodies.value[1].contains("<trt:ForcePersistence>false<"))
        #expect(try await govLength(camera) == 45)
    }

    @Test func minimalClampsToTheCamerasReportedRange() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .onvif)
        let snapshot = try await service.fetchSnapshot()
        let main = try #require(snapshot.mainProfile)
        var desired = main.settings
        desired.bitrate = 20_000   // the camera reports 32…8192
        let edit = CameraEncoderEdit(isSub: false, desired: desired, options: main.options)

        let result = try #require(try await service.applyEncoder([edit]).first)

        #expect(result.succeeded && result.method == .onvifMinimal)
        #expect(try await service.fetchSnapshot().mainProfile?.settings.bitrate == 8192)
    }

    @Test func preferredFullMethodIsTriedFirst() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .onvif, preferredMethod: .onvifFull)

        let result = try #require(try await service.applyEncoder([edit(gov: 20)]).first)

        #expect(result.succeeded && result.method == .onvifFull && result.failures.isEmpty)
        // The full request is CameraBridge's own: no UseCount (that is the camera's element, only the minimal request echoes it).
        #expect(camera.setEncoderBodies.value.count == 1)
        #expect(!camera.setEncoderBodies.value[0].contains("UseCount"))
        #expect(try await govLength(camera) == 20)
    }

    @Test func nothingToChangeWritesNothing() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .onvif)

        let result = try #require(try await service.applyEncoder([edit(gov: 30)]).first)   // already 30

        #expect(result.succeeded && result.method == nil)
        #expect(camera.setVideoEncoderConfigurationCalls.value.isEmpty)
        #expect(await service.memoryUpdate == nil)
    }

    // MARK: Credential problems end the chain

    @Test func unauthorizedStopsTheChainWithoutTryingOtherMethods() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.rejectCredentials.set(true)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .onvif, preferredMethod: .onvifFull)

        let results = try await service.applyEncoder([edit(gov: 60), CameraEncoderEdit(isSub: true, desired: edit(gov: 60).desired)])

        #expect(results.allSatisfy { !$0.succeeded })
        // Only the first method ran (the client's own login guard may turn the rejection into a lockout: both end the chain).
        #expect(results[0].failures.count == 1)
        #expect(results[0].failures.first?.method == .onvifFull)
        #expect(results[0].failures.first?.failure.stopsChain == true)
        #expect(results[1].failures.count == 1)
        // At most one authenticated read in total: no second method, no second stream.
        #expect(camera.actions.value.filter { $0 == "GetVideoEncoderConfigurations" }.count <= 1)
        #expect(camera.setVideoEncoderConfigurationCalls.value.isEmpty)
        // A credential problem says nothing about the remembered method.
        #expect(await service.memoryUpdate == nil)
    }

    @Test func applyThrowsAConfigErrorListingEveryMethodsFailure() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.setEncoderMode.set(.rejectAll)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .onvif)

        await #expect(throws: CameraConfigError.self) { try await service.apply(CameraSettingsChange(mainEncoder: edit(gov: 60).desired)) }
        let results = try await service.applyEncoder([edit(gov: 60)])
        #expect(results[0].summary == "ONVIF minimal: InvalidArgVal; ONVIF full: InvalidArgVal")
    }

    // MARK: Hikvision: ISAPI

    @Test func hikvisionTriesISAPIFirstAndNeverTouchesONVIFWhenItWorks() async throws {
        let isapi = try await MockHikvisionCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { isapi.stop(); onvif.stop() }
        isapi.channelDocuments.update { $0["101"] = MockHikvisionCamera.encoderDocument(id: "101", gov: 100) }
        let service = CameraSettingsService(endpoint: hikvisionEndpoint(isapi, onvif), credentials: credentials, vendor: .hikvision)

        let result = try #require(try await service.applyEncoder([edit(gov: 50)]).first)

        #expect(result.succeeded && result.method == .hikvisionISAPI)
        #expect(await service.memoryUpdate == .remember(.hikvisionISAPI))
        #expect(isapi.putChannelDocuments.value.map(\.id) == ["101"])
        let stored = try #require(isapi.channelDocuments.value["101"])
        #expect(stored.contains("<GovLength>50</GovLength>"))
        // Everything else in the channel document is as the camera had it.
        #expect(stored.contains("<constantBitRate>8192</constantBitRate>") && stored.contains("<maxFrameRate>2500</maxFrameRate>"))
        #expect(camera(onvif, hasSetNothing: true))
    }

    private func camera(_ onvif: MockONVIFCamera, hasSetNothing: Bool) -> Bool {
        onvif.setVideoEncoderConfigurationCalls.value.isEmpty == hasSetNothing
    }

    @Test func onvifRejectedThenISAPISucceedsAndItsMethodIsRemembered() async throws {
        let isapi = try await MockHikvisionCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { isapi.stop(); onvif.stop() }
        isapi.channelDocuments.update { $0["101"] = MockHikvisionCamera.encoderDocument(id: "101", gov: 100) }
        onvif.setEncoderMode.set(.rejectAll)   // InvalidArgVal, as a Hikvision I91ET answers
        // The camera's remembered method is ONVIF minimal: tried first, refused, then ISAPI.
        let service = CameraSettingsService(endpoint: hikvisionEndpoint(isapi, onvif), credentials: credentials, vendor: .hikvision,
                                            preferredMethod: .onvifMinimal)

        let result = try #require(try await service.applyEncoder([edit(gov: 50)]).first)

        #expect(result.succeeded && result.method == .hikvisionISAPI)
        #expect(result.failures.map(\.method) == [.onvifMinimal])
        #expect(result.summary == "via ISAPI")
        #expect(await service.memoryUpdate == .remember(.hikvisionISAPI))
        #expect(isapi.channelDocuments.value["101"]?.contains("<GovLength>50</GovLength>") == true)
    }

    @Test func aWriteThatDoesNotStickFallsThroughToTheNextMethod() async throws {
        let isapi = try await MockHikvisionCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { isapi.stop(); onvif.stop() }
        isapi.channelDocuments.update { $0["101"] = MockHikvisionCamera.encoderDocument(id: "101", gov: 100) }
        isapi.ignoreChannelPUT.set(true)   // answers success, keeps the old document
        let service = CameraSettingsService(endpoint: hikvisionEndpoint(isapi, onvif), credentials: credentials, vendor: .hikvision)

        let result = try #require(try await service.applyEncoder([edit(gov: 50)]).first)

        #expect(isapi.channelPUTAttempts.value == 1)
        #expect(result.succeeded && result.method == .onvifMinimal)
        #expect(result.failures == [CameraConfigAttempt(method: .hikvisionISAPI, failure: .didNotStick)])
        #expect(try await govLength(onvif) == 50)
    }

    @Test func everyMethodNotStickingFailsAndForgetsTheRememberedMethod() async throws {
        let camera = try await MockONVIFCamera.start()
        defer { camera.stop() }
        camera.setEncoderMode.set(.acceptWithoutStoring)
        let service = CameraSettingsService(endpoint: camera.endpoint, credentials: credentials, vendor: .onvif, preferredMethod: .onvifMinimal)

        let result = try #require(try await service.applyEncoder([edit(gov: 60)]).first)

        #expect(!result.succeeded)
        #expect(result.failures.map(\.method) == [.onvifMinimal, .onvifFull])
        #expect(result.failures.allSatisfy { $0.failure == .didNotStick })
        #expect(await service.memoryUpdate == .forget)
    }

    @Test func undoUsesTheRememberedMethodFirst() async throws {
        let isapi = try await MockHikvisionCamera.start()
        let onvif = try await MockONVIFCamera.start()
        defer { isapi.stop(); onvif.stop() }
        isapi.channelDocuments.update { $0["101"] = MockHikvisionCamera.encoderDocument(id: "101", gov: 100) }
        isapi.rejectChannelPUT.set(true)   // this camera refuses ISAPI writes: ONVIF minimal is what works
        let endpoint = hikvisionEndpoint(isapi, onvif)

        // Optimize: ISAPI is refused, ONVIF minimal works; that is what gets remembered.
        let optimize = CameraSettingsService(endpoint: endpoint, credentials: credentials, vendor: .hikvision)
        let applied = try #require(try await optimize.applyEncoder([edit(gov: 60)]).first)
        #expect(applied.method == .onvifMinimal)
        let update = await optimize.memoryUpdate
        guard case .remember(let remembered)? = update else {
            Issue.record("expected a remembered method, got \(String(describing: update))")
            return
        }
        #expect(remembered == .onvifMinimal)
        #expect(isapi.channelPUTAttempts.value == 1)

        // Undo with the remembered method: ISAPI is not asked again.
        let undo = CameraSettingsService(endpoint: endpoint, credentials: credentials, vendor: .hikvision, preferredMethod: remembered)
        let restored = try #require(try await undo.applyEncoder([edit(gov: 30)]).first)
        #expect(restored.method == .onvifMinimal && restored.failures.isEmpty)
        #expect(isapi.channelPUTAttempts.value == 1)
        #expect(onvif.setVideoEncoderConfigurationCalls.value.count == 2)
    }

    @Test func hikvisionSettingsReadOverISAPIWhenONVIFCannotListProfiles() async throws {
        let isapi = try await MockHikvisionCamera.start()
        defer { isapi.stop() }
        isapi.channelDocuments.update { $0["102"] = MockHikvisionCamera.encoderDocument(id: "102", gov: 80, frameRate: 2000, bitrate: 1024) }
        let service = CameraSettingsService(endpoint: isapi.endpoint, credentials: credentials, vendor: .hikvision)

        let sub = try #require(try await service.hikvisionEncoderSettings(isSub: true))

        #expect(sub.encoding == "H264" && sub.token.isEmpty)
        #expect(sub.frameRate == 20 && sub.bitrate == 1024 && sub.iFrameInterval == 80)
        #expect(sub.resolution == CameraResolution(width: 1920, height: 1080))
    }

    // MARK: Pure helpers

    @Test func isapiDocumentEditsOnlyTheChangedElementsAndRefusesMissingOnes() throws {
        let document = MockHikvisionCamera.encoderDocument(id: "101", gov: 100)
        let edited = try #require(HikvisionISAPI.applying(EncoderValues(frameRate: 20, bitrate: 4096, govLength: 40), to: document))
        #expect(edited.contains("<GovLength>40</GovLength>") && edited.contains("<maxFrameRate>2000</maxFrameRate>"))
        #expect(edited.contains("<constantBitRate>4096</constantBitRate>") && edited.contains("<videoResolutionWidth>1920<"))
        let noGov = "<StreamingChannel><Video><videoCodecType>H.264</videoCodecType></Video></StreamingChannel>"
        #expect(HikvisionISAPI.applying(EncoderValues(govLength: 40), to: noGov) == nil)
        #expect(HikvisionISAPI.applying(EncoderValues(codec: "H265"), to: document)?.contains("<videoCodecType>H.265<") == true)
    }

    @Test func changesSkipFieldsTheCameraDoesNotReportAndSaySo() {
        let current = EncoderValues(codec: "H264", frameRate: 15)
        let desired = CameraVideoEncoderSettings(token: "1", name: "n", encoding: "H.264", frameRate: 15, iFrameInterval: 30)
        let (changes, unreadable) = current.changes(toReach: desired)
        #expect(changes.isEmpty)
        #expect(unreadable == ["keyframe interval"])
    }
}
#endif
