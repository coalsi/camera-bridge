import BridgeSupport
import Foundation
import HAP
import HDS

// MARK: - Characteristic maps

/// The characteristics of one CameraRTPStreamManagement service.
public struct RTPStreamManagementIDs: Sendable, Hashable {
    public var aid: UInt64
    public var serviceIID: UInt64
    public var supportedVideo: HAPCharacteristicID
    public var supportedAudio: HAPCharacteristicID
    public var supportedRTP: HAPCharacteristicID
    public var selectedConfiguration: HAPCharacteristicID
    public var setupEndpoints: HAPCharacteristicID
    public var streamingStatus: HAPCharacteristicID
    public var active: HAPCharacteristicID?

    public init(service: HAPAccessoryDatabase.ServiceInfo) throws {
        func required(_ type: CharacteristicType) throws -> HAPCharacteristicID {
            guard let found = service.characteristic(type) else { throw HAPControllerError.notFound("\(type.name) in RTP stream management \(service.iid)") }
            return found.id
        }
        aid = service.aid
        serviceIID = service.iid
        supportedVideo = try required(.supportedVideoStreamConfiguration)
        supportedAudio = try required(.supportedAudioStreamConfiguration)
        supportedRTP = try required(.supportedRTPConfiguration)
        selectedConfiguration = try required(.selectedRTPStreamConfiguration)
        setupEndpoints = try required(.setupEndpoints)
        streamingStatus = try required(.streamingStatus)
        active = service.characteristic(.active)?.id
    }
}

/// The characteristics of CameraRecordingManagement.
public struct CameraRecordingIDs: Sendable, Hashable {
    public var active: HAPCharacteristicID
    public var recordingAudioActive: HAPCharacteristicID?
    public var supportedCameraConfiguration: HAPCharacteristicID
    public var supportedVideoConfiguration: HAPCharacteristicID
    public var supportedAudioConfiguration: HAPCharacteristicID
    public var selectedConfiguration: HAPCharacteristicID

    public init(service: HAPAccessoryDatabase.ServiceInfo) throws {
        func required(_ type: CharacteristicType) throws -> HAPCharacteristicID {
            guard let found = service.characteristic(type) else { throw HAPControllerError.notFound("\(type.name) in recording management") }
            return found.id
        }
        active = try required(.active)
        recordingAudioActive = service.characteristic(.recordingAudioActive)?.id
        supportedCameraConfiguration = try required(.supportedCameraRecordingConfiguration)
        supportedVideoConfiguration = try required(.supportedVideoRecordingConfiguration)
        supportedAudioConfiguration = try required(.supportedAudioRecordingConfiguration)
        selectedConfiguration = try required(.selectedCameraRecordingConfiguration)
    }
}

/// The characteristics of a camera accessory a controller uses (services found by type on one aid).
public struct CameraAccessoryIDs: Sendable, Hashable {
    public var aid: UInt64
    public var streams: [RTPStreamManagementIDs]
    public var recording: CameraRecordingIDs?
    public var homeKitCameraActive: HAPCharacteristicID?
    public var eventSnapshotsActive: HAPCharacteristicID?
    public var periodicSnapshotsActive: HAPCharacteristicID?
    public var setupDataStreamTransport: HAPCharacteristicID?
    public var supportedDataStreamTransportConfiguration: HAPCharacteristicID?
    public var motionDetected: HAPCharacteristicID?
    public var programmableSwitchEvent: HAPCharacteristicID?

    public init(database: HAPAccessoryDatabase, aid: UInt64 = 1) throws {
        guard let accessory = database.accessory(aid: aid) else { throw HAPControllerError.notFound("accessory \(aid)") }
        self.aid = aid
        streams = try accessory.services(.cameraRTPStreamManagement).map { try RTPStreamManagementIDs(service: $0) }
        recording = try accessory.service(.cameraRecordingManagement).map { try CameraRecordingIDs(service: $0) }
        let operatingMode = accessory.service(.cameraOperatingMode)
        homeKitCameraActive = operatingMode?.characteristic(.homeKitCameraActive)?.id
        eventSnapshotsActive = operatingMode?.characteristic(.eventSnapshotsActive)?.id
        periodicSnapshotsActive = operatingMode?.characteristic(.periodicSnapshotsActive)?.id
        let dataStream = accessory.service(.dataStreamTransportManagement)
        setupDataStreamTransport = dataStream?.characteristic(.setupDataStreamTransport)?.id
        supportedDataStreamTransportConfiguration = dataStream?.characteristic(.supportedDataStreamTransportConfiguration)?.id
        motionDetected = accessory.characteristic(.motionDetected, in: .motionSensor)?.id
        programmableSwitchEvent = accessory.characteristic(.programmableSwitchEvent, in: .doorbell)?.id
            ?? accessory.characteristic(.programmableSwitchEvent)?.id
    }
}

/// What a controller asks for when starting a live stream (defaults: 1280×720@30 Main 4.0, Opus 24 kHz 20 ms).
public struct LiveStreamOptions: Sendable, Hashable {
    public var resolution: ControllerTLV.Resolution
    public var profile: UInt8
    public var level: UInt8
    public var maxBitrateKbps: UInt16
    public var videoPayloadType: UInt8
    public var maxMTU: UInt16?
    /// nil = no audio parameters in the start command.
    public var audio: ControllerTLV.SelectedAudio?
    public var rtcpInterval: Float
    /// Receiver reports while the stream runs (nil = none; the accessory then times out after 30 s).
    public var keepaliveInterval: Duration?

    public init(resolution: ControllerTLV.Resolution = ControllerTLV.Resolution(1280, 720, 30), profile: UInt8 = 1, level: UInt8 = 2,
                maxBitrateKbps: UInt16 = 2000, videoPayloadType: UInt8 = 99, maxMTU: UInt16? = 1378,
                audio: ControllerTLV.SelectedAudio? = ControllerTLV.SelectedAudio(ssrc: UInt32.random(in: 1...UInt32.max)),
                rtcpInterval: Float = 0.5, keepaliveInterval: Duration? = .milliseconds(500)) {
        self.resolution = resolution
        self.profile = profile
        self.level = level
        self.maxBitrateKbps = maxBitrateKbps
        self.videoPayloadType = videoPayloadType
        self.maxMTU = maxMTU
        self.audio = audio
        self.rtcpInterval = rtcpInterval
        self.keepaliveInterval = keepaliveInterval
    }
}

/// A running live stream: the SetupEndpoints answer, what was selected, and the receiver.
public struct LiveStreamHandle: Sendable {
    public let controller: HAPTestController
    public let stream: RTPStreamManagementIDs
    public let sessionID: UUID
    public let endpoints: ControllerTLV.SetupEndpointsResponse
    public let video: ControllerTLV.SelectedVideo
    public let audio: ControllerTLV.SelectedAudio?
    public let receiver: SRTPTestReceiver

    /// Sends `reconfigure` with new video parameters (same SSRC and payload type).
    public func reconfigure(resolution: ControllerTLV.Resolution, maxBitrateKbps: UInt16) async throws {
        var video = self.video
        video.resolution = resolution
        video.maxBitrateKbps = maxBitrateKbps
        try await controller.selectStream(stream, ControllerTLV.SelectedRTPStreamConfiguration(sessionID: sessionID, command: .reconfigure, video: video))
    }

    /// Sends `end` and then stops the receiver (unless `keepReceiver`, e.g. to watch for the accessory's BYE).
    public func stop(keepReceiver: Bool = false) async throws {
        do {
            try await controller.selectStream(stream, ControllerTLV.SelectedRTPStreamConfiguration(sessionID: sessionID, command: .end))
        } catch {
            if !keepReceiver { await receiver.stop() }
            throw error
        }
        if !keepReceiver { await receiver.stop() }
    }
}

// MARK: - Camera operations

extension HAPTestController {
    /// Parsed characteristics of the camera accessory `aid`.
    public func cameraIDs(aid: UInt64 = 1) async throws -> CameraAccessoryIDs {
        try CameraAccessoryIDs(database: try await accessories(), aid: aid)
    }

    /// The three Supported* values of an RTP stream management service.
    public func supportedStreamingConfiguration(_ stream: RTPStreamManagementIDs) async throws
        -> (video: ControllerTLV.SupportedVideoStreamConfiguration, audio: ControllerTLV.SupportedAudioStreamConfiguration,
            rtp: ControllerTLV.SupportedRTPConfiguration) {
        let values = try await readDataValues([stream.supportedVideo, stream.supportedAudio, stream.supportedRTP])
        return (try ControllerTLV.SupportedVideoStreamConfiguration.decode(values[0]), try ControllerTLV.SupportedAudioStreamConfiguration.decode(values[1]),
                try ControllerTLV.SupportedRTPConfiguration.decode(values[2]))
    }

    public func streamingStatus(_ stream: RTPStreamManagementIDs) async throws -> ControllerTLV.StreamingStatus {
        try ControllerTLV.StreamingStatus.decode(try await readData(stream.streamingStatus))
    }

    /// Writes SetupEndpoints and reads the accessory's answer back.
    public func setupEndpoints(_ stream: RTPStreamManagementIDs, _ request: ControllerTLV.SetupEndpointsRequest) async throws -> ControllerTLV.SetupEndpointsResponse {
        try await writeData(stream.setupEndpoints, request.encoded())
        return try ControllerTLV.SetupEndpointsResponse.decode(try await readData(stream.setupEndpoints))
    }

    /// Writes SelectedRTPStreamConfiguration (start / reconfigure / end …).
    public func selectStream(_ stream: RTPStreamManagementIDs, _ configuration: ControllerTLV.SelectedRTPStreamConfiguration) async throws {
        try await writeData(stream.selectedConfiguration, configuration.encoded())
    }

    /// SetupEndpoints with a fresh receiver on this connection's local address, then `start`. The receiver starts
    /// sending receiver reports before the start command (accessories may wait for the first RTCP).
    ///
    /// The SetupEndpoints answer must echo our SRTP keys (the receiver decrypts with them), carry both accessory SSRCs
    /// (media is filtered by them, as iOS does) and an accessory address of this connection's family; otherwise this
    /// throws `malformedResponse` before any start command.
    public func startLiveStream(_ stream: RTPStreamManagementIDs, options: LiveStreamOptions = LiveStreamOptions()) async throws -> LiveStreamHandle {
        let receiver = try await SRTPTestReceiver.start(host: localAddress, ipv6: isIPv6)
        do {
            let sessionID = UUID()
            let request = ControllerTLV.SetupEndpointsRequest(sessionID: sessionID, controller: receiver.address, video: receiver.videoKeys,
                                                              audio: receiver.audioKeys)
            let endpoints = try await setupEndpoints(stream, request)
            guard endpoints.isSuccess, let accessory = endpoints.accessory else {
                throw HAPControllerError.malformedResponse("SetupEndpoints status \(endpoints.status)")
            }
            guard endpoints.sessionID == sessionID else { throw HAPControllerError.malformedResponse("SetupEndpoints answered another session") }
            guard endpoints.video == receiver.videoKeys, endpoints.audio == receiver.audioKeys else {
                throw HAPControllerError.malformedResponse("SetupEndpoints answered other SRTP keys than the controller's (they must be echoed)")
            }
            guard let accessoryVideoSSRC = endpoints.videoSSRC, let accessoryAudioSSRC = endpoints.audioSSRC else {
                throw HAPControllerError.malformedResponse("SetupEndpoints answered without the accessory's video and audio SSRC")
            }
            guard accessory.isIPv6 == isIPv6, accessory.ip.contains(":") == isIPv6 else {
                throw HAPControllerError.malformedResponse("SetupEndpoints answered accessory address \(accessory.ip) (\(accessory.isIPv6 ? "IPv6" : "IPv4") flag) "
                                                           + "on an \(isIPv6 ? "IPv6" : "IPv4") connection: wrong address family")
            }
            let video = ControllerTLV.SelectedVideo(profile: options.profile, level: options.level, resolution: options.resolution,
                                                    payloadType: options.videoPayloadType, ssrc: UInt32.random(in: 1...UInt32.max),
                                                    maxBitrateKbps: options.maxBitrateKbps, rtcpInterval: options.rtcpInterval, maxMTU: options.maxMTU)
            let audio = options.audio
            await receiver.connect(to: SRTPTestReceiver.Peer(host: accessory.ip, videoPort: accessory.videoPort, audioPort: accessory.audioPort,
                                                             videoSSRC: accessoryVideoSSRC, audioSSRC: accessoryAudioSSRC,
                                                             controllerVideoSSRC: video.ssrc, controllerAudioSSRC: audio?.ssrc ?? video.ssrc &+ 1,
                                                             videoPayloadType: video.payloadType, audioPayloadType: audio?.payloadType),
                                   keepaliveInterval: options.keepaliveInterval)
            try await selectStream(stream, ControllerTLV.SelectedRTPStreamConfiguration(sessionID: sessionID, command: .start, video: video, audio: audio))
            return LiveStreamHandle(controller: self, stream: stream, sessionID: sessionID, endpoints: endpoints, video: video, audio: audio,
                                    receiver: receiver)
        } catch {
            await receiver.stop()
            throw error
        }
    }

    /// The three Supported* values of CameraRecordingManagement.
    public func supportedRecordingConfiguration(_ recording: CameraRecordingIDs) async throws
        -> (camera: ControllerTLV.SupportedCameraRecordingConfiguration, video: ControllerTLV.SupportedVideoRecordingConfiguration,
            audio: ControllerTLV.SupportedAudioRecordingConfiguration) {
        let values = try await readDataValues([recording.supportedCameraConfiguration, recording.supportedVideoConfiguration,
                                               recording.supportedAudioConfiguration])
        return (try ControllerTLV.SupportedCameraRecordingConfiguration.decode(values[0]),
                try ControllerTLV.SupportedVideoRecordingConfiguration.decode(values[1]),
                try ControllerTLV.SupportedAudioRecordingConfiguration.decode(values[2]))
    }

    /// Writes SelectedCameraRecordingConfiguration as a hub does.
    public func selectRecordingConfiguration(_ recording: CameraRecordingIDs, _ configuration: ControllerTLV.SelectedCameraRecordingConfiguration) async throws {
        try await writeData(recording.selectedConfiguration, configuration.encoded())
    }

    /// What a hub turns on before recording: HomeKitCameraActive, EventSnapshotsActive, recording Active and
    /// RecordingAudioActive (a timed write), each only if the accessory has it.
    public func enableRecording(_ camera: CameraAccessoryIDs, audio: Bool) async throws {
        guard let recording = camera.recording else { throw HAPControllerError.notFound("CameraRecordingManagement") }
        if let active = camera.homeKitCameraActive { try await writeValue(active, .int(1)) }
        if let snapshots = camera.eventSnapshotsActive { try await writeValue(snapshots, .int(1)) }
        try await writeValue(recording.active, .int(1))
        if let audioActive = recording.recordingAudioActive { try await writeValue(audioActive, .int(audio ? 1 : 0), timedWriteTTL: .seconds(5)) }
    }

    /// SetupDataStreamTransport (write with response) → HDS connection to the accessory → `control/hello`.
    public func openDataStream(_ setupDataStreamTransport: HAPCharacteristicID, timeout: Duration = .seconds(10)) async throws -> HDSTestClient {
        guard let sharedSecret else { throw HAPControllerError.notPaired }
        let request = ControllerTLV.SetupDataStreamTransportRequest()
        guard let answer = try await writeData(setupDataStreamTransport, request.encoded(), wantsResponse: true) else {
            throw HAPControllerError.malformedResponse("SetupDataStreamTransport: no write-response")
        }
        let response = try ControllerTLV.SetupDataStreamTransportResponse.decode(answer)
        guard response.status == 0, let port = response.tcpPort, let accessorySalt = response.accessoryKeySalt else {
            throw HAPControllerError.malformedResponse("SetupDataStreamTransport status \(response.status)")
        }
        let client = try await HDSTestClient.connect(host: host, port: port, transport: transport, sharedSecret: sharedSecret,
                                                     controllerKeySalt: request.controllerKeySalt, accessoryKeySalt: accessorySalt, timeout: timeout)
        do {
            try await client.hello(timeout: timeout)
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    /// Reads several tlv8/data characteristics in one request (in order); throws for any per-item error.
    public func readDataValues(_ ids: [HAPCharacteristicID]) async throws -> [Data] {
        let results = try await read(ids)
        return try ids.map { id in
            guard let result = results.first(where: { $0.id == id }) else { throw HAPControllerError.malformedResponse("\(id) missing") }
            guard result.status == 0 else { throw HAPControllerError.characteristicStatus(aid: id.aid, iid: id.iid, status: result.status) }
            guard let data = result.value?.base64Data else { throw HAPControllerError.malformedResponse("\(id) is not base64 data") }
            return data
        }
    }
}

// MARK: - Choosing configurations like a hub

extension ControllerTLV.SelectedCameraRecordingConfiguration {
    /// A hub-like selection from the accessory's options: 1920×1080 if offered (else the largest resolution), Main
    /// profile if offered (else the first), the highest level, 2000 kbps, IDR interval = fragment length, the first
    /// audio codec at 32 kHz if offered (else its first rate), 64 kbps, every advertised trigger.
    public static func preferred(camera: ControllerTLV.SupportedCameraRecordingConfiguration, video: ControllerTLV.SupportedVideoRecordingConfiguration,
                                 audio: ControllerTLV.SupportedAudioRecordingConfiguration) throws -> Self {
        guard let codec = video.codecs.first, let largest = codec.resolutions.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            throw ControllerTLVError.missing("video recording configuration")
        }
        let resolution = codec.resolutions.first { $0.width == 1920 && $0.height == 1080 } ?? largest
        guard let container = camera.containers.first else { throw ControllerTLVError.missing("media container") }
        guard let audioCodec = audio.codecs.first, let firstRate = audioCodec.sampleRates.first else {
            throw ControllerTLVError.missing("audio recording configuration")
        }
        return Self(prebufferLengthMs: camera.prebufferLengthMs, eventTriggers: camera.eventTriggers, container: container,
                    videoCodec: codec.codec, videoProfile: codec.profiles.contains(1) ? 1 : (codec.profiles.first ?? 1),
                    videoLevel: codec.levels.max() ?? 2, videoBitrateKbps: 2000, iFrameIntervalMs: container.fragmentLengthMs, resolution: resolution,
                    audioCodec: audioCodec.codec, audioChannels: audioCodec.channels, audioBitrateMode: audioCodec.bitrateMode,
                    audioSampleRate: audioCodec.sampleRates.contains(3) ? 3 : firstRate, audioMaxBitrateKbps: 64)
    }
}
