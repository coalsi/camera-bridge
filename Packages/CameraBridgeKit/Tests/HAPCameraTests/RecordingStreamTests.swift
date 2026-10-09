#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import HDS
import PlatformApple
import Synchronization
import TestSupport
import Testing
@testable import HAP
@testable import HAPCamera

/// Plan W2-1 items 6 and 7: SetupDataStreamTransport → HDS → `dataSend` recording streams, over a loopback HDS
/// connection opened for a fake HAP session.
@Suite(.timeLimit(.minutes(1))) struct RecordingStreamTests {
    struct Fixture {
        let harness: CameraHarness
        let admin: FakeHAPSession
        let client: HDSLoopbackClient
        /// The accessory's end of the connection when it runs over a `FakeNetworkTransport` (to stall its sends).
        let accessoryEnd: FakeTCPConnection?

        /// Over loopback TCP, or over `fakeTransport` (which the harness's data stream server must use) when given.
        static func make(_ harness: CameraHarness, select: Bool = true, selection: CameraRecordingConfiguration = CameraRequests.recordingSelection,
                         activate: Bool = true, fakeTransport: FakeNetworkTransport? = nil,
                         admin existingAdmin: FakeHAPSession? = nil) async throws -> Fixture {
            let admin = existingAdmin ?? FakeHAPSession(sharedSecret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            if select {
                try await harness.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration)
                    .write(.data(CameraTLV.selectedRecordingConfiguration(selection)), as: admin)
            }
            if activate { try await harness.characteristic(.cameraRecordingManagement, .active).write(.uint(1), as: admin) }
            let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let written = try await harness.characteristic(.dataStreamTransportManagement, .setupDataStreamTransport)
                .write(.data(CameraTLV.SetupDataStreamTransportRequest(controllerKeySalt: salt).encoded), as: admin)
            let response = try CameraTLV.SetupDataStreamTransportResponse(parsing: try #require(written?.dataValue))
            let client: HDSLoopbackClient
            var accessoryEnd: FakeTCPConnection?
            if let fakeTransport {
                let listener = try #require(fakeTransport.listeners.last { $0.port == response.port })
                let (clientEnd, serverEnd) = FakeTCPConnection.pair()
                listener.accept(serverEnd)
                accessoryEnd = serverEnd
                client = HDSLoopbackClient(connection: clientEnd, sharedSecret: admin.sharedSecret, controllerKeySalt: salt,
                                           accessoryKeySalt: response.accessoryKeySalt)
            } else {
                client = try await HDSLoopbackClient.connect(transport: AppleNetworkTransport(), port: response.port, sharedSecret: admin.sharedSecret,
                                                             controllerKeySalt: salt, accessoryKeySalt: response.accessoryKeySalt)
            }
            let hello = try await client.hello()
            #expect(hello.kind == .response(id: 1, status: .success))
            return Fixture(harness: harness, admin: admin, client: client, accessoryEnd: accessoryEnd)
        }

        static func openBody(streamID: Int64, type: String = "ipcamera.recording", target: String = "controller") -> HDSDictionary {
            HDSDictionary([("target", .string(target)), ("type", .string(type)), ("streamId", .int(streamID))])
        }

        func open(streamID: Int64 = 1, type: String = "ipcamera.recording", target: String = "controller") async throws -> HDSMessage {
            try await client.request(protocol: "dataSend", topic: "open", body: Self.openBody(streamID: streamID, type: type, target: target))
        }

        func chunk() async throws -> DataSendChunk {
            let message = try await client.receiveMessage()
            guard let chunk = DataSendChunk(message) else { throw FixtureError(description: "not a data event: \(message.topic)") }
            return chunk
        }

        /// The next `dataSend/close` event's reason.
        func closeReason() async throws -> Int64? {
            let message = try await client.receiveMessage()
            guard message.kind == .event, message.protocolName == "dataSend", message.topic == "close" else {
                throw FixtureError(description: "expected close, got \(message.protocolName)/\(message.topic)")
            }
            guard case .int(let reason)? = message.body["reason"] else { return nil }
            #expect(message.body["streamId"] == .int(1))
            return reason
        }

        func acknowledge(streamID: Int64 = 1) async throws {
            try await client.event(protocol: "dataSend", topic: "ack", body: HDSDictionary([("streamId", .int(streamID)), ("endOfStream", .bool(true))]))
        }

        func stop() async {
            await client.close()
            await harness.stop()
        }
    }

    static func rejection(_ response: HDSMessage) -> Int64? {
        guard case .response(_, .protocolSpecificError) = response.kind, case .int(let reason)? = response.body["status"] else { return nil }
        return reason
    }

    static func accepted(_ response: HDSMessage) -> Bool {
        guard case .response(_, .success) = response.kind else { return false }
        return response.body["status"] == .int(0)
    }

    /// Research brief §3.8 / integration brief §5.3: the hub's ack is awaited 12 s after the last packet, a closed stream
    /// must stop within 10 s, recordings are capped at 3 minutes (by the delegate; the controller's backstop gives it one
    /// fragment and 5 s more); each streaming delegate call has 8 s (below HAP's 9 s). Every other test shortens these, so
    /// a debug value left in a default would otherwise go unnoticed.
    @Test func timersDefaultToTheBriefsValues() {
        #expect(CameraControllerTimings.standard == CameraControllerTimings(recordingAcknowledgeTimeout: .seconds(12), recordingStopTimeout: .seconds(10),
                                                                           maximumRecordingDuration: .seconds(180), recordingCapGrace: .seconds(5),
                                                                           streamingDelegateTimeout: .seconds(8),
                                                                           preparedSessionTimeout: .seconds(20),
                                                                           staleUnstartedSessionAge: .seconds(15)))
        #expect(CameraControllerTimings() == .standard)
        #expect(CameraControllerTimings.standard.recordingBackstop(fragmentLength: .seconds(4)) == .seconds(189))
    }

    @Test func openIsValidated() async throws {
        let harness = await CameraHarness.make()
        let fixture = try await Fixture.make(harness, select: false, activate: false)
        defer { await fixture.stop() }
        #expect(Self.rejection(try await fixture.open(type: "ipcamera.snapshot")) == HDSProtocolReason.unexpectedFailure.rawValue)
        #expect(Self.rejection(try await fixture.open(target: "accessory")) == HDSProtocolReason.unexpectedFailure.rawValue)
        #expect(Self.rejection(try await fixture.open()) == HDSProtocolReason.notAllowed.rawValue)   // recording inactive
        try await harness.characteristic(.cameraRecordingManagement, .active).write(.uint(1), as: fixture.admin)
        #expect(Self.rejection(try await fixture.open()) == HDSProtocolReason.invalidConfiguration.rawValue)   // nothing selected
        try await harness.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration)
            .write(.data(CameraTLV.selectedRecordingConfiguration(CameraRequests.recordingSelection)), as: fixture.admin)
        try await harness.characteristic(.cameraOperatingMode, .homeKitCameraActive).write(.uint(0), as: fixture.admin)
        #expect(Self.rejection(try await fixture.open()) == HDSProtocolReason.notAllowed.rawValue)   // camera off
        try await harness.characteristic(.cameraOperatingMode, .homeKitCameraActive).write(.uint(1), as: fixture.admin)
        #expect(Self.accepted(try await fixture.open(streamID: 1)))
        #expect(await eventually { harness.controller.activeRecordingStreams == 1 })
        #expect(Self.rejection(try await fixture.open(streamID: 2)) == HDSProtocolReason.busy.rawValue)
        #expect(harness.recording.calls.contains(.stream(1)) && !harness.recording.calls.contains(.stream(2)))
    }

    @Test func packetsAreChunkedAndNumbered() async throws {
        let recording = FakeRecordingDelegate()
        let initSegment = Data(repeating: 1, count: 100)
        let big = Data((0..<(0x40000 + 5)).map { UInt8(truncatingIfNeeded: $0) })
        let last = Data(repeating: 3, count: 10)
        recording.state.withLock {
            $0.script = [RecordingPacket(data: initSegment, isLast: false), RecordingPacket(data: big, isLast: false),
                         RecordingPacket(data: last, isLast: true)]
        }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open(streamID: 7)))

        let first = try await fixture.chunk()
        #expect(first.streamID == 7 && first.data == initSegment && first.dataType == "mediaInitialization")
        #expect(first.sequence == 1 && first.chunk == 1 && first.isLastChunk && first.totalSize == 100 && first.endOfStream == false)
        let second = try await fixture.chunk()
        #expect(second.dataType == "mediaFragment" && second.sequence == 2 && second.chunk == 1 && !second.isLastChunk)
        #expect(second.totalSize == Int64(big.count) && second.endOfStream == nil && second.data.count == 0x40000)
        let third = try await fixture.chunk()
        #expect(third.sequence == 2 && third.chunk == 2 && third.isLastChunk && third.totalSize == nil && third.endOfStream == false)
        #expect(second.data + third.data == big)
        let fourth = try await fixture.chunk()
        #expect(fourth.sequence == 3 && fourth.chunk == 1 && fourth.isLastChunk && fourth.totalSize == 10 && fourth.endOfStream == true)
        #expect(fourth.data == last)

        try await fixture.acknowledge(streamID: 7)
        #expect(await eventually { recording.endings == [.acknowledge(7)] })
        #expect(await eventually { harness.controller.activeRecordingStreams == 0 })
        #expect(await eventually { recording.isTerminated(7) })
        // The next recording can start.
        #expect(Self.accepted(try await fixture.open(streamID: 8)))
    }

    @Test func hubCloseEndsTheStream() async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1, 2, 3]), isLast: false)] }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        _ = try await fixture.chunk()
        // A close for another stream is ignored (messages are handled in order, so once a later request is answered the
        // close was seen).
        try await fixture.client.event(protocol: "dataSend", topic: "close", body: HDSDictionary([("streamId", .int(99)), ("reason", .int(0))]))
        _ = try await fixture.client.request(protocol: "dataSend", topic: "pause", body: HDSDictionary())
        #expect(recording.endings.isEmpty && harness.controller.activeRecordingStreams == 1)
        try await fixture.client.event(protocol: "dataSend", topic: "close", body: HDSDictionary([("streamId", .int(1)), ("reason", .int(3))]))
        #expect(await eventually { recording.endings == [.close(1, .cancelled)] })
        #expect(await eventually { recording.isTerminated(1) })
        #expect(await eventually { harness.controller.activeRecordingStreams == 0 })
        // Packets the delegate still yields are not sent.
        recording.continuation(for: 1)?.yield(RecordingPacket(data: Data([9]), isLast: false))
        #expect(Self.accepted(try await fixture.open(streamID: 2)))
        let next = try await fixture.chunk()
        #expect(next.streamID == 2 && next.sequence == 1)
    }

    @Test func missingAcknowledgementClosesAsCancelled() async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1]), isLast: false), RecordingPacket(data: Data([2]), isLast: true)] }
        let timings = CameraControllerTimings(recordingAcknowledgeTimeout: .milliseconds(200))
        let harness = await CameraHarness.make(timings: timings, recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        _ = try await fixture.chunk()
        #expect(try await fixture.chunk().endOfStream == true)
        #expect(try await fixture.closeReason() == HDSProtocolReason.cancelled.rawValue)
        #expect(await eventually { recording.endings == [.close(1, .cancelled)] })
        #expect(harness.controller.activeRecordingStreams == 0)
    }

    @Test func streamThatEndsWithoutLastPacketIsCancelled() async throws {
        let recording = FakeRecordingDelegate()
        let timings = CameraControllerTimings(recordingAcknowledgeTimeout: .milliseconds(200))
        let harness = await CameraHarness.make(timings: timings, recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        let continuation = try #require(await eventually { recording.continuation(for: 1) != nil } ? recording.continuation(for: 1) : nil)
        continuation.yield(RecordingPacket(data: Data([1]), isLast: false))
        continuation.finish()
        _ = try await fixture.chunk()
        #expect(try await fixture.closeReason() == HDSProtocolReason.cancelled.rawValue)
        #expect(await eventually { recording.endings == [.close(1, .cancelled)] })
    }

    /// A delegate that does not end its stream at the cap: the controller's backstop sends the first packet after the cap
    /// plus one fragment (the selected fragment length) plus the grace as the last one; until then packets go out as the
    /// delegate marks them (its last fragment can end up to one fragment after the cap).
    @Test func recordingTheDelegateDoesNotEndIsCappedByTheBackstop() async throws {
        let recording = FakeRecordingDelegate()
        let timings = CameraControllerTimings(recordingAcknowledgeTimeout: .seconds(5), maximumRecordingDuration: .milliseconds(200),
                                              recordingCapGrace: .seconds(1))
        let harness = await CameraHarness.make(timings: timings, recording: recording)
        var selection = CameraRequests.recordingSelection
        selection.fragmentLengthMs = 1000
        let fixture = try await Fixture.make(harness, selection: selection)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        let continuation = try #require(await eventually { recording.continuation(for: 1) != nil } ? recording.continuation(for: 1) : nil)
        let opened = ContinuousClock.now
        continuation.yield(RecordingPacket(data: Data([1]), isLast: false))
        #expect(try await fixture.chunk().endOfStream == false)
        // Past the cap and one fragment (1.2 s), within the grace (backstop at 2.2 s): not forced last.
        try await Task.sleep(until: opened + .milliseconds(1400))
        continuation.yield(RecordingPacket(data: Data([2]), isLast: false))
        #expect(try await fixture.chunk().endOfStream == false)
        // Past the backstop: the next packet is the last one.
        try await Task.sleep(until: opened + .milliseconds(2600))
        continuation.yield(RecordingPacket(data: Data([3]), isLast: false))
        let capped = try await fixture.chunk()
        #expect(capped.sequence == 3 && capped.endOfStream == true)
        #expect(await eventually { recording.isTerminated(1) })
        try await fixture.acknowledge()
        #expect(await eventually { recording.endings == [.acknowledge(1)] })
    }

    /// Review finding (W4 round 3): the controller's cap raced the delegate's own. The delegate (BridgeEngine's producer)
    /// ends a capped stream at a fragment boundary, and one keyframe can close two fragments there: the first not last,
    /// the second last. The controller's timer, armed before the delegate's clock starts, marked the first one last
    /// instead and never sent the second (the newest seconds of the clip). Packets the delegate sends after the cap go
    /// out as it marks them.
    @Test func packetsTheDelegateSendsAfterTheCapGoOutAsItMarksThem() async throws {
        let recording = FakeRecordingDelegate()
        let timings = CameraControllerTimings(recordingAcknowledgeTimeout: .seconds(2), maximumRecordingDuration: .milliseconds(300))
        let harness = await CameraHarness.make(timings: timings, recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        let continuation = try #require(await eventually { recording.continuation(for: 1) != nil } ? recording.continuation(for: 1) : nil)
        continuation.yield(RecordingPacket(data: Data([1]), isLast: false))
        #expect(try await fixture.chunk().endOfStream == false)
        // Past the cap, one keyframe closes two fragments: both go out, the second marked last.
        try await Task.sleep(for: .milliseconds(500))
        continuation.yield(RecordingPacket(data: Data([2]), isLast: false))
        continuation.yield(RecordingPacket(data: Data([3]), isLast: true))
        let first = try await fixture.chunk()
        #expect(first.sequence == 2 && first.data == Data([2]) && first.endOfStream == false)
        let second = try await fixture.chunk()
        #expect(second.sequence == 3 && second.data == Data([3]) && second.endOfStream == true)
        #expect(await eventually { recording.isTerminated(1) })
        try await fixture.acknowledge()
        #expect(await eventually { recording.endings == [.acknowledge(1)] })
    }

    @Test func cameraTurnedOffClosesTheRecording() async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1]), isLast: false)] }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        _ = try await fixture.chunk()
        try await harness.characteristic(.cameraOperatingMode, .homeKitCameraActive).write(.uint(0), as: fixture.admin)
        #expect(try await fixture.closeReason() == HDSProtocolReason.notAllowed.rawValue)
        #expect(await eventually { recording.endings == [.close(1, .notAllowed)] })
        #expect(await eventually { recording.isTerminated(1) })
    }

    @Test func recordingTurnedOffClosesTheRecording() async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1]), isLast: false)] }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        _ = try await fixture.chunk()
        try await harness.characteristic(.cameraRecordingManagement, .active).write(.uint(0), as: fixture.admin)
        #expect(try await fixture.closeReason() == HDSProtocolReason.notAllowed.rawValue)
        #expect(await eventually { recording.endings == [.close(1, .notAllowed)] })
    }

    @Test func delegateFailuresCloseWithAReason() async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.streamError = FakeDelegateError() }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open(streamID: 1)))
        #expect(try await fixture.closeReason() == HDSProtocolReason.unexpectedFailure.rawValue)
        #expect(await eventually { recording.endings == [.close(1, .unexpectedFailure)] })

        // A protocol reason thrown mid-stream is passed to the hub. (The failed stream 1 left its continuation behind:
        // drop it, so the one waited for below is the new stream's.)
        recording.state.withLock {
            $0.streamError = nil
            $0.continuations[1] = nil
        }
        #expect(await eventually { harness.controller.activeRecordingStreams == 0 })
        #expect(Self.accepted(try await fixture.open(streamID: 1)))
        let continuation = try #require(await eventually { recording.continuation(for: 1) != nil } ? recording.continuation(for: 1) : nil)
        continuation.finish(throwing: HDSProtocolReason.badData)
        #expect(try await fixture.closeReason() == HDSProtocolReason.badData.rawValue)
        #expect(await eventually { recording.endings.last == .close(1, .badData) })
    }

    @Test func droppedConnectionClosesTheStream() async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1]), isLast: false)] }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        _ = try await fixture.chunk()
        await fixture.client.close()
        #expect(await eventually { recording.endings == [.close(1, nil)] })
        #expect(await eventually { recording.isTerminated(1) })
        #expect(await eventually { harness.controller.activeRecordingStreams == 0 })
    }

    @Test func closingTheHAPSessionClosesItsDataStream() async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1]), isLast: false)] }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        _ = try await fixture.chunk()
        fixture.admin.close()
        #expect(await fixture.client.isDropped())
        #expect(await eventually { recording.endings == [.close(1, nil)] })
    }

    @Test func streamThatDoesNotStopLosesItsConnection() async throws {
        let recording = FakeRecordingDelegate()
        let gate = Gate()
        recording.state.withLock { $0.streamGate = gate }
        let timings = CameraControllerTimings(recordingStopTimeout: .milliseconds(300))
        let harness = await CameraHarness.make(timings: timings, recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open()))
        #expect(await eventually { recording.calls.contains(.stream(1)) })
        // The hub closes while the delegate is still busy in recordingStream(streamID:).
        try await fixture.client.event(protocol: "dataSend", topic: "close", body: HDSDictionary([("streamId", .int(1)), ("reason", .int(0))]))
        #expect(await eventually { recording.endings == [.close(1, .normal)] })
        #expect(harness.controller.activeRecordingStreams == 0)
        #expect(await harness.dataStreamServer.connectionCount == 1)
        // Still busy after the stop timeout: the HDS connection is closed.
        #expect(await fixture.client.isDropped(within: .seconds(5)))
        #expect(await eventually { await harness.dataStreamServer.connectionCount == 0 })
        await gate.open()
        #expect(await eventually { recording.isTerminated(1) })
    }

    @Test func unknownRequestsAreAnswered() async throws {
        let harness = await CameraHarness.make()
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        let response = try await fixture.client.request(protocol: "dataSend", topic: "pause", body: HDSDictionary())
        #expect(Self.rejection(response) == HDSProtocolReason.unsupported.rawValue)
    }

    // MARK: - Our-side close over an unhealthy connection, close before start, one close handler per connection

    @Test func closeDoesNotWaitForAStalledConnection() async throws {
        let recording = FakeRecordingDelegate()
        let transport = FakeNetworkTransport()
        let timings = CameraControllerTimings(recordingStopTimeout: .milliseconds(300))
        let harness = await CameraHarness.make(timings: timings, recording: recording, dataStreamTransport: transport)
        let fixture = try await Fixture.make(harness, fakeTransport: transport)
        defer { await fixture.stop() }
        let accessoryEnd = try #require(fixture.accessoryEnd)
        #expect(Self.accepted(try await fixture.open()))
        let continuation = try #require(await eventually { recording.continuation(for: 1) != nil } ? recording.continuation(for: 1) : nil)
        continuation.yield(RecordingPacket(data: Data([1]), isLast: false))
        _ = try await fixture.chunk()

        // The hub stops reading (Wi-Fi gone, no FIN): the next data event hangs in the transport.
        accessoryEnd.stallSends()
        continuation.yield(RecordingPacket(data: Data(repeating: 2, count: 1_000), isLast: false))
        #expect(await eventually { accessoryEnd.stalledSendCount == 1 })

        // Turning the camera off ends the recording at once: slot freed, delegate told, producer released; the stop
        // watchdog then closes the stuck HDS connection.
        try await harness.characteristic(.cameraOperatingMode, .homeKitCameraActive).write(.uint(0), as: fixture.admin)
        #expect(await eventually(timeout: .seconds(2)) { recording.endings == [.close(1, .notAllowed)] })
        #expect(harness.controller.activeRecordingStreams == 0)
        #expect(await eventually { recording.isTerminated(1) })
        #expect(await eventually(timeout: .seconds(3)) { await harness.dataStreamServer.connectionCount == 0 })

        // The hub comes back on a new connection: the next recording is accepted.
        try await harness.characteristic(.cameraOperatingMode, .homeKitCameraActive).write(.uint(1), as: fixture.admin)
        let next = try await Fixture.make(harness, select: false, activate: false, fakeTransport: transport, admin: fixture.admin)
        defer { await next.client.close() }
        #expect(Self.accepted(try await next.open(streamID: 2)))
    }

    /// Review finding (W4 round 4): a fragment that cannot be sent over HDS (the hub reset the connection) ends the
    /// recording — the delegate is told, the slot freed, the connection closed; those branches never ran.
    @Test func aFragmentThatCannotBeSentEndsTheRecording() async throws {
        let recording = FakeRecordingDelegate()
        let transport = FakeNetworkTransport()
        let harness = await CameraHarness.make(recording: recording, dataStreamTransport: transport)
        let fixture = try await Fixture.make(harness, fakeTransport: transport)
        defer { await fixture.stop() }
        let accessoryEnd = try #require(fixture.accessoryEnd)
        #expect(Self.accepted(try await fixture.open()))
        let continuation = try #require(await eventually { recording.continuation(for: 1) != nil } ? recording.continuation(for: 1) : nil)
        continuation.yield(RecordingPacket(data: Data([1]), isLast: false))
        _ = try await fixture.chunk()
        accessoryEnd.failSends()
        continuation.yield(RecordingPacket(data: Data(repeating: 2, count: 1_000), isLast: false))
        #expect(await eventually(timeout: .seconds(3)) { recording.endings.count == 1 }, "\(recording.endings)")
        let ending = recording.endings.first
        #expect(ending == .close(1, nil) || ending == .close(1, .unexpectedFailure), "\(String(describing: ending))")
        #expect(await eventually { harness.controller.activeRecordingStreams == 0 })
        #expect(await eventually { recording.isTerminated(1) })
        #expect(await eventually(timeout: .seconds(3)) { await harness.dataStreamServer.connectionCount == 0 }, "the failed connection is closed")
    }

    /// Review finding (W4 round 4): a data stream listener that cannot listen answers SetupDataStreamTransport with
    /// -70402 (the hub tries again later); the mapping never ran. The next setup listens again.
    @Test func aDataStreamThatCannotListenAnswersServiceCommunicationFailure() async throws {
        let transport = FakeNetworkTransport()
        let harness = await CameraHarness.make(dataStreamTransport: transport)
        defer { await harness.stop() }
        let admin = FakeHAPSession(sharedSecret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let setup = try harness.characteristic(.dataStreamTransportManagement, .setupDataStreamTransport)
        let request = CameraTLV.SetupDataStreamTransportRequest(controllerKeySalt: Data((0..<32).map { _ in UInt8.random(in: 0...255) })).encoded
        transport.failNextListens([.failed("no listener")])
        #expect(await hapStatus { _ = try await setup.write(.data(request), as: admin) } == .serviceCommunicationFailure)
        let written = try await setup.write(.data(request), as: admin)
        let response = try CameraTLV.SetupDataStreamTransportResponse(parsing: try #require(written?.dataValue))
        #expect(response.status == .success && response.port != 0)
    }

    @Test func unsentCloseEventClosesTheConnection() async throws {
        let recording = FakeRecordingDelegate()
        let transport = FakeNetworkTransport()
        let timings = CameraControllerTimings(recordingStopTimeout: .seconds(1))
        let harness = await CameraHarness.make(timings: timings, recording: recording, dataStreamTransport: transport)
        let fixture = try await Fixture.make(harness, fakeTransport: transport)
        defer { await fixture.stop() }
        let accessoryEnd = try #require(fixture.accessoryEnd)
        #expect(Self.accepted(try await fixture.open()))
        let continuation = try #require(await eventually { recording.continuation(for: 1) != nil } ? recording.continuation(for: 1) : nil)
        continuation.yield(RecordingPacket(data: Data([1]), isLast: false))
        _ = try await fixture.chunk()

        // Nothing in flight, but the hub stopped reading: the close event itself cannot go out.
        accessoryEnd.stallSends()
        try await harness.characteristic(.cameraRecordingManagement, .active).write(.uint(0), as: fixture.admin)
        #expect(await eventually(timeout: .seconds(2)) { recording.endings == [.close(1, .notAllowed)] })
        #expect(harness.controller.activeRecordingStreams == 0)
        #expect(await eventually { accessoryEnd.stalledSendCount == 1 })
        #expect(await eventually(timeout: .seconds(3)) { await harness.dataStreamServer.connectionCount == 0 })
        #expect(await eventually { accessoryEnd.isClosed })
    }

    @Test func streamClosedBeforeItStartsRefusesTheOpen() async throws {
        let recording = FakeRecordingDelegate()
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        // Get hold of the accessory's end of the HDS connection through a test protocol.
        let box = ConnectionBox()
        await harness.dataStreamServer.setHandler(protocol: "test") { _, connection in box.connection.withLock { $0 = connection } }
        try await fixture.client.event(protocol: "test", topic: "grab", body: HDSDictionary())
        let connection = try #require(await eventually { box.connection.withLock { $0 } != nil } ? box.connection.withLock { $0 } : nil)

        // The camera is turned off between the open being admitted and the stream starting.
        let counter = Counter()
        let stream = RecordingStream(streamID: 1, connection: connection, delegate: recording, timings: .standard) { _ in counter.increment() }
        await stream.close(reason: .notAllowed, because: "HomeKit camera was turned off")
        let open = HDSMessage(kind: .request(id: 77), protocolName: "dataSend", topic: "open",
                              body: HDSDictionary([("target", .string("controller")), ("type", .string("ipcamera.recording")), ("streamId", .int(1))]))
        await stream.start(open: open)

        // The hub gets an answer to its open (refused, notAllowed) and no close event for a stream it never had.
        let response = try await fixture.client.receiveMessage()
        #expect(response.kind == .response(id: 77, status: .protocolSpecificError))
        #expect(response.body["status"] == .int(HDSProtocolReason.notAllowed.rawValue))
        #expect(counter.value == 1)
        #expect(!recording.calls.contains(.stream(1)) && recording.endings.isEmpty)
        let next = try await fixture.client.request(protocol: "dataSend", topic: "pause", body: HDSDictionary())
        #expect(next.topic == "pause")
    }

    @Test func oneCloseHandlerPerDataStreamConnection() async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1]), isLast: true)] }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        for streamID in Int64(1)...5 {
            #expect(Self.accepted(try await fixture.open(streamID: streamID)))
            #expect(try await fixture.chunk().endOfStream == true)
            try await fixture.acknowledge(streamID: streamID)
            #expect(await eventually { harness.controller.activeRecordingStreams == 0 })
        }
        // The slot is freed as the ack arrives; the delegate hears about the end right after.
        #expect(await eventually { recording.endings.count == 5 })
        #expect(harness.controller.watchedConnectionCount == 1)
        // That one handler still ends a recording that runs when the connection drops.
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1]), isLast: false)] }
        #expect(Self.accepted(try await fixture.open(streamID: 6)))
        _ = try await fixture.chunk()
        await fixture.client.close()
        #expect(await eventually { recording.endings.last == .close(6, nil) })
        #expect(await eventually { harness.controller.watchedConnectionCount == 0 })
    }

    /// The hub's `ack` / `close` and its next `open` arriving together (one TCP segment, e.g. the continuation of a long
    /// event after the 3-minute cap): the end frees the slot before the open is handled, so the open is never refused as
    /// busy (HAP-NodeJS clears the stream synchronously in its handler).
    @Test(arguments: ["ack", "close"]) func openRightAfterTheHubEndedTheStreamIsAccepted(_ topic: String) async throws {
        let recording = FakeRecordingDelegate()
        recording.state.withLock { $0.script = [RecordingPacket(data: Data([1]), isLast: true)] }
        let harness = await CameraHarness.make(recording: recording)
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        #expect(Self.accepted(try await fixture.open(streamID: 1)))
        let rounds: Int64 = 20
        for streamID in Int64(1)...rounds {
            #expect(try await fixture.chunk().endOfStream == true)
            let end: HDSDictionary = topic == "ack"
                ? HDSDictionary([("streamId", .int(streamID)), ("endOfStream", .bool(true))])
                : HDSDictionary([("streamId", .int(streamID)), ("reason", .int(HDSProtocolReason.normal.rawValue))])
            let open = await fixture.client.nextRequest(protocol: "dataSend", topic: "open", body: Fixture.openBody(streamID: streamID + 1))
            try await fixture.client.sendTogether([HDSMessage(kind: .event, protocolName: "dataSend", topic: topic, body: end), open])
            let response = try await fixture.client.receiveMessage()
            #expect(Self.accepted(response),
                    "stream \(streamID + 1) was refused with reason \(Self.rejection(response) ?? -1) right after the hub's \(topic) of stream \(streamID)")
            guard Self.accepted(response) else { return }
        }
        #expect(await eventually { recording.endings.count == Int(rounds) })
        #expect(recording.endings.first == (topic == "ack" ? .acknowledge(1) : .close(1, .normal)))
    }

    // MARK: - A new hub connection takes the recording slot (hardening plan WS-C 3)

    /// Audit A4: a hub that reconnects (Wi-Fi drop, sleep) while its old HDS connection is not known to be dead yet was
    /// refused `busy` for minutes, because the old connection's stream held the slot. A different connection preempts it:
    /// the old stream is closed `.cancelled` (the delegate hears it, the old hub gets the close event) and the new one is
    /// accepted. The same connection opening a second stream is still busy (`openIsValidated`).
    @Test func aNewHDSConnectionPreemptsTheStreamOfAnOldOne() async throws {
        let harness = await CameraHarness.make()
        let old = try await Fixture.make(harness)
        defer { await old.stop() }
        #expect(Self.accepted(try await old.open(streamID: 1)))
        #expect(await eventually { harness.controller.activeRecordingStreams == 1 })
        #expect(await eventually { harness.recording.calls.contains(.stream(1)) })

        let new = try await Fixture.make(harness, select: false, activate: false)
        defer { await new.stop() }
        #expect(Self.accepted(try await new.open(streamID: 2)), "not refused as busy")
        #expect(await eventually { harness.recording.calls.contains(.close(1, .cancelled)) })
        #expect(await eventually { harness.recording.calls.contains(.stream(2)) })
        #expect(try await old.closeReason() == HDSProtocolReason.cancelled.rawValue)
        #expect(await eventually { harness.recording.isTerminated(1) })
        #expect(harness.controller.activeRecordingStreams == 1)
        // The new connection's stream is the live one: it is busy for a third (same connection) open.
        #expect(Self.rejection(try await new.open(streamID: 3)) == HDSProtocolReason.busy.rawValue)
    }

    /// Audit B5: the hub reuses stream ID 1 on its new connection while the old stream's end is still being delivered to
    /// the delegate in its own task. The delegate hears the old end first, so it cannot cancel the new producer.
    @Test func aReusedStreamIDStartsOnlyAfterTheOldStreamsEndReachedTheDelegate() async throws {
        let recording = FakeRecordingDelegate()
        let endGate = Gate()
        let harness = await CameraHarness.make(recording: recording)
        let old = try await Fixture.make(harness)
        defer {
            await endGate.open()
            await old.stop()
        }
        #expect(Self.accepted(try await old.open(streamID: 1)))
        #expect(await eventually { recording.calls.contains(.stream(1)) })
        recording.state.withLock { $0.endGate = endGate }

        let new = try await Fixture.make(harness, select: false, activate: false)
        defer { await new.stop() }
        #expect(Self.accepted(try await new.open(streamID: 1)))
        #expect(await eventually { recording.calls.contains(.close(1, .cancelled)) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(recording.calls.filter { $0 == .stream(1) }.count == 1, "the new stream 1 waits for the old one's end to be delivered")
        await endGate.open()
        #expect(await eventually { recording.calls.filter { $0 == .stream(1) }.count == 2 })
        let calls = recording.calls
        let closeIndex = try #require(calls.firstIndex(of: .close(1, .cancelled)))
        let secondStream = try #require(calls.indices.last { calls[$0] == .stream(1) })
        #expect(closeIndex < secondStream)
    }

    /// Unpairing turns recording off (HAP-NodeJS `handleFactoryReset`): the running recording is closed with
    /// `notAllowed`, live streams end and new opens are refused.
    @Test func unpairingClosesTheRecordingAndEndsLiveStreams() async throws {
        let harness = await CameraHarness.make()
        let fixture = try await Fixture.make(harness)
        defer { await fixture.stop() }
        let id = UUID()
        let stream = harness.streamServices[0]
        try await stream.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: fixture.admin)
        try await stream.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: fixture.admin)
        #expect(harness.controller.activeLiveStreams == 1)
        #expect(Self.accepted(try await fixture.open()))
        #expect(await eventually { harness.recording.calls.contains(.stream(1)) })

        try await harness.server.resetPairings()

        #expect(try await fixture.closeReason() == HDSProtocolReason.notAllowed.rawValue)
        #expect(await eventually { harness.recording.endings == [.close(1, .notAllowed)] })
        #expect(await eventually { harness.streaming.stopIDs == [id] })
        #expect(await eventually { harness.controller.activeRecordingStreams == 0 && harness.controller.activeLiveStreams == 0 })
        #expect(try await harness.streamServices[0].characteristic(.selectedRTPStreamConfiguration).readData(as: fixture.admin)
            == RTPStreamManagement.suspendedConfiguration)
        #expect(Self.rejection(try await fixture.open(streamID: 2)) == HDSProtocolReason.notAllowed.rawValue)
    }
}

final class ConnectionBox: Sendable {
    let connection = Mutex<DataStreamConnection?>(nil)
}

final class Counter: Sendable {
    private let count = Mutex(0)

    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

#endif
