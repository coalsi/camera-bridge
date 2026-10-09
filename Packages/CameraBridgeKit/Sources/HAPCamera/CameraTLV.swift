// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// TLV layouts follow HAP-NodeJS lib/camera/RTPStreamManagement.ts, lib/camera/RecordingManagement.ts and
// lib/datastream/DataStreamManagement.ts (research brief §3.5, §3.7).

import BridgeSupport
import Foundation
import HAPCore

/// A camera TLV that could not be parsed.
public enum CameraTLVError: Error, Equatable, Sendable {
    case malformed(String)
}

/// Encoders and parsers for the camera, recording and data-stream TLV8 values (research brief §3.5, §3.7).
///
/// List elements (resolutions, profiles, levels, sample rates, codec configurations, crypto suites, containers) are
/// consecutive items of the same type separated by an empty `00 00` item, as HAP-NodeJS writes them. Integers are
/// little-endian. Encoders never fail: out-of-range numbers are clamped into their field.
public enum CameraTLV {
    // MARK: - Streaming status

    public enum StreamingStatus: UInt8, Sendable, Equatable { case available = 0, inUse = 1, unavailable = 2 }

    /// StreamingStatus value `{1: status}`.
    public static func streamingStatus(_ status: StreamingStatus) -> Data {
        var builder = TLVBuilder()
        builder.add(0x01, uint8: status.rawValue)
        return builder.data
    }

    // MARK: - Supported streaming configurations (CameraRTPStreamManagement)

    /// `1:{1 codec(H.264), 2 {1 profiles, 2 levels, 3 packetization mode 0}, 3 attributes list}`.
    public static func supportedVideoStreamConfiguration(_ options: CameraStreamingOptions) -> Data {
        var parameters = TLVBuilder()
        addList(&parameters, 0x01, options.profiles.map { Data([$0.rawValue]) })
        addList(&parameters, 0x02, options.levels.map { Data([$0.rawValue]) })
        parameters.add(0x03, uint8: 0)   // packetization mode: non-interleaved
        var configuration = TLVBuilder()
        configuration.add(0x01, uint8: 0)   // H.264
        configuration.add(0x02, tlv: parameters)
        addList(&configuration, 0x03, options.resolutions.map(videoAttributes))
        var builder = TLVBuilder()
        builder.add(0x01, tlv: configuration)
        return builder.data
    }

    /// `1: list{1 codec, 2 {1 channels(1), 2 bitrate mode(0 variable), 3 sample rates}}, 2: comfort noise (0)`.
    public static func supportedAudioStreamConfiguration(_ options: CameraStreamingOptions) -> Data {
        let codecs = options.audioCodecs.map { codec -> Data in
            var parameters = TLVBuilder()
            parameters.add(0x01, uint8: 1)
            parameters.add(0x02, uint8: 0)
            addList(&parameters, 0x03, codec.sampleRates.map { Data([$0.rawValue]) })
            var configuration = TLVBuilder()
            configuration.add(0x01, uint8: codec.codec.rawValue)
            configuration.add(0x02, tlv: parameters)
            return configuration.data
        }
        var builder = TLVBuilder()
        addList(&builder, 0x01, codecs)
        builder.add(0x02, uint8: 0)   // comfort noise not supported
        return builder.data
    }

    /// `2: crypto suites list`.
    public static func supportedRTPConfiguration(_ options: CameraStreamingOptions) -> Data {
        var builder = TLVBuilder()
        addList(&builder, 0x02, options.cryptoSuites.map { Data([$0.rawValue]) })
        return builder.data
    }

    // MARK: - Supported recording configurations (CameraRecordingManagement)

    /// The trigger mask a camera advertises: motion, plus doorbell for video doorbells (DoorbellController).
    public static func eventTriggers(isDoorbell: Bool) -> UInt64 {
        isDoorbell ? RecordingEventTrigger.motion | RecordingEventTrigger.doorbell : RecordingEventTrigger.motion
    }

    /// `1 prebuffer i32, 2 event triggers (8 bytes), 3 container list{1 type(0 fMP4), 2 {1 fragment length i32}}`.
    public static func supportedCameraRecordingConfiguration(_ options: CameraRecordingOptions, eventTriggers: UInt64) -> Data {
        var builder = TLVBuilder()
        builder.add(0x01, uint32LE: int32Bits(options.prebufferLengthMs))
        builder.add(0x02, uint64LE: eventTriggers)
        builder.add(0x03, mediaContainer(fragmentLengthMs: options.fragmentLengthMs))
        return builder.data
    }

    /// `1 {1 codec(H.264), 2 {1 profiles, 2 levels}, 3 attributes list}`.
    public static func supportedVideoRecordingConfiguration(_ options: CameraRecordingOptions) -> Data {
        var parameters = TLVBuilder()
        addList(&parameters, 0x01, options.profiles.map { Data([$0.rawValue]) })
        addList(&parameters, 0x02, options.levels.map { Data([$0.rawValue]) })
        var configuration = TLVBuilder()
        configuration.add(0x01, uint8: 0)
        configuration.add(0x02, tlv: parameters)
        addList(&configuration, 0x03, options.resolutions.map(videoAttributes))
        var builder = TLVBuilder()
        builder.add(0x01, tlv: configuration)
        return builder.data
    }

    /// `1 list{1 codec, 2 {1 channels, 2 bitrate mode(0), 3 sample rates}}` (one codec configuration).
    public static func supportedAudioRecordingConfiguration(_ options: CameraRecordingOptions) -> Data {
        var parameters = TLVBuilder()
        parameters.add(0x01, uint8: UInt8(clamping: max(1, options.audioChannels)))
        parameters.add(0x02, uint8: 0)
        addList(&parameters, 0x03, options.audioSampleRates.map { Data([$0.rawValue]) })
        var configuration = TLVBuilder()
        configuration.add(0x01, uint8: options.audioCodec.rawValue)
        configuration.add(0x02, tlv: parameters)
        var builder = TLVBuilder()
        builder.add(0x01, tlv: configuration)
        return builder.data
    }

    // MARK: - SelectedCameraRecordingConfiguration

    /// Encodes a selection as a hub writes it:
    /// `1 {1 prebuffer, 2 triggers, 3 container}, 2 {1 codec, 2 {1 profile, 2 level, 3 bitrate, 4 iFrameInterval}, 3 attributes},
    /// 3 {1 codec, 2 {1 channels, 2 bitrate mode, 3 sample rate, 4 max bitrate}}`.
    public static func selectedRecordingConfiguration(_ configuration: CameraRecordingConfiguration) -> Data {
        var recording = TLVBuilder()
        recording.add(0x01, uint32LE: int32Bits(configuration.prebufferLengthMs))
        recording.add(0x02, uint64LE: configuration.eventTriggers)
        recording.add(0x03, mediaContainer(fragmentLengthMs: configuration.fragmentLengthMs))

        var videoParameters = TLVBuilder()
        videoParameters.add(0x01, uint8: configuration.videoProfile.rawValue)
        videoParameters.add(0x02, uint8: configuration.videoLevel.rawValue)
        videoParameters.add(0x03, uint32LE: int32Bits(configuration.videoBitrateKbps))
        videoParameters.add(0x04, uint32LE: int32Bits(configuration.iFrameIntervalMs))
        var video = TLVBuilder()
        video.add(0x01, uint8: 0)
        video.add(0x02, tlv: videoParameters)
        video.add(0x03, videoAttributes(configuration.resolution))

        var audioParameters = TLVBuilder()
        audioParameters.add(0x01, uint8: UInt8(clamping: configuration.audioChannels))
        audioParameters.add(0x02, uint8: 0)
        audioParameters.add(0x03, uint8: configuration.audioSampleRate.rawValue)
        audioParameters.add(0x04, uint32LE: UInt32(clamping: max(0, configuration.audioMaxBitrateKbps)))
        var audio = TLVBuilder()
        audio.add(0x01, uint8: configuration.audioCodec.rawValue)
        audio.add(0x02, tlv: audioParameters)

        var builder = TLVBuilder()
        builder.add(0x01, tlv: recording)
        builder.add(0x02, tlv: video)
        builder.add(0x03, tlv: audio)
        return builder.data
    }

    /// Parses a SelectedCameraRecordingConfiguration write. Throws `CameraTLVError` for missing fields or values outside
    /// the contract enums (HAP-NodeJS `parseSelectedConfiguration` would crash on those).
    public static func parseSelectedRecordingConfiguration(_ data: Data) throws(CameraTLVError) -> CameraRecordingConfiguration {
        let top = try reader(data, "selected recording configuration")
        let recording = try nested(top, 0x01, "recording configuration")
        let video = try nested(top, 0x02, "video configuration")
        let audio = try nested(top, 0x03, "audio configuration")

        let prebuffer = try int32(recording, 0x01, "prebuffer length")
        guard let triggers = recording.uint64LE(0x02) else { throw .malformed("event triggers") }
        let containers = listValues(recording.items, type: 0x03)
        guard let firstContainer = containers.first else { throw .malformed("media container") }
        let container = try reader(firstContainer, "media container")
        guard container.uint8(0x01) == 0 else { throw .malformed("media container type") }
        let containerParameters = try nested(container, 0x02, "media container parameters")
        let fragmentLength = try int32(containerParameters, 0x01, "fragment length")

        guard video.uint8(0x01) == 0 else { throw .malformed("video codec") }
        let videoParameters = try nested(video, 0x02, "video parameters")
        guard let profile = videoParameters.uint8(0x01).flatMap(H264Profile.init(rawValue:)) else { throw .malformed("video profile") }
        guard let level = videoParameters.uint8(0x02).flatMap(H264Level.init(rawValue:)) else { throw .malformed("video level") }
        let bitrate = try int32(videoParameters, 0x03, "video bitrate")
        let iFrameInterval = try int32(videoParameters, 0x04, "iFrame interval")
        let resolution = try videoResolution(try nested(video, 0x03, "video attributes"))

        guard let audioCodec = audio.uint8(0x01).flatMap(RecordingAudioCodec.init(rawValue:)) else { throw .malformed("audio codec") }
        let audioParameters = try nested(audio, 0x02, "audio parameters")
        guard let channels = audioParameters.uint8(0x01) else { throw .malformed("audio channels") }
        guard let sampleRate = audioParameters.uint8(0x03).flatMap(RecordingSampleRate.init(rawValue:)) else { throw .malformed("audio sample rate") }
        guard let maxBitrate = audioParameters.uint32LE(0x04) else { throw .malformed("audio max bitrate") }

        return CameraRecordingConfiguration(prebufferLengthMs: prebuffer, eventTriggers: triggers, fragmentLengthMs: fragmentLength,
                                            videoProfile: profile, videoLevel: level, videoBitrateKbps: bitrate, iFrameIntervalMs: iFrameInterval,
                                            resolution: resolution, audioCodec: audioCodec, audioChannels: Int(channels),
                                            audioSampleRate: sampleRate, audioMaxBitrateKbps: Int(maxBitrate))
    }

    // MARK: - SetupEndpoints

    public enum SetupEndpointsStatus: UInt8, Sendable, Equatable { case success = 0, busy = 1, error = 2 }

    /// The controller's SetupEndpoints write: `1 session id(16), 3 address{1 version, 2 ip, 3 video port, 4 audio port},
    /// 4 video SRTP{1 suite, 2 key, 3 salt}, 5 audio SRTP`.
    public struct SetupEndpointsRequest: Sendable, Equatable {
        public var sessionID: UUID
        public var controllerAddress: String
        public var isIPv6: Bool
        public var videoPort: UInt16
        public var audioPort: UInt16
        public var videoSRTP: SRTPParameters
        public var audioSRTP: SRTPParameters

        public init(sessionID: UUID, controllerAddress: String, isIPv6: Bool, videoPort: UInt16, audioPort: UInt16,
                    videoSRTP: SRTPParameters, audioSRTP: SRTPParameters) {
            self.sessionID = sessionID
            self.controllerAddress = controllerAddress
            self.isIPv6 = isIPv6
            self.videoPort = videoPort
            self.audioPort = audioPort
            self.videoSRTP = videoSRTP
            self.audioSRTP = audioSRTP
        }

        public init(parsing data: Data) throws(CameraTLVError) {
            let top = try reader(data, "SetupEndpoints")
            sessionID = try CameraTLV.sessionID(top)
            let address = try nested(top, 0x03, "controller address")
            guard let version = address.uint8(0x01), version <= 1 else { throw .malformed("address version") }
            guard let ip = address.string(0x02), !ip.isEmpty else { throw .malformed("controller address") }
            guard let video = address.uint16LE(0x03), let audio = address.uint16LE(0x04) else { throw .malformed("controller ports") }
            isIPv6 = version == 1
            controllerAddress = ip
            videoPort = video
            audioPort = audio
            videoSRTP = try srtpParameters(try nested(top, 0x04, "video SRTP parameters"))
            audioSRTP = try srtpParameters(try nested(top, 0x05, "audio SRTP parameters"))
        }

        public var encoded: Data {
            var builder = TLVBuilder()
            builder.add(0x01, CameraTLV.bytes(of: sessionID))
            builder.add(0x03, address(version: isIPv6, ip: controllerAddress, videoPort: videoPort, audioPort: audioPort))
            builder.add(0x04, srtp(videoSRTP))
            builder.add(0x05, srtp(audioSRTP))
            return builder.data
        }
    }

    /// The accessory's SetupEndpoints read-back: `1 session id, 2 status, 3 accessory address, 4/5 SRTP, 6 video SSRC,
    /// 7 audio SSRC`.
    public struct SetupEndpointsResponse: Sendable, Equatable {
        public var sessionID: UUID
        public var status: SetupEndpointsStatus
        public var accessoryAddress: String
        public var isIPv6: Bool
        public var videoPort: UInt16
        public var audioPort: UInt16
        public var videoSRTP: SRTPParameters
        public var audioSRTP: SRTPParameters
        public var videoSSRC: UInt32
        public var audioSSRC: UInt32

        public init(sessionID: UUID, status: SetupEndpointsStatus, accessoryAddress: String, isIPv6: Bool, videoPort: UInt16, audioPort: UInt16,
                    videoSRTP: SRTPParameters, audioSRTP: SRTPParameters, videoSSRC: UInt32, audioSSRC: UInt32) {
            self.sessionID = sessionID
            self.status = status
            self.accessoryAddress = accessoryAddress
            self.isIPv6 = isIPv6
            self.videoPort = videoPort
            self.audioPort = audioPort
            self.videoSRTP = videoSRTP
            self.audioSRTP = audioSRTP
            self.videoSSRC = videoSSRC
            self.audioSSRC = audioSSRC
        }

        /// A successful read-back with every field; failures (`failure(sessionID:status:)`) carry id and status only.
        public init(parsing data: Data) throws(CameraTLVError) {
            let top = try reader(data, "SetupEndpoints response")
            sessionID = try CameraTLV.sessionID(top)
            guard let status = top.uint8(0x02).flatMap(SetupEndpointsStatus.init(rawValue:)) else { throw .malformed("status") }
            self.status = status
            let address = try nested(top, 0x03, "accessory address")
            guard let version = address.uint8(0x01), version <= 1, let ip = address.string(0x02),
                  let video = address.uint16LE(0x03), let audio = address.uint16LE(0x04) else { throw .malformed("accessory address") }
            isIPv6 = version == 1
            accessoryAddress = ip
            videoPort = video
            audioPort = audio
            videoSRTP = try srtpParameters(try nested(top, 0x04, "video SRTP parameters"))
            audioSRTP = try srtpParameters(try nested(top, 0x05, "audio SRTP parameters"))
            guard let videoSSRC = top.uint32LE(0x06), let audioSSRC = top.uint32LE(0x07) else { throw .malformed("SSRC") }
            self.videoSSRC = videoSSRC
            self.audioSSRC = audioSSRC
        }

        public var encoded: Data {
            var builder = TLVBuilder()
            builder.add(0x01, CameraTLV.bytes(of: sessionID))
            builder.add(0x02, uint8: status.rawValue)
            builder.add(0x03, address(version: isIPv6, ip: accessoryAddress, videoPort: videoPort, audioPort: audioPort))
            builder.add(0x04, srtp(videoSRTP))
            builder.add(0x05, srtp(audioSRTP))
            builder.add(0x06, uint32LE: videoSSRC)
            builder.add(0x07, uint32LE: audioSSRC)
            return builder.data
        }

        /// `{1 session id, 2 status}` for a busy or failed setup.
        public static func failure(sessionID: UUID, status: SetupEndpointsStatus) -> Data {
            var builder = TLVBuilder()
            builder.add(0x01, CameraTLV.bytes(of: sessionID))
            builder.add(0x02, uint8: status.rawValue)
            return builder.data
        }

        /// `{2: error}`: what SetupEndpoints reads while no session is set up.
        public static var defaultValue: Data {
            var builder = TLVBuilder()
            builder.add(0x02, uint8: SetupEndpointsStatus.error.rawValue)
            return builder.data
        }
    }

    // MARK: - SelectedRTPStreamConfiguration

    public enum SessionCommand: UInt8, Sendable, Equatable { case end = 0, start = 1, suspend = 2, resume = 3, reconfigure = 4 }

    /// `1 control{1 session id, 2 command}, 2 video{1 codec, 2 {1 profile, 2 level, 3 packetization}, 3 attributes,
    /// 4 rtp{1 payload type, 2 SSRC, 3 max bitrate u16, 4 min RTCP interval f32, 5 max MTU u16}},
    /// 3 audio{1 codec, 2 {1 channels, 2 bitrate mode, 3 sample rate, 4 packet time}, 3 rtp{1 payload type, 2 SSRC,
    /// 3 max bitrate, 4 RTCP interval, 6 comfort-noise payload type}, 4 comfort noise}`.
    public struct SelectedRTPStreamConfiguration: Sendable, Equatable {
        public var sessionID: UUID
        public var command: SessionCommand
        public var video: SelectedVideoParameters?
        public var audio: SelectedAudioParameters?

        public init(sessionID: UUID, command: SessionCommand, video: SelectedVideoParameters? = nil, audio: SelectedAudioParameters? = nil) {
            self.sessionID = sessionID
            self.command = command
            self.video = video
            self.audio = audio
        }

        /// `defaultMTU` applies when the video RTP parameters carry no MTU (HAP-NodeJS: 1378 on IPv4, 1228 on IPv6).
        /// Video fields a reconfigure leaves out come from `base` (the running session's parameters); without `base`
        /// every field is required. A minimum RTCP interval of 0 becomes 0.5 s. Audio is parsed when present;
        /// `comfortNoisePayloadType` is set only when comfort noise is enabled.
        public init(parsing data: Data, defaultMTU: Int = 1378, base: SelectedVideoParameters? = nil) throws(CameraTLVError) {
            let top = try reader(data, "SelectedRTPStreamConfiguration")
            let control = try nested(top, 0x01, "session control")
            sessionID = try CameraTLV.sessionID(control)
            guard let command = control.uint8(0x02).flatMap(SessionCommand.init(rawValue:)) else { throw .malformed("session command") }
            self.command = command
            video = try optionalNested(top, 0x02, "video parameters").map { (reader) throws(CameraTLVError) in
                try parseVideo(reader, defaultMTU: defaultMTU, base: base)
            }
            audio = try optionalNested(top, 0x03, "audio parameters").map { (reader) throws(CameraTLVError) in try parseAudio(reader) }
        }

        public var encoded: Data {
            var control = TLVBuilder()
            control.add(0x01, CameraTLV.bytes(of: sessionID))
            control.add(0x02, uint8: command.rawValue)
            var builder = TLVBuilder()
            builder.add(0x01, tlv: control)
            if let video { builder.add(0x02, encodeVideo(video)) }
            if let audio { builder.add(0x03, encodeAudio(audio)) }
            return builder.data
        }
    }

    // MARK: - SetupDataStreamTransport

    public enum DataStreamTransportStatus: UInt8, Sendable, Equatable { case success = 0, error = 1, busy = 2 }

    /// `{1 command(0 start), 2 transport(0 HDS), 3 controller key salt(32)}`.
    public struct SetupDataStreamTransportRequest: Sendable, Equatable {
        public var command: UInt8
        public var transportType: UInt8
        public var controllerKeySalt: Data

        public init(command: UInt8 = 0, transportType: UInt8 = 0, controllerKeySalt: Data) {
            self.command = command
            self.transportType = transportType
            self.controllerKeySalt = controllerKeySalt
        }

        public init(parsing data: Data) throws(CameraTLVError) {
            let top = try reader(data, "SetupDataStreamTransport")
            guard let command = top.uint8(0x01) else { throw .malformed("session command") }
            guard let transport = top.uint8(0x02) else { throw .malformed("transport type") }
            self.command = command
            transportType = transport
            controllerKeySalt = top.data(0x03) ?? Data()
        }

        public var encoded: Data {
            var builder = TLVBuilder()
            builder.add(0x01, uint8: command)
            builder.add(0x02, uint8: transportType)
            builder.add(0x03, controllerKeySalt)
            return builder.data
        }
    }

    /// `{1 status, 2 {1 TCP port u16}, 3 accessory key salt(32)}`.
    public struct SetupDataStreamTransportResponse: Sendable, Equatable {
        public var status: DataStreamTransportStatus
        public var port: UInt16
        public var accessoryKeySalt: Data

        public init(status: DataStreamTransportStatus, port: UInt16, accessoryKeySalt: Data) {
            self.status = status
            self.port = port
            self.accessoryKeySalt = accessoryKeySalt
        }

        public init(parsing data: Data) throws(CameraTLVError) {
            let top = try reader(data, "SetupDataStreamTransport response")
            guard let status = top.uint8(0x01).flatMap(DataStreamTransportStatus.init(rawValue:)) else { throw .malformed("status") }
            let parameters = try nested(top, 0x02, "transport session parameters")
            guard let port = parameters.uint16LE(0x01) else { throw .malformed("TCP port") }
            self.status = status
            self.port = port
            accessoryKeySalt = top.data(0x03) ?? Data()
        }

        public var encoded: Data { encodedWithoutSalt + TLV8.encode([TLV8.Item(0x03, accessoryKeySalt)]) }

        /// What reads of SetupDataStreamTransport return (HAP-NodeJS strips the accessory key salt).
        public var encodedWithoutSalt: Data {
            var parameters = TLVBuilder()
            parameters.add(0x01, uint16LE: port)
            var builder = TLVBuilder()
            builder.add(0x01, uint8: status.rawValue)
            builder.add(0x02, tlv: parameters)
            return builder.data
        }
    }

    /// SupportedDataStreamTransportConfiguration: one transfer transport configuration `{1 {1 transport type(0 HDS)}}`.
    public static let supportedDataStreamTransportConfiguration: Data = {
        var transport = TLVBuilder()
        transport.add(0x01, uint8: 0)
        var builder = TLVBuilder()
        builder.add(0x01, tlv: transport)
        return builder.data
    }()

    // MARK: - Helpers (internal)

    /// The values of the `type` items of a `00 00`-separated list, in order.
    static func listValues(_ items: [TLV8.Item], type: UInt8) -> [Data] {
        items.filter { $0.type == type }.map(\.value)
    }

    /// The 16 session-identifier bytes of `id` (sent and echoed as-is).
    static func bytes(of id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    static func uuid(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let b = Array(data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func addList(_ builder: inout TLVBuilder, _ type: UInt8, _ values: [Data]) {
        for (index, value) in values.enumerated() {
            if index > 0 { builder.addSeparator(type: 0x00) }
            builder.add(type, value)
        }
    }

    private static func videoAttributes(_ resolution: VideoResolution) -> Data {
        var attributes = TLVBuilder()
        attributes.add(0x01, uint16LE: UInt16(clamping: resolution.width))
        attributes.add(0x02, uint16LE: UInt16(clamping: resolution.height))
        attributes.add(0x03, uint8: UInt8(clamping: resolution.fps))
        return attributes.data
    }

    private static func mediaContainer(fragmentLengthMs: Int) -> Data {
        var parameters = TLVBuilder()
        parameters.add(0x01, uint32LE: int32Bits(fragmentLengthMs))
        var container = TLVBuilder()
        container.add(0x01, uint8: 0)   // fragmented MP4
        container.add(0x02, tlv: parameters)
        return container.data
    }

    /// `value` clamped to Int32, as its little-endian bit pattern (HAP-NodeJS `writeInt32LE`).
    private static func int32Bits(_ value: Int) -> UInt32 {
        UInt32(bitPattern: Int32(clamping: value))
    }

    private static func address(version isIPv6: Bool, ip: String, videoPort: UInt16, audioPort: UInt16) -> Data {
        var address = TLVBuilder()
        address.add(0x01, uint8: isIPv6 ? 1 : 0)
        address.add(0x02, string: ip)
        address.add(0x03, uint16LE: videoPort)
        address.add(0x04, uint16LE: audioPort)
        return address.data
    }

    private static func srtp(_ parameters: SRTPParameters) -> Data {
        var builder = TLVBuilder()
        builder.add(0x01, uint8: parameters.suite.rawValue)
        builder.add(0x02, parameters.masterKey)
        builder.add(0x03, parameters.masterSalt)
        return builder.data
    }

    private static func srtpParameters(_ reader: TLVReader) throws(CameraTLVError) -> SRTPParameters {
        guard let suite = reader.uint8(0x01).flatMap(SRTPCryptoSuite.init(rawValue:)) else { throw .malformed("SRTP crypto suite") }
        let key = reader.data(0x02) ?? Data()
        let salt = reader.data(0x03) ?? Data()
        if suite != .none, key.isEmpty || salt.isEmpty { throw .malformed("SRTP key or salt") }
        return SRTPParameters(suite: suite, masterKey: key, masterSalt: salt)
    }

    private static func reader(_ data: Data, _ what: String) throws(CameraTLVError) -> TLVReader {
        do {
            return try TLVReader(data)
        } catch {
            throw .malformed(what)
        }
    }

    private static func nested(_ reader: TLVReader, _ type: UInt8, _ what: String) throws(CameraTLVError) -> TLVReader {
        guard let value = reader.data(type) else { throw .malformed(what) }
        return try CameraTLV.reader(value, what)
    }

    private static func optionalNested(_ reader: TLVReader, _ type: UInt8, _ what: String) throws(CameraTLVError) -> TLVReader? {
        guard let value = reader.data(type) else { return nil }
        return try CameraTLV.reader(value, what)
    }

    private static func sessionID(_ reader: TLVReader) throws(CameraTLVError) -> UUID {
        guard let id = reader.data(0x01).flatMap(uuid) else { throw .malformed("session identifier") }
        return id
    }

    /// A 4-byte little-endian signed integer (shorter encodings accepted as unsigned).
    private static func int32(_ reader: TLVReader, _ type: UInt8, _ what: String) throws(CameraTLVError) -> Int {
        guard let bits = reader.uint32LE(type) else { throw .malformed(what) }
        let width = reader.data(type)?.count ?? 0
        return width == 4 ? Int(Int32(bitPattern: bits)) : Int(bits)
    }

    private static func videoResolution(_ attributes: TLVReader) throws(CameraTLVError) -> VideoResolution {
        guard let width = attributes.uint16LE(0x01), let height = attributes.uint16LE(0x02), let fps = attributes.uint8(0x03) else {
            throw .malformed("video attributes")
        }
        return VideoResolution(Int(width), Int(height), Int(fps))
    }

    private static func parseVideo(_ video: TLVReader, defaultMTU: Int, base: SelectedVideoParameters?) throws(CameraTLVError) -> SelectedVideoParameters {
        if let codec = video.uint8(0x01), codec != 0 { throw .malformed("video codec") }
        let parameters = try optionalNested(video, 0x02, "video codec parameters")
        let profile: H264Profile
        let level: H264Level
        if let parameters {
            guard let parsedProfile = parameters.uint8(0x01).flatMap(H264Profile.init(rawValue:)) else { throw .malformed("video profile") }
            guard let parsedLevel = parameters.uint8(0x02).flatMap(H264Level.init(rawValue:)) else { throw .malformed("video level") }
            profile = parsedProfile
            level = parsedLevel
        } else if let base {
            profile = base.profile
            level = base.level
        } else {
            throw .malformed("video codec parameters")
        }
        let resolution: VideoResolution
        if let attributes = try optionalNested(video, 0x03, "video attributes") {
            resolution = try videoResolution(attributes)
        } else if let base {
            resolution = base.resolution
        } else {
            throw .malformed("video attributes")
        }
        let rtp = try nested(video, 0x04, "video RTP parameters")
        guard let payloadType = rtp.uint8(0x01) ?? base?.payloadType else { throw .malformed("video payload type") }
        guard let ssrc = rtp.uint32LE(0x02) ?? base?.controllerSSRC else { throw .malformed("video SSRC") }
        guard let maxBitrate = rtp.uint16LE(0x03).map(Int.init) ?? base?.maxBitrateKbps else { throw .malformed("video max bitrate") }
        guard let rtcp = rtp.float32LE(0x04).map(Double.init) ?? base?.rtcpIntervalSeconds else { throw .malformed("video RTCP interval") }
        let mtu = rtp.uint16LE(0x05).map(Int.init) ?? base?.mtu ?? defaultMTU
        return SelectedVideoParameters(profile: profile, level: level, resolution: resolution, payloadType: payloadType & 0x7F,
                                       controllerSSRC: ssrc, maxBitrateKbps: maxBitrate, rtcpIntervalSeconds: rtcpInterval(rtcp), mtu: mtu)
    }

    private static func parseAudio(_ audio: TLVReader) throws(CameraTLVError) -> SelectedAudioParameters {
        guard let codec = audio.uint8(0x01).flatMap(StreamingAudioCodec.init(rawValue:)) else { throw .malformed("audio codec") }
        let parameters = try nested(audio, 0x02, "audio parameters")
        guard let channels = parameters.uint8(0x01) else { throw .malformed("audio channels") }
        guard let sampleRate = parameters.uint8(0x03).flatMap(StreamingSampleRate.init(rawValue:)) else { throw .malformed("audio sample rate") }
        guard let packetTime = parameters.uint8(0x04) else { throw .malformed("audio packet time") }
        let rtp = try nested(audio, 0x03, "audio RTP parameters")
        guard let payloadType = rtp.uint8(0x01), let ssrc = rtp.uint32LE(0x02), let maxBitrate = rtp.uint16LE(0x03),
              let rtcp = rtp.float32LE(0x04) else { throw .malformed("audio RTP parameters") }
        let comfortNoise = (audio.uint8(0x04) ?? 0) != 0
        let comfortNoisePayloadType = comfortNoise ? rtp.uint8(0x06) : nil
        return SelectedAudioParameters(codec: codec, channels: Int(channels), sampleRate: sampleRate, packetTimeMs: Int(packetTime),
                                       payloadType: payloadType & 0x7F, controllerSSRC: ssrc, maxBitrateKbps: Int(maxBitrate),
                                       rtcpIntervalSeconds: rtcpInterval(Double(rtcp)), comfortNoisePayloadType: comfortNoisePayloadType)
    }

    /// Controllers often send 0 ("seems to be always zero" — HAP-NodeJS); RTP's default is 0.5 s.
    private static func rtcpInterval(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 0.5
    }

    private static func encodeVideo(_ video: SelectedVideoParameters) -> Data {
        var parameters = TLVBuilder()
        parameters.add(0x01, uint8: video.profile.rawValue)
        parameters.add(0x02, uint8: video.level.rawValue)
        parameters.add(0x03, uint8: 0)
        var rtp = TLVBuilder()
        rtp.add(0x01, uint8: video.payloadType)
        rtp.add(0x02, uint32LE: video.controllerSSRC)
        rtp.add(0x03, uint16LE: UInt16(clamping: video.maxBitrateKbps))
        rtp.add(0x04, float32LE: Float(video.rtcpIntervalSeconds))
        rtp.add(0x05, uint16LE: UInt16(clamping: video.mtu))
        var builder = TLVBuilder()
        builder.add(0x01, uint8: 0)
        builder.add(0x02, tlv: parameters)
        builder.add(0x03, videoAttributes(video.resolution))
        builder.add(0x04, tlv: rtp)
        return builder.data
    }

    private static func encodeAudio(_ audio: SelectedAudioParameters) -> Data {
        var parameters = TLVBuilder()
        parameters.add(0x01, uint8: UInt8(clamping: audio.channels))
        parameters.add(0x02, uint8: 0)
        parameters.add(0x03, uint8: audio.sampleRate.rawValue)
        parameters.add(0x04, uint8: UInt8(clamping: audio.packetTimeMs))
        var rtp = TLVBuilder()
        rtp.add(0x01, uint8: audio.payloadType)
        rtp.add(0x02, uint32LE: audio.controllerSSRC)
        rtp.add(0x03, uint16LE: UInt16(clamping: audio.maxBitrateKbps))
        rtp.add(0x04, float32LE: Float(audio.rtcpIntervalSeconds))
        rtp.add(0x06, uint8: audio.comfortNoisePayloadType ?? 13)
        var builder = TLVBuilder()
        builder.add(0x01, uint8: audio.codec.rawValue)
        builder.add(0x02, tlv: parameters)
        builder.add(0x03, tlv: rtp)
        builder.add(0x04, uint8: audio.comfortNoisePayloadType == nil ? 0 : 1)
        return builder.data
    }
}
