import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import RTSP
import Testing
import TestSupport
@testable import BridgeWeb

@Suite(.timeLimit(.minutes(1))) struct CameraTypeAPITests {
    @Test func listsTheMacAppsTypesInOrderWithTheirWords() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let answer = await session.get("/api/v1/camera-types")
        #expect(answer.status == 200)
        let types = try #require(answer.json["types"] as? [[String: Any]])
        #expect(types.compactMap { $0["id"] as? String } == ["automatic", "hikvision", "reolink", "tapo", "amcrest", "doorbird", "wyzeRTSP", "rtspURL",
                                                             "unifiProtect", "ring", "googleNest", "wyzeCloud", "tuya", "otherCloud", "demo"])
        let automatic = try #require(types.first)
        #expect(automatic["title"] as? String == "ONVIF / RTSP Camera (Detect Automatically)")
        #expect(automatic["usesDiscovery"] as? Bool == true)
        #expect((automatic["setupSteps"] as? [String])?.count == 3)
        #expect(automatic["vendor"] is NSNull)
        let groups = try #require(answer.json["groups"] as? [[String: Any]])
        #expect(groups.compactMap { $0["title"] as? String } == ["Cameras on Your Network", "Consoles", "Cloud Cameras", "Try Camera Bridge"])
        #expect(answer.json["streamingHelperInstalled"] as? Bool == true)
        for type in types {
            #expect(!(type["summary"] as? String ?? "").isEmpty)
            #expect((type["setupSteps"] as? [String])?.isEmpty == false)
        }
        let cloud = types.filter { $0["group"] as? String == "cloud" }
        #expect(cloud.allSatisfy { $0["needsStreamingHelper"] as? Bool == true })
    }

    @Test func theDemoCameraCanBeLeftOut() async throws {
        let harness = try Harness { $0.offersDemoCamera = false }
        let session = try await harness.signIn()
        let types = try #require(await session.get("/api/v1/camera-types").json["types"] as? [[String: Any]])
        #expect(!types.contains { $0["id"] as? String == "demo" })
    }

    @Test func everyTypeHasAConsistentSpec() {
        for spec in CameraTypeCatalog.all {
            #expect(Set(spec.fields).isDisjoint(with: Set(spec.advancedFields)), "\(spec.id)")
            if spec.group == .network, spec.usesDiscovery { #expect(spec.fields.contains("host"), "\(spec.id)") }
            if spec.needsStreamingHelper { #expect(spec.group == .cloud || spec.group == .console) }
        }
        #expect(Set(CameraTypeCatalog.all.map(\.id)).count == CameraTypeCatalog.all.count)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ProbeAPITests {
    @Test func aWorkingCameraIsDescribedForTheNextPages() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "automatic", "host": "192.0.2.20", "username": "admin", "password": "pw"])
        #expect(answer.status == 200)
        let json = answer.json
        #expect(json["ok"] as? Bool == true)
        #expect(json["vendor"] as? String == "onvif")
        #expect(json["vendorName"] as? String == "ONVIF")
        #expect(json["model"] as? String == "Doorstep 3000")
        #expect(json["suggestedName"] as? String == "Doorstep 3000")
        #expect(json["suggestedKind"] as? String == "camera")
        #expect(json["suggestedMotionSource"] as? String == "cameraEvents")
        #expect(json["hasCameraAudio"] as? Bool == true)
        #expect(json["canUseTwoWayAudio"] as? Bool == true)
        #expect(json["onvifPort"] as? Int == 8000)
        let main = try #require(json["mainStream"] as? [String: Any])
        #expect(main["summary"] as? String == "H.264 1920×1080 · 25 fps · AAC 16 kHz")
        let sources = try #require(json["motionSources"] as? [[String: Any]])
        #expect(sources.compactMap { $0["id"] as? String } == ["cameraEvents", "softMotion", "webhook"])
        #expect(sources.first?["title"] as? String == "Camera Events")
        let sensors = try #require(json["sensorsByMotionSource"] as? [String: [[String: Any]]])
        #expect(sensors["cameraEvents"]?.compactMap { $0["id"] as? String } == ["person", "vehicle"])
        #expect(sensors["softMotion"]?.compactMap { $0["id"] as? String } == ["person", "vehicle"])
        #expect(sensors["webhook"]?.compactMap { $0["id"] as? String } == ["person", "vehicle", "animal", "package"])
        let call = try #require(backend.read { $0.probeCalls.first })
        #expect(call.host == "192.0.2.20")
        #expect(call.username == "admin")
        #expect(call.password == "pw")
        #expect(call.vendor == nil, "detect automatically")
    }

    @Test func aCameraWithoutMotionEventsOffersBuiltInDetectionOnly() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.probe = .success(CameraProbeResult(vendor: .rtsp, manufacturer: "", model: "", serialNumber: "", firmware: "",
                                                  mainStream: StreamInfo(url: URL(string: "rtsp://192.0.2.9/s")!, videoCodec: .h264, width: 640, height: 480),
                                                  capabilities: CameraCapabilities()))
        }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let json = await session.send("POST", "/api/v1/probe", json: ["type": "rtspURL", "mainStreamURL": "rtsp://192.0.2.9/s"]).json
        #expect((json["motionSources"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["softMotion", "webhook"])
        #expect(json["suggestedMotionSource"] as? String == "softMotion")
        #expect(json["suggestedName"] as? String == "Camera")
        #expect(json["hasCameraAudio"] as? Bool == false)
    }

    @Test func aDoorbellThatReportsNoButtonRingsThroughTheWebhook() async throws {
        let backend = FakeBackend()
        var result = FakeBackend.sampleProbe
        result.capabilities.isDoorbell = true
        backend.write { $0.probe = .success(result) }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let json = await session.send("POST", "/api/v1/probe", json: ["type": "automatic", "host": "192.0.2.20", "username": "u"]).json
        #expect(json["suggestedKind"] as? String == "doorbell")
        #expect(json["ringsThroughWebhook"] as? Bool == false)
    }

    @Test func aPastedAddressIsSplitIntoItsParts() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "hikvision", "host": "https://admin:s3cret@192.0.2.20:8443/doc/page.html"])
        #expect(answer.status == 200)
        let call = try #require(backend.read { $0.probeCalls.first })
        #expect(call.host == "192.0.2.20")
        #expect(call.username == "admin")
        #expect(call.password == "s3cret")
        #expect(call.vendor == .hikvision)
    }

    @Test func missingOrWrongInputIsExplainedPerField() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        func problem(_ body: [String: Any]) async -> (String?, String?) {
            let answer = await session.send("POST", "/api/v1/probe", json: body)
            #expect(answer.status == 400, "\(body)")
            return (answer.json["field"] as? String, answer.json["message"] as? String)
        }
        #expect(await problem(["type": "nonsense"]).0 == "type")
        #expect(await problem(["type": "automatic"]).0 == "host")
        #expect(await problem(["type": "automatic", "host": "not a host!"]).0 == "host")
        #expect(await problem(["type": "automatic", "host": "192.0.2.20"]).0 == "username")
        #expect(await problem(["type": "automatic", "host": "192.0.2.20", "username": "a", "rtspPort": 70_000]).0 == "rtspPort")
        #expect(await problem(["type": "automatic", "host": "192.0.2.20", "username": "a", "httpPort": 0]).0 == "httpPort")
        #expect(await problem(["type": "rtspURL"]).0 == "mainStreamURL")
        #expect(await problem(["type": "rtspURL", "mainStreamURL": "http://192.0.2.9/x"]).0 == "mainStreamURL")
        let tls = await problem(["type": "rtspURL", "mainStreamURL": "rtsps://192.0.2.9/x"])
        #expect(tls.1?.contains("RTSP over TLS") == true)
        #expect(await problem(["type": "rtspURL", "mainStreamURL": "rtsp://192.0.2.9/x", "subStreamURL": "ftp://x"]).0 == "subStreamURL")
        #expect(await problem(["type": "wyzeRTSP", "host": "192.0.2.5"]).0 == "username")
        #expect(await problem(["type": "wyzeRTSP", "host": "192.0.2.5", "username": "u"]).0 == "password")
        #expect(await problem(["type": "ring", "source": ""]).0 == "source")
        #expect(await problem(["type": "ring", "source": "exec:rm -rf /"]).0 == "source")
        #expect(await problem(["type": "unifiProtect", "host": "192.0.2.1"]).0 == "apiKey")
        #expect(await problem(["type": "unifiProtect", "host": "192.0.2.1", "apiKey": "k"]).0 == "unifiCamera")
        #expect(await problem(["type": "googleNest"]).0 == "nest")
    }

    @Test func aProblemDoesNotEchoTheSecretsItWasGiven() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "ring", "source": "exec:curl https://example.invalid/?token=SUPERSECRET"])
        #expect(answer.status == 400)
        #expect(!answer.text.contains("SUPERSECRET"))
    }

    @Test func cloudCamerasNeedTheStreamingHelper() async throws {
        let backend = FakeBackend()
        backend.write { $0.helperInstalled = false }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "ring", "source": "ring:?refresh_token=abc&device_id=9&camera_id=1"])
        #expect(answer.status == 400)
        #expect((answer.json["message"] as? String)?.contains("streaming helper") == true)
    }

    @Test func aCloudSourceIsCheckedThroughTheHelper() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "ring", "source": "ring:?refresh_token=abc&device_id=9&camera_id=1"])
        #expect(answer.status == 200)
        #expect(answer.json["ok"] as? Bool == true)
        #expect(backend.read { $0.calls } == ["probeIntegration"])
    }

    @Test func theCameraRefusingTheLoginIsAnAnswerNotAnError() async throws {
        let backend = FakeBackend()
        backend.write { $0.probe = .failure(CameraAdapterError.unauthorized) }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "hikvision", "host": "192.0.2.20", "username": "a", "password": "wrong"])
        #expect(answer.status == 200)
        #expect(answer.json["ok"] as? Bool == false)
        #expect(answer.json["error"] as? String == "The camera rejected the user name or password.")
    }

    @Test(arguments: [
        (TransportError.connectionRefused as any Error, "The connection was refused."),
        (TransportError.timedOut as any Error, "The connection timed out."),
        (RTSPError.notFound as any Error, "The camera has no video stream at this address. Check the stream URL."),
        (EngineError.noCameraAPI(host: "192.0.2.20") as any Error, "No Hikvision, Reolink or ONVIF interface answered at 192.0.2.20."),
        (CameraAdapterError.httpStatus(503) as any Error, "The camera answered with an error (HTTP 503). Check the camera type and ports."),
    ])
    func probeFailuresAreWorded(error: any Error, expectedStart: String) async throws {
        let backend = FakeBackend()
        backend.write { $0.probe = .failure(error) }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "automatic", "host": "192.0.2.20", "username": "a"])
        #expect(answer.status == 200)
        #expect((answer.json["error"] as? String)?.hasPrefix(expectedStart) == true, "\(answer.json["error"] as? String ?? "")")
    }

    @Test func anErrorNobodyMappedReadsAsUnexpected() async throws {
        struct Odd: Error {}
        let backend = FakeBackend()
        backend.write { $0.probe = .failure(Odd()) }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "automatic", "host": "192.0.2.20", "username": "a"])
        #expect(answer.json["error"] as? String == ErrorText.unexpected)
    }

    @Test func credentialsInsideAnErrorAreRedacted() async throws {
        let backend = FakeBackend()
        backend.write { $0.probe = .failure(CameraAdapterError.unsupported("could not open rtsp://admin:hunter2@192.0.2.20/stream")) }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/probe", json: ["type": "automatic", "host": "192.0.2.20", "username": "a"])
        #expect(!answer.text.contains("hunter2"))
    }

    @Test func aCameraThatIsAlreadyAddedIsFlagged() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let first = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.0.2.20", "username": "u", "name": "Porch"])
        #expect(first.status == 201)
        let again = await session.send("POST", "/api/v1/probe", json: ["type": "automatic", "host": "192.0.2.20", "username": "u"])
        let existing = try #require(again.json["alreadyAdded"] as? [String: Any])
        #expect(existing["name"] as? String == "Porch")
    }

    @Test func probingNeedsASignedInUser() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        #expect(await harness.send("POST", "/api/v1/probe", json: ["type": "demo"]).status == 401)
    }
}

@Suite(.timeLimit(.minutes(1))) struct AddCameraAPITests {
    private func add(_ session: Harness.Session, _ extra: [String: Any] = [:]) async -> Answer {
        var body: [String: Any] = ["type": "automatic", "host": "192.0.2.20", "username": "viewer", "password": "pw", "name": "Front Door"]
        for (key, value) in extra { body[key] = value }
        return await session.send("POST", "/api/v1/cameras", json: body)
    }

    @Test func addsACameraWithTheProbedDetailsAndTheWizardsDefaults() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await add(session)
        #expect(answer.status == 201)
        let json = answer.json
        #expect(json["name"] as? String == "Front Door")
        #expect(json["vendor"] as? String == "onvif")
        #expect(json["kind"] as? String == "camera")
        #expect(json["manufacturer"] as? String == "Acme")
        #expect(json["model"] as? String == "Doorstep 3000")
        #expect(json["motionSource"] as? String == "cameraEvents")
        #expect(json["motionSensitivity"] as? Double == 0.5)
        #expect(json["motionHoldSeconds"] as? Int == 20)
        #expect(json["audioEnabled"] as? Bool == true)
        #expect(json["twoWayAudio"] as? Bool == true)
        #expect(json["username"] as? String == "viewer")
        #expect(json["address"] as? String == "192.0.2.20")
        #expect(json["vendorName"] as? String == "ONVIF")
        #expect(json["password"] == nil)
        let endpoint = try #require(json["endpoint"] as? [String: Any])
        #expect(endpoint["host"] as? String == "192.0.2.20")
        #expect(endpoint["onvifPort"] as? Int == 8000, "the port the probe found is saved")
        // Stream addresses are the camera's, without credentials.
        #expect(json["mainStreamURL"] as? String == "rtsp://192.0.2.20:554/main")
        let id = try #require(UUID(uuidString: json["id"] as? String ?? ""))
        #expect(backend.read { $0.passwords[id] } == "pw")
        #expect(await session.get("/api/v1/cameras/\(id)").status == 200)
        #expect((await session.get("/api/v1/cameras").json["cameras"] as? [[String: Any]])?.count == 1)
    }

    @Test func theChoicesOfTheLaterPagesAreKept() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let answer = await add(session, ["kind": "doorbell", "motionSource": "softMotion", "motionSensitivity": 0.8, "motionHoldSeconds": 45,
                                         "sensors": ["person": true, "vehicle": true, "animal": true, "humidity": true], "audioEnabled": false, "twoWayAudio": false])
        #expect(answer.status == 201)
        #expect(answer.json["kind"] as? String == "doorbell")
        #expect(answer.json["motionSource"] as? String == "softMotion")
        #expect(answer.json["motionSensitivity"] as? Double == 0.8)
        #expect(answer.json["motionHoldSeconds"] as? Int == 45)
        #expect(answer.json["audioEnabled"] as? Bool == false)
        #expect(answer.json["twoWayAudio"] as? Bool == false)
        let sensors = try #require(answer.json["sensors"] as? [String: Bool])
        #expect(sensors["person"] == true && sensors["vehicle"] == true)
        #expect(sensors["animal"] == false, "the camera does not report animals")
        #expect(sensors["humidity"] == false)
    }

    @Test func impossibleChoicesFallBackTheWayTheWizardDoes() async throws {
        let backend = FakeBackend()
        var result = FakeBackend.sampleProbe
        result.capabilities = CameraCapabilities(events: [], twoWayAudio: false)
        backend.write { $0.probe = .success(result) }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await add(session, ["motionSource": "cameraEvents", "twoWayAudio": true, "motionSensitivity": 7, "motionHoldSeconds": 0])
        #expect(answer.status == 201)
        #expect(answer.json["motionSource"] as? String == "softMotion", "the camera reports no motion events")
        #expect(answer.json["twoWayAudio"] as? Bool == false)
        #expect(answer.json["motionSensitivity"] as? Double == 1)
        #expect(answer.json["motionHoldSeconds"] as? Int == 1)
    }

    @Test func aNameIsRequired() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await add(session, ["name": "   "])
        #expect(answer.status == 400)
        #expect(answer.json["field"] as? String == "name")
        #expect(backend.read { $0.configurations.isEmpty })
    }

    @Test func aLongNameIsShortened() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let answer = await add(session, ["name": String(repeating: "N", count: 200)])
        #expect((answer.json["name"] as? String)?.count == 60)
    }

    @Test func theDemoCameraNeedsNothing() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.probe = .success(CameraProbeResult(vendor: .demo, manufacturer: "CameraBridge", model: "Demo Camera", serialNumber: "DEMO", firmware: "1",
                                                  capabilities: CameraCapabilities(events: [.motion])))
        }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "demo", "name": "Test pattern"])
        #expect(answer.status == 201)
        #expect(answer.json["vendor"] as? String == "demo")
        #expect(answer.json["username"] as? String == "")
        #expect(answer.json["address"] as? String == "Test pattern")
        #expect(backend.read { $0.probeCalls.first?.username } == "")
    }

    @Test func anRtspUrlCameraKeepsItsStreamsWithoutCredentials() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.probe = .success(CameraProbeResult(vendor: .rtsp, manufacturer: "", model: "", serialNumber: "", firmware: "", capabilities: CameraCapabilities()))
        }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "rtspURL", "mainStreamURL": "rtsp://guest:secret@192.0.2.9:8554/live/main",
                                                                          "subStreamURL": "rtsp://192.0.2.9:8554/live/sub", "name": "Shed"])
        #expect(answer.status == 201)
        #expect(answer.json["mainStreamURL"] as? String == "rtsp://192.0.2.9:8554/live/main")
        #expect(answer.json["subStreamURL"] as? String == "rtsp://192.0.2.9:8554/live/sub")
        #expect(answer.json["username"] as? String == "guest")
        #expect((answer.json["endpoint"] as? [String: Any])?["rtspPort"] as? Int == 8554)
        #expect(!answer.text.contains("secret"))
        let id = try #require(UUID(uuidString: answer.json["id"] as? String ?? ""))
        #expect(backend.read { $0.passwords[id] } == "secret")
    }

    @Test func aCloudCameraKeepsItsSourceInTheSecretStore() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.integrationProbe = .success(CameraProbeResult(vendor: .go2rtc, manufacturer: "Ring", model: "Stick Up Cam", serialNumber: "", firmware: "",
                                                             capabilities: CameraCapabilities()))
        }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "ring", "source": "ring:?refresh_token=SECRETTOKEN&device_id=9&camera_id=42", "name": "Driveway"])
        #expect(answer.status == 201, "\(answer.text)")
        #expect(!answer.text.contains("SECRETTOKEN"))
        #expect(answer.json["vendor"] as? String == "go2rtc")
        #expect((answer.json["integration"] as? [String: Any])?["service"] as? String == "ring")
        #expect(answer.json["address"] as? String == "Ring")
        let id = try #require(UUID(uuidString: answer.json["id"] as? String ?? ""))
        #expect(backend.read { $0.passwords[id] }?.contains("SECRETTOKEN") == true)
    }

    @Test func aConsoleCameraNeedsTheKeyAndTheChosenCamera() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.integrationProbe = .success(CameraProbeResult(vendor: .unifi, manufacturer: "Ubiquiti", model: "G4", serialNumber: "", firmware: "",
                                                             capabilities: CameraCapabilities(events: [.motion])))
        }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "unifiProtect", "host": "192.0.2.1", "apiKey": "KEY123", "unifiCameraID": "abc", "unifiCameraName": "Garage", "name": "Garage"])
        #expect(answer.status == 201, "\(answer.text)")
        #expect((answer.json["integration"] as? [String: Any])?["details"] as? [String: String] == ["protectCameraID": "abc", "deviceName": "Garage"])
        let endpoint = try #require(answer.json["endpoint"] as? [String: Any])
        #expect(endpoint["useHTTPS"] as? Bool == true)
        #expect(endpoint["httpPort"] as? Int == 443)
        #expect(!answer.text.contains("KEY123"))
    }

    @Test func aFailedCheckAddsNothing() async throws {
        let backend = FakeBackend()
        backend.write { $0.probe = .failure(CameraAdapterError.unauthorized) }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await add(session)
        #expect(answer.status == 422)
        #expect(answer.json["error"] as? String == "probe_failed")
        #expect(backend.read { $0.configurations.isEmpty })
    }

    @Test func engineRefusalsAreExplained() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        backend.write { $0.addError = EngineError.duplicateCamera }
        let duplicate = await add(session)
        #expect(duplicate.status == 409)
        #expect(duplicate.json["error"] as? String == "duplicate")
        backend.write { $0.addError = PortAllocationError.noFreePort(startingAt: 21_100) }
        let ports = await add(session)
        #expect(ports.status == 422)
        #expect((ports.json["message"] as? String)?.contains("no free network port") == true || (ports.json["message"] as? String)?.contains("No free network port") == true)
    }

    @Test func malformedBodiesAreRefused() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        #expect(await session.send("POST", "/api/v1/cameras", json: ["name": "x"]).status == 400)
        let wrongKind = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.0.2.20", "username": "u", "name": "x", "kind": "toaster"])
        #expect(wrongKind.status == 400)
        #expect(wrongKind.json["field"] as? String == "kind")
        #expect(!wrongKind.text.contains("toaster"), "what was sent is not echoed back")
        let wrongType = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": 12, "username": "u", "name": "x"])
        #expect(wrongType.status == 400)
        #expect(await session.send("POST", "/api/v1/cameras", json: [1, 2, 3]).status == 400)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CameraResourceAPITests {
    private func addCamera(_ session: Harness.Session, name: String = "Front Door") async throws -> UUID {
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.0.2.20", "username": "viewer", "password": "pw", "name": name])
        return try #require(UUID(uuidString: answer.json["id"] as? String ?? ""))
    }

    @Test func listShowsConfigurationAndLiveStatus() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let answer = await session.get("/api/v1/cameras/\(id)")
        let status = try #require(answer.json["status"] as? [String: Any])
        #expect(status["connection"] as? String == "online")
        #expect(status["summary"] as? String == "Live · Not Paired")
        #expect(status["paired"] as? Bool == false)
        #expect(status["hapPort"] as? Int == 21_100)
        #expect(status["videoSummary"] as? String == "H.264 1920×1080 · 25 fps")
        #expect(status["setupCode"] == nil, "the setup code is only on the pairing endpoint")
        #expect(!answer.text.contains("12345678"))
    }

    @Test func statusWordsFollowTheMacApp() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        func summary(_ status: CameraStatus) async -> (String?, String?) {
            backend.write { $0.statusOverrides[id] = status }
            let json = await session.get("/api/v1/cameras/\(id)").json["status"] as? [String: Any]
            return (json?["summary"] as? String, json?["connectionReason"] as? String)
        }
        func status(_ connection: ConnectionState, paired: Bool = true, recording: Bool = false, motion: Bool = false, viewers: Int = 0) -> CameraStatus {
            CameraStatus(id: id, name: "Front Door", kind: .camera, vendor: .onvif, connection: connection, isPaired: paired, motionActive: motion,
                         recordingNow: recording, liveViewers: viewers)
        }
        #expect(await summary(status(.online)).0 == "Live")
        #expect(await summary(status(.online, recording: true)).0 == "Live · Recording")
        #expect(await summary(status(.online, motion: true)).0 == "Live · Motion")
        #expect(await summary(status(.online, viewers: 2)).0 == "Live · 2 Viewers")
        #expect(await summary(status(.connecting)).0 == "Connecting…")
        #expect(await summary(status(.disabled)).0 == "Disabled")
        let offline = await summary(status(.offline("the connection was refused")))
        #expect(offline.0 == "Offline — retrying")
        #expect(offline.1 == "the connection was refused")
    }

    @Test func unknownCamerasAre404() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = UUID()
        for (method, path) in [("GET", ""), ("DELETE", ""), ("GET", "/snapshot"), ("GET", "/live"), ("GET", "/pairing"), ("POST", "/reset-pairing"),
                               ("POST", "/test-motion")] {
            #expect(await session.send(method, "/api/v1/cameras/\(id)\(path)").status == 404, "\(method) \(path)")
        }
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["name": "x"]).status == 404)
        #expect(await session.get("/api/v1/cameras/not-a-uuid").status == 404)
        #expect(await session.get("/api/v1/cameras/..%2F..%2Fetc").status == 404)
    }

    @Test func deleteRemovesTheCamera() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        #expect(await session.send("DELETE", "/api/v1/cameras/\(id)").status == 204)
        #expect(await session.get("/api/v1/cameras/\(id)").status == 404)
        #expect(backend.read { $0.calls.contains("remove") })
    }

    // MARK: Changes

    @Test func renamingAndSwitchingACameraOff() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let answer = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["name": "  Back Door  ", "isEnabled": false])
        #expect(answer.status == 200)
        #expect(answer.json["name"] as? String == "Back Door")
        #expect(answer.json["isEnabled"] as? Bool == false)
        #expect(answer.json["motionSource"] as? String == "cameraEvents", "what was not sent stays")
        #expect(answer.json["username"] as? String == "viewer")
        let kept = await session.get("/api/v1/cameras/\(id)")
        #expect(kept.json["name"] as? String == "Back Door")
    }

    @Test func qualityAndRecordingChoices() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let answer = await session.send("PATCH", "/api/v1/cameras/\(id)", json: [
            "liveStreamMode": "alwaysSub", "liveQualityMode": "originalQuality", "liveMaxBitrateOverride": "mbps4",
            "recordingStreamMode": "main", "recordingQualityMode": "originalWhenPossible"])
        #expect(answer.status == 200)
        #expect(answer.json["liveStreamMode"] as? String == "alwaysSub")
        #expect(answer.json["liveQualityMode"] as? String == "originalQuality")
        #expect(answer.json["liveMaxBitrateOverride"] as? String == "mbps4")
        #expect(answer.json["recordingStreamMode"] as? String == "main")
        #expect(answer.json["recordingQualityMode"] as? String == "originalWhenPossible")
    }

    @Test func theTimestampOverlayIsPatchedFieldByField() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let first = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["timestampOverlay": ["enabled": true, "position": "bottomLeft", "size": "large"]])
        let overlay = try #require(first.json["timestampOverlay"] as? [String: Any])
        #expect(overlay["enabled"] as? Bool == true)
        #expect(overlay["position"] as? String == "bottomLeft")
        #expect(overlay["size"] as? String == "large")
        #expect(overlay["showDate"] as? Bool == true, "untouched fields keep their value")
        let second = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["timestampOverlay": ["showSeconds": false, "showCameraName": true]])
        let again = try #require(second.json["timestampOverlay"] as? [String: Any])
        #expect(again["position"] as? String == "bottomLeft")
        #expect(again["showSeconds"] as? Bool == false)
        #expect(again["showCameraName"] as? Bool == true)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["timestampOverlay": ["position": "middle"]]).status == 400)
    }

    @Test func motionChoicesAreChecked() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let soft = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionSource": "softMotion", "motionSensitivity": 0.9, "motionHoldSeconds": 30])
        #expect(soft.json["motionSource"] as? String == "softMotion")
        #expect(soft.json["motionSensitivity"] as? Double == 0.9)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionSensitivity": 1.5]).json["field"] as? String == "motionSensitivity")
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionSensitivity": -0.1]).status == 400)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionHoldSeconds": 0]).status == 400)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionHoldSeconds": 7_200]).status == 400)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionSource": "psychic"]).status == 400)
    }

    @Test func cameraEventsCannotBeChosenForACameraThatReportsNone() async throws {
        let backend = FakeBackend()
        var result = FakeBackend.sampleProbe
        result.capabilities = CameraCapabilities(events: [], twoWayAudio: false)
        backend.write { $0.probe = .success(result) }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let answer = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionSource": "cameraEvents"])
        #expect(answer.status == 400)
        #expect(answer.json["field"] as? String == "motionSource")
        let two = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["twoWayAudio": true])
        #expect(two.status == 400)
    }

    @Test func switchingTheMotionSourceTurnsOffSensorsItDoesNotOffer() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        _ = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionSource": "webhook", "sensors": ["animal": true, "person": true]])
        let withWebhook = await session.get("/api/v1/cameras/\(id)")
        #expect((withWebhook.json["sensors"] as? [String: Bool])?["animal"] == true)
        let back = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["motionSource": "cameraEvents"])
        let sensors = try #require(back.json["sensors"] as? [String: Bool])
        #expect(sensors["animal"] == false, "the camera does not report animals, only the webhook did")
        #expect(sensors["person"] == true)
    }

    @Test func sensorNamesAreChecked() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["sensors": ["lasers": true]]).status == 400)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["sensors": ["person": "yes"]]).status == 400)
    }

    @Test func connectionDetailsAreCheckedAndAPasswordIsPassedOn() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let moved = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["endpoint": ["host": "192.0.2.44", "httpPort": 8080], "username": "admin",
                                                                              "password": "new-secret", "mainStreamURL": "rtsp://192.0.2.44:554/h264"])
        #expect(moved.status == 200)
        let endpoint = try #require(moved.json["endpoint"] as? [String: Any])
        #expect(endpoint["host"] as? String == "192.0.2.44")
        #expect(endpoint["httpPort"] as? Int == 8080)
        #expect(endpoint["rtspPort"] as? Int == 554)
        #expect(moved.json["mainStreamURL"] as? String == "rtsp://192.0.2.44:554/h264")
        #expect(moved.json["username"] as? String == "admin")
        #expect(!moved.text.contains("new-secret"))
        #expect(backend.read { $0.passwords[id] } == "new-secret")
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["endpoint": ["host": "bad host!"]]).json["field"] as? String == "endpoint.host")
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["endpoint": ["rtspPort": 70_000]]).status == 400)
        #expect(await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["mainStreamURL": "http://x"]).status == 400)
        let cleared = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["subStreamURL": ""])
        #expect(cleared.json["subStreamURL"] is NSNull || cleared.json["subStreamURL"] == nil)
        let emptyPassword = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["password": ""])
        #expect(emptyPassword.status == 200)
        #expect(backend.read { $0.passwords[id] } == "new-secret", "an empty password means unchanged")
    }

    @Test func aNameCannotBeEmptied() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let answer = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["name": "   "])
        #expect(answer.status == 400)
        #expect(await session.get("/api/v1/cameras/\(id)").json["name"] as? String == "Front Door")
    }

    @Test func engineFailuresOnUpdateAreExplained() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        backend.write { $0.updateError = ConfigurationStoreError.corrupt("x") }
        let answer = await session.send("PATCH", "/api/v1/cameras/\(id)", json: ["name": "New"])
        #expect(answer.status == 422)
        #expect((answer.json["message"] as? String)?.contains("damaged") == true)
    }

    // MARK: Pictures

    @Test func aSnapshotIsAJPEG() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let answer = await session.get("/api/v1/cameras/\(id)/snapshot")
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == "image/jpeg")
        #expect(answer.headers["Cache-Control"] == "no-store")
        #expect(Array(answer.body.prefix(3)) == [0xFF, 0xD8, 0xFF])
    }

    @Test func noPictureYetIsA503WithARetryHint() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        backend.write { $0.snapshot = nil }
        let answer = await session.get("/api/v1/cameras/\(id)/snapshot")
        #expect(answer.status == 503)
        #expect(answer.headers["Retry-After"] == "5")
        #expect(answer.json["error"] as? String == "no_picture")
    }

    @Test func theLivePreviewIsMultipartJPEGs() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let live = await session.stream("/api/v1/cameras/\(id)/live")
        defer { live.stop() }
        #expect(live.response.status == 200)
        #expect(live.response.headers["Content-Type"] == "multipart/x-mixed-replace; boundary=cbframe")
        #expect(live.response.headers["Cache-Control"] == "no-store")
        #expect(await live.wait { $0.components(separatedBy: "--cbframe").count > 3 }, "several frames arrive")
        #expect(live.text.hasPrefix("--cbframe\r\nContent-Type: image/jpeg\r\nContent-Length: 12\r\n\r\n"))
    }

    @Test func theNumberOfLivePreviewsIsLimitedAndFreedWhenOneEnds() async throws {
        let harness = try Harness { $0.maximumLiveStreams = 2 }
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let first = await session.stream("/api/v1/cameras/\(id)/live")
        let second = await session.stream("/api/v1/cameras/\(id)/live")
        let refused = await session.send("GET", "/api/v1/cameras/\(id)/live")
        #expect(refused.status == 429)
        #expect(refused.json["error"] as? String == "too_many_streams")
        first.stop()
        #expect(await eventually { first.finished.value })
        let third = await harness.raw("GET", "/api/v1/cameras/\(id)/live", cookie: session.cookie)
        #expect(third.status == 200, "the slot of the ended preview is free again")
        second.stop()
        StreamCollector(third).stop()
    }

    @Test func aPreviewEndsAfterItsLifetime() async throws {
        let harness = try Harness { $0.liveLifetime = .milliseconds(150) }
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let live = await session.stream("/api/v1/cameras/\(id)/live")
        #expect(await eventually { live.finished.value })
    }

    // MARK: Pairing

    @Test func anUnpairedCameraOffersItsCodeAndAQRCode() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        let answer = await session.get("/api/v1/cameras/\(id)/pairing")
        #expect(answer.status == 200)
        #expect(answer.json["accessoryName"] as? String == "Front Door")
        #expect(answer.json["paired"] as? Bool == false)
        #expect(answer.json["setupCode"] as? String == "123-45-678")
        #expect(answer.json["setupURI"] as? String == "X-HM://00GW95DQA7OSX")
        let svg = try #require(answer.json["qrSVG"] as? String)
        #expect(svg.hasPrefix("<svg ") && svg.hasSuffix("</svg>"))
        #expect(answer.json["blocker"] == nil)
    }

    @Test func aPairedCameraOffersNoCode() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        backend.write {
            $0.statusOverrides[id] = CameraStatus(id: id, name: "Front Door", kind: .camera, vendor: .onvif, connection: .online, isPaired: true,
                                                  setupCode: "12345678", setupURI: "X-HM://00GW95DQA7OSX", hapPort: 21_100)
        }
        let answer = await session.get("/api/v1/cameras/\(id)/pairing")
        #expect(answer.json["paired"] as? Bool == true)
        #expect(answer.json["setupCode"] == nil)
        #expect(answer.json["qrSVG"] == nil)
    }

    @Test(arguments: [
        (EngineState.paused, true, UInt16?.some(21_100), "bridgePaused", "resume"),
        (EngineState.stopped, true, UInt16?.some(21_100), "bridgeNotRunning", "start"),
        (EngineState.failed("x"), true, UInt16?.some(21_100), "bridgeNotRunning", "start"),
        (EngineState.starting, true, UInt16?.some(21_100), "bridgeStarting", nil),
        (EngineState.running, false, UInt16?.some(21_100), "cameraDisabled", nil),
        (EngineState.running, true, UInt16?.none, "accessoryNotRunning", nil),
    ])
    func noCodeWhileTheHomeAppCouldNotFindTheAccessory(state: EngineState, enabled: Bool, port: UInt16?, blocker: String, action: String?) async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        backend.write { fake in
            fake.state = state
            fake.configurations[0].isEnabled = enabled
            fake.statusOverrides[id] = CameraStatus(id: id, name: "Front Door", kind: .camera, vendor: .onvif, connection: .online, setupCode: "12345678",
                                                    setupURI: "X-HM://00GW95DQA7OSX", hapPort: port)
        }
        let answer = await session.get("/api/v1/cameras/\(id)/pairing")
        #expect(answer.json["blocker"] as? String == blocker)
        #expect(answer.json["blockerAction"] as? String == action)
        #expect(answer.json["setupCode"] == nil)
        #expect(answer.json["qrSVG"] == nil)
        #expect((answer.json["blockerMessage"] as? String)?.isEmpty == false)
    }

    @Test func aNewAccessoryWithoutACodeYetIsWaiting() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        backend.write { $0.statusOverrides[id] = CameraStatus(id: id, name: "Front Door", kind: .camera, vendor: .onvif, connection: .online, hapPort: 21_100) }
        #expect(await session.get("/api/v1/cameras/\(id)/pairing").json["blocker"] as? String == "waiting")
    }

    @Test func resettingThePairing() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        #expect(await session.send("POST", "/api/v1/cameras/\(id)/reset-pairing").status == 204)
        #expect(backend.read { $0.calls.contains("resetPairing") })
    }

    @Test func aTestMotionEventNeedsAPublishedAccessory() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        #expect(await session.send("POST", "/api/v1/cameras/\(id)/test-motion").status == 204)
        #expect(backend.read { $0.calls.contains("motion") })
        backend.write { $0.state = .paused; $0.calls = [] }
        let blocked = await session.send("POST", "/api/v1/cameras/\(id)/test-motion")
        #expect(blocked.status == 409)
        #expect(blocked.json["message"] as? String == "The bridge is paused, so a motion event can’t reach the Home app.")
        #expect(backend.read { !$0.calls.contains("motion") })
    }
}

@Suite(.timeLimit(.minutes(1))) struct DiscoveryAPITests {
    @Test func discoveredCamerasAreMergedByHostAndMarkedWhenAlreadyAdded() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.discovered = [
                DiscoveredCamera(host: "192.0.2.30", name: nil, hardware: nil, xAddrs: [URL(string: "http://192.0.2.30:8000/onvif/device_service")!]),
                DiscoveredCamera(host: "192.0.2.30", name: "Garage", hardware: "DS-2CD", xAddrs: [URL(string: "http://192.0.2.30:8000/onvif/device_service")!,
                                                                                                      URL(string: "https://192.0.2.30/onvif")!]),
                DiscoveredCamera(host: "192.0.2.31", name: "Porch", hardware: nil, xAddrs: []),
                DiscoveredCamera(host: "192.0.2.20", name: "Added already", hardware: nil, xAddrs: []),
            ]
        }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        _ = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.0.2.20", "username": "u", "name": "Front"])
        let answer = await session.send("POST", "/api/v1/discover")
        #expect(answer.status == 200)
        let cameras = try #require(answer.json["cameras"] as? [[String: Any]])
        #expect(cameras.compactMap { $0["host"] as? String } == ["192.0.2.30", "192.0.2.31", "192.0.2.20"])
        #expect(cameras[0]["name"] as? String == "Garage")
        #expect(cameras[0]["hardware"] as? String == "DS-2CD")
        #expect(cameras[0]["onvifPort"] as? Int == 8000)
        #expect(cameras[0]["alreadyAdded"] as? Bool == false)
        #expect(cameras[2]["alreadyAdded"] as? Bool == true)
    }

    @Test func nothingFoundIsAnEmptyList() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        #expect((await session.send("POST", "/api/v1/discover").json["cameras"] as? [Any])?.isEmpty == true)
    }

    @Test func aConsolesCamerasAreListedWithTheKey() async throws {
        let backend = FakeBackend()
        backend.write { $0.protectCameras = [UnifiProtectCamera(id: "c1", name: "Garage", model: "G4 Bullet", isConnected: true, isDoorbell: false)] }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("POST", "/api/v1/integrations/unifi/cameras", json: ["host": "192.0.2.1", "apiKey": "KEY"])
        #expect(answer.status == 200)
        let first = try #require((answer.json["cameras"] as? [[String: Any]])?.first)
        #expect(first["id"] as? String == "c1")
        #expect(first["connected"] as? Bool == true)
        #expect(await session.send("POST", "/api/v1/integrations/unifi/cameras", json: ["host": "192.0.2.1", "apiKey": " "]).status == 400)
        #expect(await session.send("POST", "/api/v1/integrations/unifi/cameras", json: ["host": "no spaces allowed", "apiKey": "k"]).status == 400)
    }

    @Test func googleSignInStartsWithALinkForTheProject() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let link = await session.send("POST", "/api/v1/integrations/nest/authorize", json: ["projectID": "11111111-2222-3333-4444-555555555555", "clientID": "client-123.apps.example"])
        #expect(link.status == 200)
        let url = try #require(link.json["url"] as? String)
        #expect(url.hasPrefix("https://nestservices.google.com/partnerconnections/11111111-2222-3333-4444-555555555555/auth?"))
        #expect(url.contains("client_id=client-123.apps.example"))
        #expect(await session.send("POST", "/api/v1/integrations/nest/authorize", json: ["projectID": "", "clientID": "x"]).status == 400)
        #expect(await session.send("POST", "/api/v1/integrations/nest/connect", json: ["projectID": "p", "clientID": "c", "clientSecret": "s", "code": "  "]).status == 400)
    }
}
