#if os(macOS)
import BridgeSupport
import Foundation
import HAPCore
import Synchronization
import TestSupport
import Testing
@testable import HAP
@testable import HAPCamera

/// Plan W2-1 items 4, 5, 6, 8 and 9: recording management, operating mode and its persistence, snapshot policy, data
/// stream transport setup, motion sensor, doorbell, microphone and speaker.
@Suite(.timeLimit(.minutes(1))) struct OperatingModeTests {
    static let defaultState = CameraOperatingState(homeKitCameraActive: true, eventSnapshotsActive: true, periodicSnapshotsActive: true,
                                                   recordingActive: false, recordingAudioActive: false)

    @Test func defaultsAndOptionalControls() async throws {
        let plain = await CameraHarness.make()
        defer { await plain.stop() }
        #expect(plain.controller.operatingState == Self.defaultState)
        let mode = try #require(plain.service(.cameraOperatingMode))
        #expect(mode.existingCharacteristic(.homeKitCameraActive)?.value == .uint(1))
        #expect(mode.existingCharacteristic(.eventSnapshotsActive)?.value == .uint(1))
        #expect(mode.existingCharacteristic(.periodicSnapshotsActive)?.value == .uint(1))
        #expect(mode.existingCharacteristic(.nightVision) == nil && mode.existingCharacteristic(.cameraOperatingModeIndicator) == nil)
        // Install reports the initial state to the recording delegate.
        #expect(plain.recording.calls == [.configuration(nil), .active(false), .audioActive(false)])

        let full = await CameraHarness.make(nightVision: true, indicator: true)
        defer { await full.stop() }
        var expected = Self.defaultState
        expected.nightVision = true
        expected.indicatorEnabled = true
        #expect(full.controller.operatingState == expected)
        let fullMode = try #require(full.service(.cameraOperatingMode))
        let nightVision = try #require(fullMode.existingCharacteristic(.nightVision))
        let indicator = try #require(fullMode.existingCharacteristic(.cameraOperatingModeIndicator))
        let changes = full.controller.operatingStateChanges
        let session = FakeHAPSession(isAdmin: false)
        try await nightVision.write(.bool(false), as: session)
        try await indicator.write(.bool(false), as: session)
        expected.nightVision = false
        expected.indicatorEnabled = false
        #expect(full.controller.operatingState == expected)
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next()?.nightVision == false)
        #expect(await iterator.next() == expected)
    }

    @Test func homeKitCameraActiveOffDisablesEverything() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let admin = FakeHAPSession()
        let hkca = try harness.characteristic(.cameraOperatingMode, .homeKitCameraActive)
        #expect(await hapStatus { try await hkca.write(.uint(0), as: FakeHAPSession(isAdmin: false)) } == .insufficientPrivileges)

        // A running live stream.
        let stream = harness.streamServices[0]
        let id = UUID()
        try await stream.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints(id: id).encoded), as: admin)
        try await stream.characteristic(.selectedRTPStreamConfiguration).write(.data(CameraRequests.selected(id, .start)), as: admin)

        let changes = harness.controller.operatingStateChanges
        try await hkca.write(.uint(0), as: admin)
        #expect(harness.controller.operatingState.homeKitCameraActive == false)
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next()?.homeKitCameraActive == false)
        #expect(await eventually { harness.streaming.stopIDs == [id] })
        #expect(harness.controller.motionService?.existingCharacteristic(.statusActive)?.value == .bool(false))
        #expect(await hapStatus { try await stream.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: admin) }
            == .notAllowedInCurrentState)
        #expect(try await stream.characteristic(.setupEndpoints).readData(as: admin).hexString == "020102")
        let snapshot = await hapStatus { _ = try await Self.snapshot(harness, reason: 1) }
        #expect(snapshot == .notAllowedInCurrentState)

        try await hkca.write(.uint(1), as: admin)
        #expect(harness.controller.motionService?.existingCharacteristic(.statusActive)?.value == .bool(true))
        try await stream.characteristic(.setupEndpoints).write(.data(CameraRequests.setupEndpoints().encoded), as: admin)
        #expect(harness.streaming.prepares.count == 2)
    }

    @Test func snapshotPolicy() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let admin = FakeHAPSession()
        #expect(try await Self.snapshot(harness, reason: nil) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        #expect(harness.streaming.snapshots.last?.width == 640 && harness.streaming.snapshots.last?.height == 360)
        #expect(harness.streaming.snapshots.last?.reason == nil)
        _ = try await Self.snapshot(harness, reason: 0)
        #expect(harness.streaming.snapshots.last?.reason == .periodic)

        let event = try harness.characteristic(.cameraOperatingMode, .eventSnapshotsActive)
        let periodic = try harness.characteristic(.cameraOperatingMode, .periodicSnapshotsActive)
        try await event.write(.uint(0), as: admin)
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: 1) } == .notAllowedInCurrentState)
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: nil) } == .insufficientPrivileges)
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: 0) } == nil)
        try await event.write(.uint(1), as: admin)
        try await periodic.write(.uint(0), as: admin)
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: 0) } == .notAllowedInCurrentState)
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: nil) } == .insufficientPrivileges)
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: 1) } == nil)
        #expect(harness.controller.operatingState.periodicSnapshotsActive == false)
        try await periodic.write(.uint(1), as: admin)

        // Every stream service inactive → no snapshots.
        for service in harness.streamServices { try await service.characteristic(.active).write(.uint(0), as: admin) }
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: 1) } == .notAllowedInCurrentState)
        try await harness.streamServices[0].characteristic(.active).write(.uint(1), as: admin)

        // Delegate failures.
        harness.streaming.state.withLock { $0.snapshotError = FakeDelegateError() }
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: 1) } == .serviceCommunicationFailure)
        harness.streaming.state.withLock {
            $0.snapshotError = nil
            $0.snapshotData = Data()
        }
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: 1) } == .serviceCommunicationFailure)
    }

    @Test func recordingActiveAndAudioReachTheDelegate() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let admin = FakeHAPSession()
        let active = try harness.characteristic(.cameraRecordingManagement, .active)
        let audio = try harness.characteristic(.cameraRecordingManagement, .recordingAudioActive)
        #expect(await hapStatus { try await active.write(.uint(1), as: FakeHAPSession(isAdmin: false)) } == .insufficientPrivileges)
        try await active.write(.uint(1), as: admin)
        try await active.write(.uint(1), as: admin)
        try await audio.write(.uint(1), as: admin)
        #expect(harness.recording.calls.dropFirst(3) == [.active(true), .audioActive(true)])
        #expect(harness.controller.operatingState.recordingActive && harness.controller.operatingState.recordingAudioActive)
        try await active.write(.uint(0), as: admin)
        #expect(harness.recording.calls.last == .active(false))
    }

    @Test func selectedRecordingConfiguration() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let admin = FakeHAPSession()
        let selected = try harness.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration)
        #expect(await hapStatus { _ = try await selected.read(as: admin) } == .serviceCommunicationFailure)

        let goldens = try CameraTLVGoldens.load()
        let encoded = try hex(goldens.selectedRecordingConfiguration[0].encoded)
        let parsed = try goldens.selectedRecordingConfiguration[0].configuration.cameraRecordingConfiguration()
        #expect(await hapStatus { try await selected.write(.data(encoded), as: FakeHAPSession(isAdmin: false)) } == .insufficientPrivileges)
        #expect(await hapStatus { try await selected.write(.data(Data([1, 2, 3])), as: admin) } == .invalidValue)
        try await selected.write(.data(encoded), as: admin)
        try await selected.write(.data(encoded), as: admin)
        #expect(harness.recording.calls.dropFirst(3) == [.configuration(parsed)])
        #expect(try await selected.readData(as: admin) == encoded)

        let doorbellSelection = try hex(goldens.selectedRecordingConfiguration[1].encoded)
        try await selected.write(.data(doorbellSelection), as: admin)
        #expect(harness.recording.calls.last == .configuration(try goldens.selectedRecordingConfiguration[1].configuration.cameraRecordingConfiguration()))
    }

    @Test func stateIsPersistedAndRestored() async throws {
        let store = try CameraHarness.pairedStore()
        let first = await CameraHarness.make(nightVision: true, store: store)
        let admin = FakeHAPSession()
        let selection = CameraTLV.selectedRecordingConfiguration(CameraRequests.recordingSelection)
        try await first.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration).write(.data(selection), as: admin)
        try await first.characteristic(.cameraRecordingManagement, .active).write(.uint(1), as: admin)
        try await first.characteristic(.cameraRecordingManagement, .recordingAudioActive).write(.uint(1), as: admin)
        try await first.characteristic(.cameraOperatingMode, .eventSnapshotsActive).write(.uint(0), as: admin)
        try await first.characteristic(.cameraOperatingMode, .nightVision).write(.bool(false), as: admin)
        try await first.streamServices[1].characteristic(.active).write(.uint(0), as: admin)
        await first.stop()

        let second = await CameraHarness.make(nightVision: true, store: store)
        defer { await second.stop() }
        let state = second.controller.operatingState
        #expect(state == CameraOperatingState(homeKitCameraActive: true, eventSnapshotsActive: false, periodicSnapshotsActive: true,
                                              recordingActive: true, recordingAudioActive: true, nightVision: false, indicatorEnabled: nil))
        #expect(second.recording.calls == [.configuration(CameraRequests.recordingSelection), .active(true), .audioActive(true)])
        #expect(try await second.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration).readData(as: admin) == selection)
        #expect(try second.characteristic(.cameraRecordingManagement, .active).value == .uint(1))
        #expect(try second.characteristic(.cameraOperatingMode, .eventSnapshotsActive).value == .uint(0))
        #expect(second.streamServices[1].existingCharacteristic(.active)?.value == .uint(0))
        #expect(second.streamServices[0].existingCharacteristic(.active)?.value == .uint(1))

        // Changing the advertised recording options drops the hub's selection (and only that).
        let changed = CameraRecordingOptions(resolutions: [VideoResolution(1920, 1080, 30)])
        await second.stop()
        let third = await CameraHarness.make(recordingOptions: changed, nightVision: true, store: store)
        defer { await third.stop() }
        #expect(third.recording.calls == [.configuration(nil), .active(true), .audioActive(true)])
        #expect(await hapStatus { _ = try await third.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration).read(as: admin) }
            == .serviceCommunicationFailure)
        let persisted = try #require(await third.server.extra(forKey: CameraController.persistenceKey))
        #expect(try JSONDecoder().decode(PersistedCameraState.self, from: persisted).selectedConfiguration == nil)
    }

    /// What one Home chose: a recording selection, recording with audio, the camera off, no snapshots, the second stream
    /// management off and night vision off.
    static func makeNonDefault(_ harness: CameraHarness, as admin: FakeHAPSession) async throws {
        let selection = CameraTLV.selectedRecordingConfiguration(CameraRequests.recordingSelection)
        try await harness.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration).write(.data(selection), as: admin)
        try await harness.characteristic(.cameraRecordingManagement, .active).write(.uint(1), as: admin)
        try await harness.characteristic(.cameraRecordingManagement, .recordingAudioActive).write(.uint(1), as: admin)
        for type in [CharacteristicType.homeKitCameraActive, .eventSnapshotsActive, .periodicSnapshotsActive] {
            try await harness.characteristic(.cameraOperatingMode, type).write(.uint(0), as: admin)
        }
        try await harness.characteristic(.cameraOperatingMode, .nightVision).write(.bool(false), as: admin)
        try await harness.streamServices[1].characteristic(.active).write(.uint(0), as: admin)
        #expect(harness.controller.operatingState == CameraOperatingState(homeKitCameraActive: false, eventSnapshotsActive: false,
                                                                          periodicSnapshotsActive: false, recordingActive: true,
                                                                          recordingAudioActive: true, nightVision: false))
    }

    /// The factory state of a camera with night vision control whose night vision was turned off (HAP-NodeJS keeps it).
    static let factoryStateWithNightVisionOff = CameraOperatingState(homeKitCameraActive: true, eventSnapshotsActive: true,
                                                                     periodicSnapshotsActive: true, recordingActive: false,
                                                                     recordingAudioActive: false, nightVision: false)

    /// HAP-NodeJS `handleAccessoryUnpairedForControllers` → `CameraController.handleFactoryReset`: once the accessory has
    /// no pairing left, everything a hub chose goes back to its default and the recording delegate is told.
    @Test func unpairingFactoryResetsTheCamera() async throws {
        let store = try CameraHarness.pairedStore()
        let harness = await CameraHarness.make(nightVision: true, store: store)
        let admin = FakeHAPSession()
        try await Self.makeNonDefault(harness, as: admin)
        for service in [ServiceType.microphone, .speaker] {
            try await harness.characteristic(service, .mute).write(.bool(true), as: admin)
            try await harness.characteristic(service, .volume).write(.uint(30), as: admin)
        }
        let motion = try #require(harness.controller.motionService)
        #expect(motion.existingCharacteristic(.statusActive)?.value == .bool(false))
        #expect(await hapStatus { _ = try await Self.snapshot(harness, reason: SnapshotReason.periodic.rawValue) } == .notAllowedInCurrentState)
        let changes = harness.controller.operatingStateChanges
        let callsBefore = harness.recording.calls.count

        try await harness.server.resetPairings()

        #expect(await eventually { harness.controller.operatingState == Self.factoryStateWithNightVisionOff })
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() == Self.factoryStateWithNightVisionOff)
        #expect(Array(harness.recording.calls.dropFirst(callsBefore)) == [.active(false), .configuration(nil), .audioActive(false)])
        let selected = try harness.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration)
        #expect(await hapStatus { _ = try await selected.read(as: admin) } == .serviceCommunicationFailure)
        #expect(selected.value == .data(Data()))
        #expect(try harness.characteristic(.cameraRecordingManagement, .active).value == .uint(0))
        #expect(try harness.characteristic(.cameraRecordingManagement, .recordingAudioActive).value == .uint(0))
        for type in [CharacteristicType.homeKitCameraActive, .eventSnapshotsActive, .periodicSnapshotsActive] {
            #expect(try harness.characteristic(.cameraOperatingMode, type).value == .uint(1), "\(type.name)")
        }
        #expect(try harness.characteristic(.cameraOperatingMode, .nightVision).value == .bool(false))
        #expect(harness.streamServices.allSatisfy { $0.existingCharacteristic(.active)?.value == .uint(1) })
        #expect(harness.streamManagements.allSatisfy { $0.isActive })
        #expect(motion.existingCharacteristic(.statusActive)?.value == .bool(true))
        for service in [ServiceType.microphone, .speaker] {
            #expect(try harness.characteristic(service, .mute).value == .bool(false))
            #expect(try harness.characteristic(service, .volume).value == .uint(100))
        }
        #expect(try await Self.snapshot(harness, reason: SnapshotReason.periodic.rawValue) == harness.streaming.state.withLock { $0.snapshotData })
        let persisted = try JSONDecoder().decode(PersistedCameraState.self,
                                                 from: try #require(await harness.server.extra(forKey: CameraController.persistenceKey)))
        #expect(persisted.selectedConfiguration == nil && !persisted.recordingActive && !persisted.recordingAudioActive)
        #expect(persisted.homeKitCameraActive && persisted.eventSnapshotsActive && persisted.periodicSnapshotsActive)
        #expect(persisted.nightVision == false && persisted.streamActive == [true, true])
        await harness.stop()

        // Started again (still unpaired): the same factory state.
        let restarted = await CameraHarness.make(nightVision: true, store: store)
        defer { await restarted.stop() }
        #expect(restarted.controller.operatingState == Self.factoryStateWithNightVisionOff)
        #expect(restarted.recording.calls == [.configuration(nil), .active(false), .audioActive(false)])
    }

    /// Pairings cleared while the camera was not running (`BridgeEngine.resetPairing` of a stopped camera), or state that
    /// outlived an unpairing: an accessory without pairings starts from the factory state.
    @Test func savedStateOfAnUnpairedAccessoryIsNotRestored() async throws {
        let store = try CameraHarness.pairedStore()
        let first = await CameraHarness.make(nightVision: true, store: store)
        try await Self.makeNonDefault(first, as: FakeHAPSession())
        await first.stop()
        var state = try #require(try store.loadState())
        state.pairings = []
        try store.saveState(state)

        let second = await CameraHarness.make(nightVision: true, store: store)
        defer { await second.stop() }
        #expect(second.controller.operatingState == Self.factoryStateWithNightVisionOff)
        #expect(second.recording.calls == [.configuration(nil), .active(false), .audioActive(false)])
        #expect(second.streamServices.allSatisfy { $0.existingCharacteristic(.active)?.value == .uint(1) })
        #expect(try second.characteristic(.cameraOperatingMode, .homeKitCameraActive).value == .uint(1))
        #expect(await hapStatus {
            _ = try await second.characteristic(.cameraRecordingManagement, .selectedCameraRecordingConfiguration).read(as: FakeHAPSession())
        } == .serviceCommunicationFailure)
        let persisted = try JSONDecoder().decode(PersistedCameraState.self,
                                                 from: try #require(await second.server.extra(forKey: CameraController.persistenceKey)))
        #expect(persisted.selectedConfiguration == nil && !persisted.recordingActive && persisted.homeKitCameraActive)
    }

    @Test func unreadablePersistedStateIsIgnored() async throws {
        let store = InMemoryHAPStore()
        var state = HAPPersistentState()
        state.extras[CameraController.persistenceKey] = Data("not json".utf8)
        try store.saveState(state)
        let harness = await CameraHarness.make(store: store)
        defer { await harness.stop() }
        #expect(harness.controller.operatingState == Self.defaultState)
        let persisted = try #require(await harness.server.extra(forKey: CameraController.persistenceKey))
        #expect((try? JSONDecoder().decode(PersistedCameraState.self, from: persisted)) != nil)
    }

    @Test func persistedStateWithMissingFieldsKeepsWhatItHas() async throws {
        // Written by another version: fields it did not know are missing, one it had is unknown to us.
        let json = Data(#"{"version":1,"recordingActive":true,"homeKitCameraActive":false,"streamActive":[true,false],"futureField":7}"#.utf8)
        let decoded = try JSONDecoder().decode(PersistedCameraState.self, from: json)
        var expected = PersistedCameraState()
        expected.recordingActive = true
        expected.homeKitCameraActive = false
        expected.streamActive = [true, false]
        #expect(decoded == expected)
        #expect(try JSONDecoder().decode(PersistedCameraState.self, from: Data("{}".utf8)) == PersistedCameraState())

        let store = try CameraHarness.pairedStore()
        var state = try #require(try store.loadState())
        state.extras[CameraController.persistenceKey] = json
        try store.saveState(state)
        let harness = await CameraHarness.make(store: store)
        defer { await harness.stop() }
        var restored = Self.defaultState
        restored.recordingActive = true
        restored.homeKitCameraActive = false
        #expect(harness.controller.operatingState == restored)
        #expect(harness.recording.calls == [.configuration(nil), .active(true), .audioActive(false)])
        #expect(harness.streamServices[1].existingCharacteristic(.active)?.value == .uint(0))
        #expect(try harness.characteristic(.cameraOperatingMode, .homeKitCameraActive).value == .uint(0))
    }

    @Test func motionSensorAndStatus() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let motion = try #require(harness.controller.motionService)
        harness.controller.setMotionDetected(true)
        #expect(motion.existingCharacteristic(.motionDetected)?.value == .bool(true))
        harness.controller.setMotionDetected(false)
        #expect(motion.existingCharacteristic(.motionDetected)?.value == .bool(false))

        harness.controller.setSensorStatus(active: false, fault: true, tampered: true)
        #expect(motion.existingCharacteristic(.statusActive)?.value == .bool(false))
        #expect(motion.existingCharacteristic(.statusFault)?.value == .uint(1))
        #expect(motion.existingCharacteristic(.statusTampered)?.value == .uint(1))
        harness.controller.setSensorStatus(active: true, fault: false, tampered: false)
        #expect(motion.existingCharacteristic(.statusActive)?.value == .bool(true))
        #expect(motion.existingCharacteristic(.statusFault)?.value == .uint(0))
        // StatusActive is the sensor status AND HomeKitCameraActive.
        try await harness.characteristic(.cameraOperatingMode, .homeKitCameraActive).write(.uint(0), as: FakeHAPSession())
        #expect(motion.existingCharacteristic(.statusActive)?.value == .bool(false))
        harness.controller.setSensorStatus(active: true, fault: false, tampered: false)
        #expect(motion.existingCharacteristic(.statusActive)?.value == .bool(false))
    }

    @Test func doorbellServiceAndRing() async throws {
        let harness = await CameraHarness.make(isDoorbell: true)
        defer { await harness.stop() }
        let doorbell = try #require(harness.service(.doorbell))
        #expect(doorbell.isPrimary)
        #expect(harness.accessory.services.filter(\.isPrimary).count == 1)
        let event = try #require(doorbell.existingCharacteristic(.programmableSwitchEvent))
        #expect(event.validValuesOverride == [0])
        #expect(try await event.read(as: FakeHAPSession()) == .null)
        let received = Mutex<[HAPValue]>([])
        _ = event.addObserver { value, _ in received.withLock { $0.append(value) } }
        harness.controller.ringDoorbell()
        harness.controller.ringDoorbell()
        #expect(received.withLock { $0 } == [.uint(0), .uint(0)])
        let recording = try #require(harness.service(.cameraRecordingManagement))
        #expect(recording.existingCharacteristic(.supportedCameraRecordingConfiguration)?.value
            == .data(CameraTLV.supportedCameraRecordingConfiguration(CameraHarness.recordingOptions,
                                                                     eventTriggers: RecordingEventTrigger.motion | RecordingEventTrigger.doorbell)))

        // Ringing a plain camera is a no-op.
        let camera = await CameraHarness.make()
        defer { await camera.stop() }
        camera.controller.ringDoorbell()
        #expect(camera.service(.doorbell) == nil)
    }

    @Test func microphoneAndSpeaker() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let microphone = try #require(harness.service(.microphone))
        let speaker = try #require(harness.service(.speaker))
        #expect(microphone.existingCharacteristic(.mute)?.value == .bool(false))
        #expect(microphone.existingCharacteristic(.volume)?.value == .uint(100))
        #expect(speaker.existingCharacteristic(.mute)?.value == .bool(false))
        #expect(speaker.existingCharacteristic(.volume)?.value == .uint(100))
        try await speaker.characteristic(.mute).write(.bool(true), as: FakeHAPSession())
        #expect(speaker.existingCharacteristic(.mute)?.value == .bool(true))

        let quiet = await CameraHarness.make(twoWayAudio: false)
        defer { await quiet.stop() }
        #expect(quiet.service(.speaker) == nil && quiet.service(.microphone) != nil)
    }

    @Test func setupDataStreamTransport() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let setup = try harness.characteristic(.dataStreamTransportManagement, .setupDataStreamTransport)
        let session = FakeHAPSession()
        let salt = Data((0..<32).map { UInt8($0) })
        let written = try await setup.write(.data(CameraTLV.SetupDataStreamTransportRequest(controllerKeySalt: salt).encoded), as: session)
        let response = try CameraTLV.SetupDataStreamTransportResponse(parsing: try #require(written?.dataValue))
        #expect(response.status == .success && response.port != 0 && response.accessoryKeySalt.count == 32)
        #expect(try await setup.readData(as: session) == response.encodedWithoutSalt)

        #expect(await hapStatus { try await setup.write(.data(CameraTLV.SetupDataStreamTransportRequest(controllerKeySalt: Data(count: 16)).encoded),
                                                        as: session) } == .invalidValue)
        #expect(await hapStatus { try await setup.write(.data(CameraTLV.SetupDataStreamTransportRequest(command: 1, controllerKeySalt: salt).encoded),
                                                        as: session) } == .invalidValue)
        #expect(await hapStatus { try await setup.write(.data(CameraTLV.SetupDataStreamTransportRequest(transportType: 1, controllerKeySalt: salt).encoded),
                                                        as: session) } == .invalidValue)
        #expect(await hapStatus { try await setup.write(.data(Data([0xFF])), as: session) } == .invalidValue)
    }

    @Test func installTwiceIsIgnored() async throws {
        let harness = await CameraHarness.make()
        defer { await harness.stop() }
        let count = harness.accessory.services.count
        await harness.controller.install(on: harness.accessory, server: harness.server)
        #expect(harness.accessory.services.count == count)
    }

    static func snapshot(_ harness: CameraHarness, reason: Int?) async throws(HAPStatus) -> Data {
        guard let handler = harness.accessory.resourceHandler else { throw .resourceDoesNotExist }
        let request = HAPResourceRequest(type: "image", width: 640, height: 360, reason: reason)
        return try await handler(request, FakeHAPSession().context)
    }
}
#endif
