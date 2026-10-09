#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import Synchronization
import TestSupport
import Testing
@testable import HAP
@testable import HAPCamera

/// Plan W2-1 items 2 and 3: SetupEndpoints, SelectedRTPStreamConfiguration, StreamingStatus and session teardown.
@Suite(.timeLimit(.minutes(1))) struct StreamManagementTests {
    @Test func servicesAndInitialValues() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let types = harness.accessory.services.map(\.type.uuid)
        #expect(types == ["3E", "A2", "110", "110", "112", "113", "204", "21A", "129", "85"])
        #expect(harness.streamServices.map(\.subtype) == ["0", "1"])
        #expect(harness.service(.doorbell) == nil)

        let options = CameraHarness.streamingOptions
        for service in harness.streamServices {
            #expect(service.existingCharacteristic(.supportedVideoStreamConfiguration)?.value == .data(CameraTLV.supportedVideoStreamConfiguration(options)))
            #expect(service.existingCharacteristic(.supportedAudioStreamConfiguration)?.value == .data(CameraTLV.supportedAudioStreamConfiguration(options)))
            #expect(service.existingCharacteristic(.supportedRTPConfiguration)?.value == .data(CameraTLV.supportedRTPConfiguration(options)))
            #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
            #expect(service.existingCharacteristic(.active)?.value == .uint(1))
            let session = FakeHAPSession()
            #expect(try await service.characteristic(.setupEndpoints).readData(as: session).hexString == "020102")
            #expect(try await service.characteristic(.selectedRTPStreamConfiguration).readData(as: session).hexString == "0103020102")
        }

        let recording = try #require(harness.service(.cameraRecordingManagement))
        let motion = try #require(harness.service(.motionSensor))
        let dataStream = try #require(harness.service(.dataStreamTransportManagement))
        #expect(recording.linkedServices.contains { $0 === motion })
        #expect(recording.linkedServices.contains { $0 === dataStream })
        #expect(harness.controller.motionService === motion)
        #expect(motion.existingCharacteristic(.statusActive)?.value == .bool(true))
        #expect(motion.existingCharacteristic(.statusFault)?.value == .uint(0))
        #expect(motion.existingCharacteristic(.statusTampered)?.value == .uint(0))
        #expect(dataStream.existingCharacteristic(.version)?.value == .string("1.0"))
        #expect(dataStream.existingCharacteristic(.supportedDataStreamTransportConfiguration)?.value == .data(Data([1, 3, 1, 1, 0])))
        let recordingOptions = CameraHarness.recordingOptions
        #expect(recording.existingCharacteristic(.supportedCameraRecordingConfiguration)?.value
            == .data(CameraTLV.supportedCameraRecordingConfiguration(recordingOptions, eventTriggers: RecordingEventTrigger.motion)))
        #expect(recording.existingCharacteristic(.supportedVideoRecordingConfiguration)?.value
            == .data(CameraTLV.supportedVideoRecordingConfiguration(recordingOptions)))
        #expect(recording.existingCharacteristic(.supportedAudioRecordingConfiguration)?.value
            == .data(CameraTLV.supportedAudioRecordingConfiguration(recordingOptions)))
        #expect(recording.existingCharacteristic(.active)?.value == .uint(0))
        #expect(recording.existingCharacteristic(.recordingAudioActive)?.value == .uint(0))
        #expect(harness.controller.activeLiveStreams == 0 && harness.controller.activeRecordingStreams == 0)
    }

    /// An iPhone on a VPN advertises the tunnel's address; the delegate gets both it and the HAP connection's, and the
    /// answer still names our address on the HAP connection's interface (the peer's subnet).
    @Test func aControllerAdvertisingAnotherAddressThanItsHAPConnectionIsPassedBoth() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession(localAddress: "192.0.2.5", remoteAddress: "192.0.2.20")
        let request = CameraRequests.setupEndpoints(address: "10.5.0.2")
        _ = try await service.characteristic(.setupEndpoints).write(.data(request.encoded), as: session)
        let prepare = try #require(harness.streaming.prepares.first)
        #expect(prepare.controllerAddress == "10.5.0.2" && prepare.peerAddress == "192.0.2.20" && prepare.localAddress == "192.0.2.5")
        let readBack = try CameraTLV.SetupEndpointsResponse(parsing: try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(readBack.accessoryAddress == "192.0.2.5" && readBack.status == .success)
    }

    @Test func minimalCameraWithoutRecordingOrTalkback() async {
        let harness = await CameraHarness.make(recordingOptions: nil, twoWayAudio: false, streamCount: 1)
        defer { await harness.stop() }
        #expect(harness.accessory.services.map(\.type.uuid) == ["3E", "A2", "110", "112", "85"])
        #expect(harness.controller.operatingState == CameraOperatingState(homeKitCameraActive: true, eventSnapshotsActive: true,
                                                                          periodicSnapshotsActive: true, recordingActive: false,
                                                                          recordingAudioActive: false))
    }

    @Test func setupEndpointsPreparesAndReadsBack() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession(localAddress: "192.168.1.10", remoteAddress: "192.168.1.20")
        let request = CameraRequests.setupEndpoints()
        let written = try await service.characteristic(.setupEndpoints).write(.data(request.encoded), as: session)
        #expect(written == nil)

        let prepare = try #require(harness.streaming.prepares.first)
        #expect(prepare.sessionID == request.sessionID && prepare.controllerAddress == "192.168.1.20" && prepare.isIPv6 == false)
        #expect(prepare.controllerVideoPort == 51_000 && prepare.controllerAudioPort == 51_002)
        #expect(prepare.videoSRTP == CameraRequests.srtp && prepare.audioSRTP == CameraRequests.srtp)
        #expect(prepare.localAddress == "192.168.1.10")
        #expect(prepare.peerAddress == "192.168.1.20", "the HAP connection's peer, for a controller that advertises a VPN address")

        let readBack = try CameraTLV.SetupEndpointsResponse(parsing: try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(readBack == CameraTLV.SetupEndpointsResponse(sessionID: request.sessionID, status: .success, accessoryAddress: "192.168.1.10",
                                                             isIPv6: false, videoPort: 50_000, audioPort: 50_002, videoSRTP: CameraRequests.srtp,
                                                             audioSRTP: CameraRequests.srtp, videoSSRC: FakeStreamingDelegate.videoSSRC,
                                                             audioSSRC: FakeStreamingDelegate.audioSSRC))
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.inUse)))
        #expect(harness.streamServices[1].existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        // Prepared but not started: not a live stream yet.
        #expect(harness.controller.activeLiveStreams == 0)
    }

    /// Review finding (W4 round 4): SetupEndpoints carries the controller's address as text without a scope; for a
    /// link-local one the streaming delegate needs the HAP connection's zone, which never reached it.
    @Test func theHAPConnectionsZoneReachesTheStreamingDelegate() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession(localAddress: "fe80::1", remoteAddress: "fe80::2", isIPv6: true, zone: "en0")
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(address: "fe80::2", isIPv6: true).encoded),
                                                                as: session)
        let prepared = try #require(harness.streaming.prepares.first)
        #expect(prepared.controllerAddress == "fe80::2" && prepared.connectionZone == "en0")
        // A connection without a zone (IPv4, or an address that needs none) passes none.
        let plain = FakeHAPSession()
        try await harness.streamServices[1].characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: plain)
        #expect(harness.streaming.prepares.count == 2 && harness.streaming.prepares.last?.connectionZone == nil)
    }

    @Test func addressFamilyComesFromTheSession() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession(localAddress: "fe80::1", remoteAddress: "fe80::2", isIPv6: true)
        let request = CameraRequests.setupEndpoints(address: "fe80::2", isIPv6: true)
        try await service.characteristic(.setupEndpoints).write(.data(request.encoded), as: session)
        #expect(harness.streaming.prepares.first?.isIPv6 == true)
        let readBack = try CameraTLV.SetupEndpointsResponse(parsing: try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(readBack.isIPv6 && readBack.accessoryAddress == "fe80::1")
        // The default MTU of an IPv6 session is 1228.
        var video = CameraRequests.video
        video.mtu = 0
        let configuration = CameraTLV.SelectedRTPStreamConfiguration(sessionID: request.sessionID, command: .start, video: video,
                                                                      audio: CameraRequests.audio)
        var items = try TLVReader(configuration.encoded).items
        let videoItems = try TLVReader(try #require(items.first { $0.type == 2 }?.value)).items
        let rtp = try TLVReader(try #require(videoItems.first { $0.type == 4 }?.value)).items.filter { $0.type != 5 }
        let strippedVideo = videoItems.map { $0.type == 4 ? TLV8.Item(4, TLV8.encode(rtp)) : $0 }
        items = items.map { $0.type == 2 ? TLV8.Item(2, TLV8.encode(strippedVideo)) : $0 }
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(TLV8.encode(items)), as: session)
        guard case .start(_, let startedVideo, _)? = harness.streaming.requests.first else {
            Issue.record("no start")
            return
        }
        #expect(startedVideo.mtu == 1228)
    }

    @Test func secondSetupOnABusyServiceGetsBusy() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let owner = FakeHAPSession()
        let other = FakeHAPSession()
        let first = CameraRequests.setupEndpoints()
        let second = CameraRequests.setupEndpoints()
        try await service.characteristic(.setupEndpoints).write(.data(first.encoded), as: owner)
        try await service.characteristic(.setupEndpoints).write(.data(second.encoded), as: other)
        #expect(harness.streaming.prepares.count == 1)
        let busy = try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: other))
        #expect(busy.uint8(0x02) == CameraTLV.SetupEndpointsStatus.busy.rawValue)
        #expect(busy.data(0x01) == CameraTLV.bytes(of: second.sessionID))
        let ownerRead = try CameraTLV.SetupEndpointsResponse(parsing: try await service.characteristic(.setupEndpoints).readData(as: owner))
        #expect(ownerRead.status == .success && ownerRead.sessionID == first.sessionID)
    }

    @Test func prepareFailureFailsTheWriteAndFreesTheService() async throws {
        let streaming = FakeStreamingDelegate()
        streaming.state.withLock { $0.prepareError = FakeDelegateError() }
        let harness = await CameraHarness.make(streaming: streaming)
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let request = CameraRequests.setupEndpoints()
        let status = await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(request.encoded), as: session) }
        #expect(status == .serviceCommunicationFailure)
        let readBack = try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(readBack.uint8(0x02) == CameraTLV.SetupEndpointsStatus.error.rawValue)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        #expect(streaming.requests.isEmpty)   // prepare failed: nothing to stop
        // A delegate that throws a HAPStatus keeps it.
        streaming.state.withLock { $0.prepareError = HAPStatus.resourceBusy }
        let busy = await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: session) }
        #expect(busy == .resourceBusy)
    }

    @Test func startReconfigureAndEnd() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[1]
        let session = FakeHAPSession()
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        let start = CameraRequests.selected(id, .start)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(start), as: session)
        guard case .start(let startedID, let video, let audio)? = harness.streaming.requests.first else {
            Issue.record("no start request")
            return
        }
        #expect(startedID == id && video == CameraRequests.video && audio == CameraRequests.audio)
        #expect(harness.controller.activeLiveStreams == 1)
        #expect(try await service.characteristic(.selectedRTPStreamConfiguration).readData(as: session) == start)

        var reconfigured = CameraRequests.video
        reconfigured.resolution = VideoResolution(640, 360, 30)
        reconfigured.maxBitrateKbps = 150
        try await service.characteristic(.selectedRTPStreamConfiguration)
            .write(.data(CameraRequests.selected(id, .reconfigure, video: reconfigured, audio: nil)), as: session)
        guard case .reconfigure(let reconfiguredID, let newVideo)? = harness.streaming.requests.last else {
            Issue.record("no reconfigure request")
            return
        }
        #expect(reconfiguredID == id && newVideo == reconfigured)

        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .end, video: nil, audio: nil)), as: session)
        // The service is free at once; the delegate's `.stop` follows without holding the End up.
        #expect(harness.controller.activeLiveStreams == 0)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        #expect(try await service.characteristic(.setupEndpoints).readData(as: session).hexString == "020102")
        #expect(try await service.characteristic(.selectedRTPStreamConfiguration).readData(as: session).hexString == "0103020102")
        // Closing the HAP connection afterwards does not stop again (its close was handled once the watch is gone).
        #expect(harness.streamManagements[1].watchedHAPSessionCount == 1)
        session.close()
        #expect(await eventually { harness.streamManagements[1].watchedHAPSessionCount == 0 })
        #expect(harness.streaming.stopIDs == [id])
    }

    /// Review finding (W4 round 4): a reconfigure the streaming delegate fails ends the session (the delegate is told to
    /// stop it, the stream is Available again) and answers -70402; that branch never ran.
    @Test func aReconfigureTheDelegateFailsEndsTheSession() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: session)
        #expect(harness.controller.activeLiveStreams == 1)
        harness.streaming.state.withLock { $0.reconfigureError = FakeDelegateError() }
        var reconfigured = CameraRequests.video
        reconfigured.maxBitrateKbps = 150
        let status = await hapStatus {
            try await service.characteristic(.selectedRTPStreamConfiguration)
                .write(.data(CameraRequests.selected(id, .reconfigure, video: reconfigured, audio: nil)), as: session)
        }
        #expect(status == .serviceCommunicationFailure)
        #expect(harness.streaming.stopIDs == [id], "the half-configured session is stopped")
        #expect(harness.controller.activeLiveStreams == 0)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        // The stream can be set up again.
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: session)
        #expect(harness.streaming.prepares.count == 2)
    }

    @Test func invalidSessionCommandsAreRejected() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let selected = harness.streamServices[0].characteristic(.selectedRTPStreamConfiguration)
        let session = FakeHAPSession()
        let id = UUID()
        // No session yet.
        #expect(await hapStatus { try await selected.write(.data(CameraRequests.selected(id, .start)), as: session) } == .invalidValue)
        try await harness.streamServices[0].characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        // Wrong session id, suspend, resume, reconfigure before start, garbage.
        #expect(await hapStatus { try await selected.write(.data(CameraRequests.selected(UUID(), .start)), as: session) } == .invalidValue)
        #expect(await hapStatus { try await selected.write(.data(CameraRequests.selected(id, .suspend, video: nil, audio: nil)), as: session) } == .invalidValue)
        #expect(await hapStatus { try await selected.write(.data(CameraRequests.selected(id, .resume, video: nil, audio: nil)), as: session) } == .invalidValue)
        #expect(await hapStatus { try await selected.write(.data(CameraRequests.selected(id, .reconfigure, audio: nil)), as: session) } == .invalidValue)
        #expect(await hapStatus { try await selected.write(.data(Data([0x01, 0x02, 0x03])), as: session) } == .invalidValue)
        #expect(await hapStatus { try await selected.write(.data(CameraRequests.selected(id, .start, video: nil)), as: session) } == .invalidValue)
        #expect(harness.streaming.requests.isEmpty)
        // Start works once; a second start is rejected.
        try await selected.write(.data(CameraRequests.selected(id, .start)), as: session)
        #expect(await hapStatus { try await selected.write(.data(CameraRequests.selected(id, .start)), as: session) } == .invalidValue)
        #expect(harness.streaming.startIDs == [id])
    }

    @Test func startFailureStopsTheSession() async throws {
        let streaming = FakeStreamingDelegate()
        streaming.state.withLock { $0.startError = FakeDelegateError() }
        let harness = await CameraHarness.make(streaming: streaming)
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        let status = await hapStatus { try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: session) }
        #expect(status == .serviceCommunicationFailure)
        #expect(streaming.stopIDs == [id])
        #expect(harness.controller.activeLiveStreams == 0)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
    }

    @Test func closingTheHAPSessionStopsItsStream() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        // Prepared only.
        let prepared = FakeHAPSession()
        let preparedID = UUID()
        try await harness.streamServices[0].characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: preparedID).encoded), as: prepared)
        // Started.
        let started = FakeHAPSession()
        let startedID = UUID()
        let service = harness.streamServices[1]
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: startedID).encoded), as: started)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(startedID, .start)), as: started)
        #expect(harness.controller.activeLiveStreams == 1)

        started.close()
        #expect(await eventually { harness.streaming.stopIDs == [startedID] })
        #expect(await eventually { harness.controller.activeLiveStreams == 0 })
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        prepared.close()
        #expect(await eventually { harness.streaming.stopIDs == [startedID, preparedID] })
        #expect(harness.streamServices[0].existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
    }

    @Test func connectionClosingWhilePreparingStopsAfterPrepare() async throws {
        let streaming = FakeStreamingDelegate()
        let gate = Gate()
        streaming.state.withLock { $0.prepareGate = gate }
        let harness = await CameraHarness.make(streaming: streaming)
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        let write = Task { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session) }
        #expect(await eventually { streaming.prepares.count == 1 })
        session.close()
        // The teardown waits for the setup: nothing to stop until prepare returns.
        #expect(await eventually { harness.streamManagements[0].queuedOperationCount == 1 })
        #expect(streaming.stopIDs.isEmpty)
        await gate.open()
        _ = try? await write.value
        #expect(await eventually { streaming.stopIDs == [id] })
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
    }

    @Test func setupWhoseRequestTimedOutIsReleased() async throws {
        let streaming = FakeStreamingDelegate()
        let gate = Gate()
        streaming.state.withLock { $0.prepareGate = gate }
        let harness = await CameraHarness.make(streaming: streaming)
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        // The server cancels a handler that exceeds its timeout: the setup gives up on the prepare at once, and a
        // prepare that completes afterwards is stopped again.
        let write = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session) }
        }
        #expect(await eventually { streaming.prepares.count == 1 })
        write.cancel()
        #expect(await value(of: write) == .operationTimedOut)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        let readBack = try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(readBack.uint8(0x02) == CameraTLV.SetupEndpointsStatus.error.rawValue)
        #expect(streaming.stopIDs.isEmpty)
        await gate.open()
        #expect(await eventually { streaming.stopIDs == [id] })
    }

    @Test func streamingAvailabilityDrivesStreamingStatus() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let session = FakeHAPSession()
        harness.controller.setStreamingAvailable(false)
        for service in harness.streamServices {
            #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.unavailable)))
        }
        let service = harness.streamServices[0]
        let request = CameraRequests.setupEndpoints()
        try await service.characteristic(.setupEndpoints).write(.data(request.encoded), as: session)
        #expect(harness.streaming.prepares.isEmpty)
        let readBack = try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(readBack.uint8(0x02) == CameraTLV.SetupEndpointsStatus.error.rawValue)

        harness.controller.setStreamingAvailable(true)
        for service in harness.streamServices {
            #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        }
        // A stream in use stays in use while the camera goes away; its end leaves the service unavailable.
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        harness.controller.setStreamingAvailable(false)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.inUse)))
        #expect(harness.streamServices[1].existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.unavailable)))
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .end, video: nil, audio: nil)), as: session)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.unavailable)))
    }

    @Test func streamActiveCharacteristicDisablesStreaming() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let admin = FakeHAPSession()
        let user = FakeHAPSession(isAdmin: false)
        let service = harness.streamServices[0]
        let active = try #require(service.existingCharacteristic(.active))
        #expect(await hapStatus { try await active.write(.uint(0), as: user) } == .insufficientPrivileges)

        // Active while streaming → the stream stops.
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: admin)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: admin)
        try await active.write(.uint(0), as: admin)
        #expect(await eventually { harness.streaming.stopIDs == [id] })

        #expect(await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: admin) }
            == .notAllowedInCurrentState)
        #expect(await hapStatus { try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: admin) }
            == .notAllowedInCurrentState)
        #expect(try await service.characteristic(.setupEndpoints).readData(as: admin).hexString == "020102")
        #expect(try await service.characteristic(.selectedRTPStreamConfiguration).readData(as: admin).hexString == "0103020102")
        // The other stream service is unaffected.
        try await harness.streamServices[1].characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: admin)
        #expect(harness.streaming.prepares.count == 2)
    }

    // MARK: - Accessory-side stop, deadlines, cancellation, close handlers, address family

    @Test func accessoryCanEndALiveSession() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[1]
        let session = FakeHAPSession()
        let id = UUID()
        #expect(harness.controller.stopStreamingSession(id) == false)
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: session)
        #expect(harness.controller.activeLiveStreams == 1)

        // E.g. no RTCP for 30 s: the delegate ends the session it serves.
        #expect(harness.controller.stopStreamingSession(id))
        #expect(await eventually { harness.streaming.stopIDs == [id] })
        #expect(harness.controller.activeLiveStreams == 0)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        #expect(try await service.characteristic(.setupEndpoints).readData(as: session).hexString == "020102")
        #expect(try await service.characteristic(.selectedRTPStreamConfiguration).readData(as: session).hexString == "0103020102")
        // Exactly one stop: a second call, the controller's own end and its connection closing change nothing.
        #expect(harness.controller.stopStreamingSession(id) == false)
        // A user's log: the iPhone's end for the session the accessory ended first used to log a warning and answer an
        // error; it is a no-op now, and a start for the dead session is still refused.
        #expect(await hapStatus { try await service.characteristic(.selectedRTPStreamConfiguration)
            .write(.data(CameraRequests.selected(id, .end, video: nil, audio: nil)), as: session) } == nil)
        #expect(await hapStatus { try await service.characteristic(.selectedRTPStreamConfiguration)
            .write(.data(CameraRequests.selected(id, .start)), as: session) } == .invalidValue)
        session.close()
        #expect(await eventually { harness.streamManagements[1].watchedHAPSessionCount == 0 })
        #expect(harness.streaming.stopIDs == [id])
        // The service takes a new controller.
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: FakeHAPSession())
        #expect(harness.streaming.prepares.count == 2)
    }

    /// Field report (live views retried forever): after the accessory ended a session the service was free only once a
    /// queued task ran, so the iPhone's immediate retry could be refused as busy, and its late end for the old session
    /// must never touch the new one.
    @Test func aRetryRightAfterTheAccessoryEndedIsNotBusyAndAStaleEndLeavesTheNewSessionAlone() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let old = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: old).encoded), as: session)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(old, .start)), as: session)
        #expect(harness.controller.stopStreamingSession(old))
        // No waiting: the very next setup is admitted.
        let new = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: new).encoded), as: session)
        #expect(harness.streaming.prepares.count == 2)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(new, .start)), as: session)
        // The old session's end arrives late.
        #expect(await hapStatus { try await service.characteristic(.selectedRTPStreamConfiguration)
            .write(.data(CameraRequests.selected(old, .end, video: nil, audio: nil)), as: session) } == nil)
        #expect(await eventually { harness.streaming.stopIDs == [old] })
        #expect(harness.controller.activeLiveStreams == 1, "the new session is still streaming")
        #expect(harness.streaming.startIDs == [old, new])
    }

    @Test func accessoryStopFromInsideADelegateCallDoesNotDeadlock() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let controller = harness.controller
        let found = Counter()
        harness.streaming.state.withLock { $0.onStart = { [weak controller] id in if controller?.stopStreamingSession(id) == true { found.increment() } } }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: session)
        #expect(found.value == 1)
        #expect(await eventually { harness.streaming.stopIDs == [id] })
        #expect(await eventually { harness.controller.activeLiveStreams == 0 })
    }

    @Test func hungPrepareMissesItsDeadline() async throws {
        let streaming = FakeStreamingDelegate()
        let gate = Gate()
        streaming.state.withLock { $0.prepareGate = gate }
        let harness = await CameraHarness.make(timings: CameraControllerTimings(streamingDelegateTimeout: .milliseconds(200)), streaming: streaming)
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        let write = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session) }
        }
        #expect(await value(of: write, within: .seconds(3)) == .operationTimedOut)
        let readBack = try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(readBack.uint8(0x02) == CameraTLV.SetupEndpointsStatus.error.rawValue)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))

        // The service is not wedged: the next setup runs while the first prepare still hangs.
        streaming.state.withLock { $0.prepareGate = nil }
        let next = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: FakeHAPSession()) }
        }
        #expect(await value(of: next, within: .seconds(3)) == .some(nil))
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.inUse)))
        // The abandoned prepare finishes after all: it gets its stop, the new session is untouched.
        await gate.open()
        #expect(await eventually { streaming.stopIDs == [id] })
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.inUse)))
    }

    @Test func hungStartAndStopMissTheirDeadline() async throws {
        let streaming = FakeStreamingDelegate()
        let startGate = Gate()
        let stopGate = Gate()
        streaming.state.withLock {
            $0.startGate = startGate
            $0.stopGate = stopGate
        }
        let harness = await CameraHarness.make(timings: CameraControllerTimings(streamingDelegateTimeout: .milliseconds(200)), streaming: streaming)
        defer {
            await startGate.open()
            await stopGate.open()
            await harness.stop()
        }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        let start = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: session) }
        }
        #expect(await value(of: start, within: .seconds(3)) == .operationTimedOut)
        // A failed start ends the session (its stop hangs too, and is abandoned in turn).
        #expect(streaming.stopIDs == [id])
        #expect(harness.controller.activeLiveStreams == 0)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        let next = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: FakeHAPSession()) }
        }
        #expect(await value(of: next, within: .seconds(3)) == .some(nil))
        #expect(streaming.prepares.count == 2)
    }

    @Test func requestsThatTimeOutWhileQueuedNeverReachTheDelegate() async throws {
        let streaming = FakeStreamingDelegate()
        let gate = Gate()
        streaming.state.withLock { $0.prepareGate = gate }
        let harness = await CameraHarness.make(streaming: streaming)   // standard 8 s deadline
        defer {
            await gate.open()
            await harness.stop()
        }
        let service = harness.streamServices[0]
        let management = harness.streamManagements[0]
        let first = FakeHAPSession()
        let firstID = UUID()
        let firstWrite = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: firstID).encoded), as: first) }
        }
        #expect(await eventually { streaming.prepares.count == 1 })
        // A second controller's setup and a command queue behind the hung prepare; their HAP requests time out.
        let second = FakeHAPSession()
        let queuedSetup = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: second) }
        }
        let queuedStart = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(firstID, .start)), as: first) }
        }
        #expect(await eventually { management.queuedOperationCount == 2 })
        queuedSetup.cancel()
        queuedStart.cancel()
        #expect(await value(of: queuedSetup, within: .seconds(2)) == .operationTimedOut)
        #expect(await value(of: queuedStart, within: .seconds(2)) == .operationTimedOut)
        #expect(management.queuedOperationCount == 0)
        #expect(streaming.prepares.count == 1 && streaming.startIDs.isEmpty)

        // The hung setup's own request times out and its connection closes: the service is free again at once.
        firstWrite.cancel()
        #expect(await value(of: firstWrite, within: .seconds(2)) == .operationTimedOut)
        first.close()
        streaming.state.withLock { $0.prepareGate = nil }
        let third = UUID()
        let thirdWrite = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: third).encoded), as: FakeHAPSession()) }
        }
        #expect(await value(of: thirdWrite, within: .seconds(2)) == .some(nil))
        #expect(streaming.prepares.map(\.sessionID).last == third)
        await gate.open()
        #expect(await eventually { streaming.stopIDs == [firstID] })
    }

    @Test func oneCloseHandlerPerHAPSession() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        for _ in 0..<50 {
            let id = UUID()
            try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
            try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .end, video: nil, audio: nil)), as: session)
        }
        #expect(session.closeHandlerCount == 1)
        #expect(harness.streamManagements[0].watchedHAPSessionCount == 1)
        #expect(await eventually { harness.streaming.stopIDs.count == 50 })
        // A refused controller is watched too (its busy read-back goes away with it).
        let last = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: last).encoded), as: session)
        let refused = FakeHAPSession()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: refused)
        #expect(refused.closeHandlerCount == 1 && harness.streamManagements[0].watchedHAPSessionCount == 2)
        refused.close()
        #expect(await eventually { harness.streamManagements[0].watchedHAPSessionCount == 1 })
        #expect(harness.streaming.stopIDs.count == 50)   // the refused controller owned nothing
        // The one handler still ends whichever session the connection owns now.
        session.close()
        #expect(await eventually { harness.streaming.stopIDs.last == last && harness.streaming.stopIDs.count == 51 })
        #expect(await eventually { harness.streamManagements[0].watchedHAPSessionCount == 0 })
    }

    @Test func accessoryAddressMustMatchTheRequestedFamily() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        // An IPv4 HAP connection whose controller asks for an IPv6 stream; the delegate answers with the connection's
        // IPv4 address.
        let session = FakeHAPSession(localAddress: "192.168.1.10", remoteAddress: "192.168.1.20")
        let id = UUID()
        let status = await hapStatus { try await service.characteristic(.setupEndpoints)
            .write(.data(CameraRequests.setupEndpoints(id: id, address: "fe80::2", isIPv6: true).encoded), as: session) }
        #expect(status == .serviceCommunicationFailure)
        #expect(harness.streaming.stopIDs == [id])   // it was prepared, so it is stopped
        let readBack = try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(readBack.uint8(0x02) == CameraTLV.SetupEndpointsStatus.error.rawValue)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))

        // A delegate that resolves an address of the requested family is fine (and the read-back says IPv6).
        harness.streaming.state.withLock { $0.accessoryAddressOverride = "fe80::10" }
        let ipv6 = UUID()
        try await service.characteristic(.setupEndpoints)
            .write(.data(CameraRequests.setupEndpoints(id: ipv6, address: "fe80::2", isIPv6: true).encoded), as: session)
        let accepted = try CameraTLV.SetupEndpointsResponse(parsing: try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(accepted.status == .success && accepted.isIPv6 && accepted.accessoryAddress == "fe80::10")
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(ipv6, .end, video: nil, audio: nil)), as: session)

        // Something that is no IP address at all is refused as well.
        harness.streaming.state.withLock { $0.accessoryAddressOverride = "camera.local" }
        #expect(await hapStatus { try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: session) }
            == .serviceCommunicationFailure)
        #expect(RTPStreamManagement.isIPv6Address("10.0.0.1") == false && RTPStreamManagement.isIPv6Address("fe80::1%en0") == true)
        #expect(RTPStreamManagement.isIPv6Address("10.0.0") == nil && RTPStreamManagement.isIPv6Address("") == nil)
        #expect(RTPStreamManagement.unmapped("::FFFF:192.168.1.10") == "192.168.1.10" && RTPStreamManagement.unmapped("::ffff:1") == "::ffff:1")

        // An IPv4-mapped answer to an IPv4 request is advertised as the plain IPv4 address.
        harness.streaming.state.withLock { $0.accessoryAddressOverride = "::ffff:192.168.1.10" }
        let mapped = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: mapped).encoded), as: session)
        let mappedReadBack = try CameraTLV.SetupEndpointsResponse(parsing: try await service.characteristic(.setupEndpoints).readData(as: session))
        #expect(mappedReadBack.status == .success && !mappedReadBack.isIPv6 && mappedReadBack.accessoryAddress == "192.168.1.10")
    }

    // MARK: - Sessions that never start (hardening plan WS-C 2)

    /// Audit A2: a controller that prepared a stream and then vanished (or whose Start was lost) left the service "in use"
    /// for good. The prepared session expires, the status reads available, the delegate gets exactly one `.stop` and the
    /// next controller is admitted.
    @Test func aPreparedSessionThatIsNeverStartedExpires() async throws {
        let harness = await CameraHarness.make(timings: CameraControllerTimings(preparedSessionTimeout: .milliseconds(300)))
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: FakeHAPSession())
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.inUse)))
        #expect(harness.streaming.stopIDs.isEmpty)

        #expect(await eventually { service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)) })
        #expect(await eventually { harness.streaming.stopIDs == [id] })
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.streaming.stopIDs == [id], "exactly one stop")
        #expect(!harness.streamManagements[0].hasSession(id))

        // A new controller is not refused as busy.
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: FakeHAPSession())
        #expect(harness.streaming.prepares.count == 2)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.inUse)))
    }

    @Test func aStartedSessionDoesNotExpire() async throws {
        let harness = await CameraHarness.make(timings: CameraControllerTimings(preparedSessionTimeout: .milliseconds(200)))
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: session)
        try await Task.sleep(for: .milliseconds(600))
        #expect(harness.controller.activeLiveStreams == 1)
        #expect(harness.streaming.stopIDs.isEmpty)
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.inUse)))
    }

    /// Audit B7 / network #3: the same controller setting up again (its first attempt's Start never came) is not refused as
    /// busy by its own leftover; the leftover is ended, and its single `.stop` still reaches the delegate.
    @Test func aNewSetupFromTheSameControllerSupersedesItsUnstartedSession() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let controllerID = UUID().uuidString
        let first = UUID(), second = UUID()
        // The same controller on a new HAP connection (the old one is not known to be dead yet).
        try await service.characteristic(.setupEndpoints)
            .write(.data(CameraRequests.setupEndpoints(id: first).encoded), as: FakeHAPSession(controllerID: controllerID))
        try await service.characteristic(.setupEndpoints)
            .write(.data(CameraRequests.setupEndpoints(id: second).encoded), as: FakeHAPSession(controllerID: controllerID))
        #expect(harness.streaming.prepares.map(\.sessionID) == [first, second])
        #expect(harness.streamManagements[0].hasSession(second) && !harness.streamManagements[0].hasSession(first))
        #expect(await eventually { harness.streaming.stopIDs == [first] })
    }

    @Test func aNewSetupOnTheSameHAPConnectionSupersedesEvenARunningSession() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let old = UUID(), new = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: old).encoded), as: session)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(old, .start)), as: session)
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: new).encoded), as: session)
        #expect(harness.streamManagements[0].hasSession(new) && !harness.streamManagements[0].hasSession(old))
        #expect(await eventually { harness.streaming.stopIDs == [old] })
    }

    /// A different controller's running stream is never taken over, and the same controller on another connection does not
    /// take over a *running* stream either (it may be that user's other device).
    @Test func otherConnectionsAreStillRefusedWhileARunningStreamHoldsTheService() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let controllerID = UUID().uuidString
        let owner = FakeHAPSession(controllerID: controllerID)
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: owner)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: owner)
        let stranger = FakeHAPSession()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: stranger)
        let refused = try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: stranger))
        #expect(refused.uint8(0x02) == CameraTLV.SetupEndpointsStatus.busy.rawValue)
        let sibling = FakeHAPSession(controllerID: controllerID)
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: sibling)
        let siblingRefused = try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: sibling))
        #expect(siblingRefused.uint8(0x02) == CameraTLV.SetupEndpointsStatus.busy.rawValue)
        #expect(harness.controller.activeLiveStreams == 1 && harness.streaming.stopIDs.isEmpty)
    }

    /// An unstarted session older than `staleUnstartedSessionAge` yields to anyone; a younger one of another controller
    /// does not.
    @Test func aStaleUnstartedSessionYieldsToAnotherController() async throws {
        let harness = await CameraHarness.make(timings: CameraControllerTimings(preparedSessionTimeout: .seconds(30),
                                                                                staleUnstartedSessionAge: .milliseconds(300)))
        defer { await harness.stop() }
        let service = harness.streamServices[0]
        let old = UUID(), new = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: old).encoded), as: FakeHAPSession())
        let early = FakeHAPSession()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: early)
        #expect(try TLVReader(try await service.characteristic(.setupEndpoints).readData(as: early)).uint8(0x02)
            == CameraTLV.SetupEndpointsStatus.busy.rawValue, "not stale yet")
        try await Task.sleep(for: .milliseconds(450))
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: new).encoded), as: FakeHAPSession())
        #expect(harness.streamManagements[0].hasSession(new))
        #expect(await eventually { harness.streaming.stopIDs == [old] })
    }

    /// Audit B8: the controller's End frees the service at once and does not wait for the delegate's `.stop`.
    @Test func theControllersEndDoesNotWaitForTheDelegatesStop() async throws {
        let streaming = FakeStreamingDelegate()
        let stopGate = Gate()
        let harness = await CameraHarness.make(streaming: streaming)
        defer {
            await stopGate.open()
            await harness.stop()
        }
        let service = harness.streamServices[0]
        let session = FakeHAPSession()
        let id = UUID()
        try await service.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: session)
        try await service.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: session)
        streaming.state.withLock { $0.stopGate = stopGate }
        let end = Task { () async -> HAPStatus? in
            await hapStatus { try await service.characteristic(.selectedRTPStreamConfiguration)
                .write(.data(CameraRequests.selected(id, .end, video: nil, audio: nil)), as: session) }
        }
        #expect(await value(of: end, within: .seconds(2)) == .some(nil), "End answered while the stop is still hanging")
        #expect(service.existingCharacteristic(.streamingStatus)?.value == .data(CameraTLV.streamingStatus(.available)))
        await stopGate.open()
        #expect(await eventually { streaming.stopIDs == [id] })
    }
}

#endif
