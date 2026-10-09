#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import HDS
import PlatformApple
import TestSupport
import Testing
@testable import HAP
@testable import HAPCamera

/// Plan W2-1 item 10 (acceptance): a real `AccessoryServer` on 127.0.0.1 (never advertised) with a `CameraController`
/// and fake delegates, driven by TestSupport's `HAPTestController` and `HDSTestClient`: pair → read accessories →
/// SetupEndpoints → start stream → SetupDataStreamTransport → HDS connect → hello → dataSend open → init + 2 fragments →
/// close.
@Suite(.timeLimit(.minutes(3))) struct LoopbackEndToEndTests {
    struct Running {
        let accessory: Accessory
        let server: AccessoryServer
        let dataStreamServer: DataStreamServer
        let controller: CameraController
        let port: UInt16

        func stop() async {
            await server.stop()
            await dataStreamServer.stop()
        }
    }

    static func start(isDoorbell: Bool, streaming: FakeStreamingDelegate, recording: FakeRecordingDelegate) async throws -> Running {
        let transport = AppleNetworkTransport()
        let accessory = Accessory(info: CameraHarness.info, category: isDoorbell ? .videoDoorbell : .ipCamera)
        let server = AccessoryServer(accessory: accessory,
                                     configuration: AccessoryServerConfiguration(port: 0, advertise: false, serviceName: "Loopback Camera",
                                                                                 loopbackOnly: true),
                                     store: InMemoryHAPStore(), transport: transport, advertiser: NullServiceAdvertiser())
        let dataStreamServer = DataStreamServer(transport: transport, loopbackOnly: true)
        let configuration = CameraControllerConfiguration(streaming: CameraHarness.streamingOptions, recording: CameraHarness.recordingOptions,
                                                          isDoorbell: isDoorbell)
        let controller = CameraController(configuration: configuration, streamingDelegate: streaming, recordingDelegate: recording,
                                          dataStreamServer: dataStreamServer)
        await controller.install(on: accessory, server: server)
        try await server.start()
        let port = try #require(await server.port)
        return Running(accessory: accessory, server: server, dataStreamServer: dataStreamServer, controller: controller, port: port)
    }

    @Test func pairStreamAndRecord() async throws {
        let streaming = FakeStreamingDelegate()
        let recording = FakeRecordingDelegate()
        let initSegment = Data(repeating: 0xA1, count: 700)
        let fragment1 = Data(repeating: 0xB2, count: 4_000)
        let fragment2 = Data(repeating: 0xC3, count: 5_000)
        recording.state.withLock {
            $0.script = [RecordingPacket(data: initSegment, isLast: false), RecordingPacket(data: fragment1, isLast: false),
                         RecordingPacket(data: fragment2, isLast: false)]
        }
        let running = try await Self.start(isDoorbell: false, streaming: streaming, recording: recording)
        defer { await running.stop() }

        // Pair (full SRP pair-setup) and verify.
        let client = try await HAPTestController.paired(port: running.port, setupCode: try await running.server.setupCode.formatted)

        // /accessories: every camera service, the linked motion sensor, the supported configurations.
        let database = try await client.accessories()
        let accessory = try #require(database.accessory(aid: 1))
        #expect(accessory.services.map { HAPAccessoryDatabase.shortType($0.type) } == ["3E", "A2", "110", "110", "112", "113", "204", "21A", "129", "85"])
        let recordingService = try #require(accessory.service(.cameraRecordingManagement))
        let motionService = try #require(accessory.service(.motionSensor))
        #expect(recordingService.linked.contains(motionService.iid))
        let camera = try CameraAccessoryIDs(database: database)
        let stream = try #require(camera.streams.first)
        #expect(try await client.readData(stream.supportedVideo) == CameraTLV.supportedVideoStreamConfiguration(CameraHarness.streamingOptions))

        // SetupEndpoints → prepareStream → read-back.
        let request = CameraRequests.setupEndpoints(address: "127.0.0.1")
        try await client.writeData(stream.setupEndpoints, request.encoded)
        let prepare = try #require(streaming.prepares.first)
        #expect(prepare.sessionID == request.sessionID && prepare.localAddress == "127.0.0.1" && prepare.controllerVideoPort == 51_000)
        let readBack = try CameraTLV.SetupEndpointsResponse(parsing: try await client.readData(stream.setupEndpoints))
        #expect(readBack.status == .success && readBack.accessoryAddress == "127.0.0.1" && !readBack.isIPv6)
        #expect(readBack.videoSSRC == FakeStreamingDelegate.videoSSRC && readBack.audioSSRC == FakeStreamingDelegate.audioSSRC)
        #expect(readBack.videoSRTP == CameraRequests.srtp)
        #expect(try await client.readData(stream.streamingStatus) == CameraTLV.streamingStatus(.inUse))

        // Start the stream: the delegate gets the parsed parameters.
        try await client.writeData(stream.selectedConfiguration, CameraRequests.selected(request.sessionID, .start))
        guard case .start(let startedID, let video, let audio)? = streaming.requests.first else {
            Issue.record("the streaming delegate was not asked to start")
            return
        }
        #expect(startedID == request.sessionID && video == CameraRequests.video && audio == CameraRequests.audio)
        #expect(running.controller.activeLiveStreams == 1)

        // Recording prerequisites: the hub's selection and Active.
        let recordingIDs = try #require(camera.recording)
        try await client.writeData(recordingIDs.selectedConfiguration, CameraTLV.selectedRecordingConfiguration(CameraRequests.recordingSelection))
        try await client.writeValue(recordingIDs.active, 1)
        #expect(recording.calls.contains(.configuration(CameraRequests.recordingSelection)) && recording.calls.contains(.active(true)))

        // SetupDataStreamTransport (write response) → HDS with keys from this HAP session → hello → open, receive init +
        // 2 fragments, close.
        let hds = try await client.openDataStream(try #require(camera.setupDataStreamTransport))
        let open = try await hds.openRecording(streamID: 1)
        #expect(open.isAccepted && open.body["status"] == .int(0))
        let capture = try await hds.receiveRecording(streamID: 1, maximumFragments: 2)
        #expect(capture.initialization == initSegment && capture.fragments == [fragment1, fragment2])
        #expect(capture.chunkCounts == [1, 1, 1] && !capture.endOfStream && capture.closeReason == nil)
        #expect(running.controller.activeRecordingStreams == 1)
        try await hds.closeRecording(streamID: 1, reason: .normal)
        #expect(await eventually { recording.endings == [.close(1, .normal)] })
        #expect(await eventually { recording.isTerminated(1) })
        #expect(await eventually { running.controller.activeRecordingStreams == 0 })

        // End the live stream.
        try await client.writeData(stream.selectedConfiguration, CameraRequests.selected(request.sessionID, .end, video: nil, audio: nil))
        #expect(streaming.stopIDs == [request.sessionID])
        #expect(try await client.readData(stream.streamingStatus) == CameraTLV.streamingStatus(.available))

        await hds.close()
        await client.close()
    }

    /// A paired controller's `/accessories` never carries another controller's SetupEndpoints request or read-back (SRTP
    /// master key and salt), also within 5 s of its previous `/accessories`, when stored values are served. Regression
    /// (W4 HAP review): B saw A's request right after A's write and A's read-back right after A's read.
    @Test func accessoriesNeverShowAnotherControllersSRTPKeys() async throws {
        let streaming = FakeStreamingDelegate()
        let running = try await Self.start(isDoorbell: false, streaming: streaming, recording: FakeRecordingDelegate())
        defer { await running.stop() }
        let longTermKey = try #require(await running.server.longTermKey)
        let pairing = HAPAccessoryPairing(accessoryPairingID: try await running.server.deviceID.description,
                                          accessoryLongTermPublicKey: longTermKey.publicKey)
        func verifiedClient() async throws -> HAPTestController {
            let identity = HAPControllerIdentity.generate()
            await running.server.addPairingForTesting(controllerID: identity.pairingID, publicKey: identity.publicKey)
            return try await HAPTestController.connectVerified(host: "127.0.0.1", port: running.port, transport: AppleNetworkTransport(),
                                                               identity: identity, pairing: pairing)
        }
        let a = try await verifiedClient()
        let b = try await verifiedClient()
        let secrets = [CameraRequests.srtp.masterKey, CameraRequests.srtp.masterSalt]
        func setupEndpointsValue(_ database: HAPAccessoryDatabase, _ id: HAPCharacteristicID) throws -> Data {
            let characteristic = database.accessory(aid: id.aid)?.services.flatMap(\.characteristics).first { $0.iid == id.iid }
            return try #require(characteristic?.value?.base64Data)
        }
        func leaks(_ data: Data) -> Bool { secrets.contains { data.range(of: $0) != nil } }

        let first = try await b.accessories()   // contacts the handlers; the rest is within 5 s
        let setupEndpoints = try #require(try CameraAccessoryIDs(database: first).streams.first).setupEndpoints
        #expect(try setupEndpointsValue(first, setupEndpoints) == CameraTLV.SetupEndpointsResponse.defaultValue)

        let request = CameraRequests.setupEndpoints(address: "127.0.0.1")
        try await a.writeData(setupEndpoints, request.encoded)
        let afterWrite = try setupEndpointsValue(try await b.accessories(), setupEndpoints)
        #expect(!leaks(afterWrite), "B saw A's SetupEndpoints request")
        #expect(afterWrite == CameraTLV.SetupEndpointsResponse.defaultValue)

        let readBack = try await a.readData(setupEndpoints)
        #expect(leaks(readBack), "A's own read-back echoes its SRTP parameters")
        let afterRead = try setupEndpointsValue(try await b.accessories(), setupEndpoints)
        #expect(!leaks(afterRead), "B saw A's SetupEndpoints read-back")
        #expect(afterRead == CameraTLV.SetupEndpointsResponse.defaultValue)
        // A's own /accessories shows its read-back, as its GET does.
        #expect(try setupEndpointsValue(try await a.accessories(), setupEndpoints) == readBack)
        await a.close()
        await b.close()
    }

    /// Review finding (W4 round 4): the camera's admin-only writes check the open session's admin flag, which only the
    /// accessory server's Add Pairing keeps in step with the controller's stored permissions. A controller demoted (or
    /// promoted) by an admin while it is connected gets its new rights on the same connection, not after it reconnects.
    @Test func permissionChangesApplyToAConnectedControllersCameraWrites() async throws {
        let running = try await Self.start(isDoorbell: false, streaming: FakeStreamingDelegate(), recording: FakeRecordingDelegate())
        defer { await running.stop() }
        let longTermKey = try #require(await running.server.longTermKey)
        let pairing = HAPAccessoryPairing(accessoryPairingID: try await running.server.deviceID.description,
                                          accessoryLongTermPublicKey: longTermKey.publicKey)
        let adminIdentity = HAPControllerIdentity.generate()
        await running.server.addPairingForTesting(controllerID: adminIdentity.pairingID, publicKey: adminIdentity.publicKey)
        let admin = try await HAPTestController.connectVerified(host: "127.0.0.1", port: running.port, transport: AppleNetworkTransport(),
                                                                identity: adminIdentity, pairing: pairing)
        let hubIdentity = HAPControllerIdentity.generate()
        try await admin.addPairing(identifier: hubIdentity.pairingID, publicKey: hubIdentity.publicKey, isAdmin: true)
        let hub = try await HAPTestController.connectVerified(host: "127.0.0.1", port: running.port, transport: AppleNetworkTransport(),
                                                              identity: hubIdentity, pairing: pairing)
        let camera = try CameraAccessoryIDs(database: try await hub.accessories())
        let homeKitCameraActive = try #require(camera.homeKitCameraActive)
        let recordingActive = try #require(camera.recording).active
        try await hub.writeValue(homeKitCameraActive, 0)

        // Demoted while connected: the same connection's admin-only writes are refused from now on.
        try await admin.addPairing(identifier: hubIdentity.pairingID, publicKey: hubIdentity.publicKey, isAdmin: false)
        let refused = HAPStatus.insufficientPrivileges.rawValue
        await #expect(throws: HAPControllerError.characteristicStatus(aid: 1, iid: homeKitCameraActive.iid, status: refused)) {
            try await hub.writeValue(homeKitCameraActive, 1)
        }
        await #expect(throws: HAPControllerError.characteristicStatus(aid: 1, iid: recordingActive.iid, status: refused)) {
            try await hub.writeValue(recordingActive, 1)
        }
        #expect(try await hub.readValue(homeKitCameraActive) == 0)
        try await admin.writeValue(homeKitCameraActive, 0)   // the admin's own session keeps its rights

        // Promoted again, on the same connection.
        try await admin.addPairing(identifier: hubIdentity.pairingID, publicKey: hubIdentity.publicKey, isAdmin: true)
        try await hub.writeValue(homeKitCameraActive, 1)
        #expect(try await hub.readValue(homeKitCameraActive) == 1)
        #expect(await hub.isVerified)
        await admin.close()
        await hub.close()
    }

    /// HAP-NodeJS factory-resets the camera once its last pairing is gone (`handleAccessoryUnpairedForControllers`):
    /// a camera removed from one Home and added to the next (or the same) one must not carry the old hub's choices.
    @Test func removingTheLastPairingResetsTheCameraForTheNextHome() async throws {
        let streaming = FakeStreamingDelegate()
        let recording = FakeRecordingDelegate()
        let running = try await Self.start(isDoorbell: false, streaming: streaming, recording: recording)
        defer { await running.stop() }
        let setupCode = try await running.server.setupCode.formatted

        // The first Home: a recording selection, recording on, snapshots off, the camera off, both streams inactive.
        let first = try await HAPTestController.paired(port: running.port, setupCode: setupCode)
        let database = try await first.accessories()
        let camera = try CameraAccessoryIDs(database: database)
        let recordingIDs = try #require(camera.recording)
        let homeKitCameraActive = try #require(camera.homeKitCameraActive)
        let eventSnapshots = try #require(camera.eventSnapshotsActive)
        let periodicSnapshots = try #require(camera.periodicSnapshotsActive)
        let streamActive = try camera.streams.map { try #require($0.active) }
        let statusActive = try database.characteristic(.statusActive, in: .motionSensor)
        try await first.writeData(recordingIDs.selectedConfiguration, CameraTLV.selectedRecordingConfiguration(CameraRequests.recordingSelection))
        try await first.writeValue(recordingIDs.active, 1)
        for id in [homeKitCameraActive, eventSnapshots, periodicSnapshots] + streamActive { try await first.writeValue(id, 0) }
        #expect(try await first.readValue(statusActive) == 0)   // bools are sent as 0 / 1
        await #expect(throws: HAPControllerError.httpStatus(207, hapStatus: HAPStatus.notAllowedInCurrentState.rawValue)) {
            _ = try await first.snapshot(width: 640, height: 360)
        }

        // It removes its own (the only admin) pairing: the accessory is unpaired and resets itself.
        try await first.removePairing()
        await first.close()
        #expect(await eventually { await !running.server.isPaired })
        #expect(await eventually { running.controller.operatingState == OperatingModeTests.defaultState })
        #expect(await eventually { recording.calls.suffix(2) == [.active(false), .configuration(nil)] })

        // The next Home sees a camera that is on, streams, takes snapshots and has no recording selection.
        let second = try await HAPTestController.paired(port: running.port, setupCode: setupCode)
        for id in [homeKitCameraActive, eventSnapshots, periodicSnapshots] + streamActive {
            #expect(try await second.readValue(id) == 1, "\(id)")
        }
        #expect(try await second.readValue(recordingIDs.active) == 0)
        #expect(try await second.readValue(statusActive) == 1)
        await #expect(throws: HAPControllerError.characteristicStatus(aid: 1, iid: recordingIDs.selectedConfiguration.iid,
                                                                      status: HAPStatus.serviceCommunicationFailure.rawValue)) {
            _ = try await second.readData(recordingIDs.selectedConfiguration)
        }
        #expect(try await second.snapshot(width: 640, height: 360) == streaming.state.withLock { $0.snapshotData })
        await second.close()
    }

    @Test func doorbellRingAndMotionReachSubscribers() async throws {
        let running = try await Self.start(isDoorbell: true, streaming: FakeStreamingDelegate(), recording: FakeRecordingDelegate())
        defer { await running.stop() }
        // A controller that is already paired (no pair-setup).
        let identity = HAPControllerIdentity.generate()
        await running.server.addPairingForTesting(controllerID: identity.pairingID, publicKey: identity.publicKey)
        let longTermKey = try #require(await running.server.longTermKey)
        let pairing = HAPAccessoryPairing(accessoryPairingID: try await running.server.deviceID.description,
                                          accessoryLongTermPublicKey: longTermKey.publicKey)
        let client = try await HAPTestController.connectVerified(host: "127.0.0.1", port: running.port, transport: AppleNetworkTransport(),
                                                                 identity: identity, pairing: pairing)

        let database = try await client.accessories()
        let accessory = try #require(database.accessory(aid: 1))
        #expect(accessory.service(.doorbell)?.isPrimary == true)
        let switchID = try database.characteristic(.programmableSwitchEvent, in: .doorbell)
        let motionID = try database.characteristic(.motionDetected, in: .motionSensor)
        try await client.subscribe([switchID, motionID])

        running.controller.ringDoorbell()
        #expect(try await client.nextEvent(for: switchID, timeout: .seconds(2)).value == 0)
        running.controller.setMotionDetected(true)
        #expect(try await client.nextEvent(for: motionID, timeout: .seconds(2)).value == 1)

        await client.close()
    }
}
#endif
