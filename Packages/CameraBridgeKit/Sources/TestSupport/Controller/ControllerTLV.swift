// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// (TLV layouts of lib/camera/RTPStreamManagement.ts, lib/camera/RecordingManagement.ts and
// lib/datastream/DataStreamManagement.ts; research brief §3.5, §3.7.)

import Foundation
import HAPCore

/// Typed TLV8 values of the camera characteristics, as a HomeKit controller writes and reads them (research brief
/// §3.5, §3.7). Written independently of HAPCamera so the controller can check the accessory's encoders. Every type
/// encodes and decodes: tests use the encoders to build fake accessories and the decoders to read real ones.
///
/// List elements (profiles, levels, resolutions, sample rates, codec configurations, crypto suites, containers) are
/// separated by an empty `00 00` item, like HAP-NodeJS writes them; decoders accept them with or without separators.
public enum ControllerTLV {
    public struct Resolution: Sendable, Hashable, Codable, CustomStringConvertible {
        public var width: Int
        public var height: Int
        public var fps: Int
        public init(_ width: Int, _ height: Int, _ fps: Int) {
            self.width = width
            self.height = height
            self.fps = fps
        }

        public var description: String { "\(width)x\(height)@\(fps)" }

        func encoded() -> TLVBuilder {
            var attributes = TLVBuilder()
            attributes.add(0x01, uint16LE: UInt16(clamping: width))
            attributes.add(0x02, uint16LE: UInt16(clamping: height))
            attributes.add(0x03, uint8: UInt8(clamping: fps))
            return attributes
        }

        static func decode(_ data: Data) throws(ControllerTLVError) -> Resolution {
            let reader = try ControllerTLVError.reader(data, "video attributes")
            guard let width = reader.uint16LE(0x01), let height = reader.uint16LE(0x02), let fps = reader.uint8(0x03) else {
                throw .malformed("video attributes")
            }
            return Resolution(Int(width), Int(height), Int(fps))
        }
    }

    /// SRTP crypto suite and keys of one media stream (SetupEndpoints type 4/5, nested type 1/2/3).
    public struct SRTPKeys: Sendable, Hashable {
        /// 0 AES_CM_128_HMAC_SHA1_80, 1 AES_256_CM_HMAC_SHA1_80, 2 none.
        public var suite: UInt8
        public var masterKey: Data
        public var masterSalt: Data
        public init(suite: UInt8 = 0, masterKey: Data, masterSalt: Data) {
            self.suite = suite
            self.masterKey = masterKey
            self.masterSalt = masterSalt
        }

        /// Fresh AES_CM_128_HMAC_SHA1_80 keys: 16-byte key, 14-byte salt.
        public static func random() -> SRTPKeys {
            SRTPKeys(suite: 0, masterKey: randomBytes(16), masterSalt: randomBytes(14))
        }

        func encoded() -> TLVBuilder {
            var builder = TLVBuilder()
            builder.add(0x01, uint8: suite)
            builder.add(0x02, masterKey)
            builder.add(0x03, masterSalt)
            return builder
        }

        static func decode(_ data: Data) throws(ControllerTLVError) -> SRTPKeys {
            let reader = try ControllerTLVError.reader(data, "SRTP parameters")
            guard let suite = reader.uint8(0x01) else { throw .malformed("SRTP crypto suite") }
            return SRTPKeys(suite: suite, masterKey: reader.data(0x02) ?? Data(), masterSalt: reader.data(0x03) ?? Data())
        }
    }

    // MARK: - SetupEndpoints (0x118)

    /// Controller address + RTP ports (SetupEndpoints type 3; nested 1 version, 2 address, 3 video port, 4 audio port).
    public struct Address: Sendable, Hashable {
        public var isIPv6: Bool
        public var ip: String
        public var videoPort: UInt16
        public var audioPort: UInt16
        public init(isIPv6: Bool, ip: String, videoPort: UInt16, audioPort: UInt16) {
            self.isIPv6 = isIPv6
            self.ip = ip
            self.videoPort = videoPort
            self.audioPort = audioPort
        }

        func encoded() -> TLVBuilder {
            var builder = TLVBuilder()
            builder.add(0x01, uint8: isIPv6 ? 1 : 0)
            builder.add(0x02, string: ip)
            builder.add(0x03, uint16LE: videoPort)
            builder.add(0x04, uint16LE: audioPort)
            return builder
        }

        static func decode(_ data: Data) throws(ControllerTLVError) -> Address {
            let reader = try ControllerTLVError.reader(data, "address")
            guard let version = reader.uint8(0x01), let ip = reader.string(0x02), let video = reader.uint16LE(0x03),
                  let audio = reader.uint16LE(0x04) else {
                throw .malformed("address")
            }
            return Address(isIPv6: version == 1, ip: ip, videoPort: video, audioPort: audio)
        }
    }

    /// What the controller writes to SetupEndpoints.
    public struct SetupEndpointsRequest: Sendable, Hashable {
        public var sessionID: UUID
        public var controller: Address
        public var video: SRTPKeys
        public var audio: SRTPKeys
        public init(sessionID: UUID = UUID(), controller: Address, video: SRTPKeys, audio: SRTPKeys) {
            self.sessionID = sessionID
            self.controller = controller
            self.video = video
            self.audio = audio
        }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            builder.add(0x01, uuidBytes(sessionID))
            builder.add(0x03, tlv: controller.encoded())
            builder.add(0x04, tlv: video.encoded())
            builder.add(0x05, tlv: audio.encoded())
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SetupEndpointsRequest {
            let reader = try ControllerTLVError.reader(data, "SetupEndpoints")
            guard let session = reader.data(0x01), let sessionID = uuid(session) else { throw .malformed("session identifier") }
            guard let address = reader.data(0x03) else { throw .missing("controller address") }
            guard let video = reader.data(0x04), let audio = reader.data(0x05) else { throw .missing("SRTP parameters") }
            return SetupEndpointsRequest(sessionID: sessionID, controller: try Address.decode(address), video: try SRTPKeys.decode(video),
                                         audio: try SRTPKeys.decode(audio))
        }
    }

    /// SetupEndpoints read-back (status 0 success, 1 busy, 2 error). Busy/error responses carry only id and status.
    public struct SetupEndpointsResponse: Sendable, Hashable {
        public var sessionID: UUID
        public var status: UInt8
        public var accessory: Address?
        public var video: SRTPKeys?
        public var audio: SRTPKeys?
        public var videoSSRC: UInt32?
        public var audioSSRC: UInt32?
        public init(sessionID: UUID, status: UInt8, accessory: Address? = nil, video: SRTPKeys? = nil, audio: SRTPKeys? = nil,
                    videoSSRC: UInt32? = nil, audioSSRC: UInt32? = nil) {
            self.sessionID = sessionID
            self.status = status
            self.accessory = accessory
            self.video = video
            self.audio = audio
            self.videoSSRC = videoSSRC
            self.audioSSRC = audioSSRC
        }

        public var isSuccess: Bool { status == 0 }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            builder.add(0x01, uuidBytes(sessionID))
            builder.add(0x02, uint8: status)
            if let accessory { builder.add(0x03, tlv: accessory.encoded()) }
            if let video { builder.add(0x04, tlv: video.encoded()) }
            if let audio { builder.add(0x05, tlv: audio.encoded()) }
            if let videoSSRC { builder.add(0x06, uint32LE: videoSSRC) }
            if let audioSSRC { builder.add(0x07, uint32LE: audioSSRC) }
            return builder.data
        }

        /// Also accepts the accessory's default value `{2:2}` (no session id → nil UUID).
        public static func decode(_ data: Data) throws(ControllerTLVError) -> SetupEndpointsResponse {
            let reader = try ControllerTLVError.reader(data, "SetupEndpoints response")
            guard let status = reader.uint8(0x02) else { throw .missing("SetupEndpoints status") }
            var sessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            if let session = reader.data(0x01) {
                guard let parsed = uuid(session) else { throw .malformed("session identifier") }
                sessionID = parsed
            }
            var response = SetupEndpointsResponse(sessionID: sessionID, status: status)
            if let address = reader.data(0x03) { response.accessory = try Address.decode(address) }
            if let video = reader.data(0x04) { response.video = try SRTPKeys.decode(video) }
            if let audio = reader.data(0x05) { response.audio = try SRTPKeys.decode(audio) }
            if reader.data(0x06) != nil {
                guard let ssrc = reader.uint32LE(0x06) else { throw .malformed("video SSRC") }
                response.videoSSRC = ssrc
            }
            if reader.data(0x07) != nil {
                guard let ssrc = reader.uint32LE(0x07) else { throw .malformed("audio SSRC") }
                response.audioSSRC = ssrc
            }
            return response
        }
    }

    // MARK: - SelectedRTPStreamConfiguration (0x117)

    public enum StreamCommand: UInt8, Sendable, Hashable {
        case end = 0, start = 1, suspend = 2, resume = 3, reconfigure = 4
    }

    /// Selected video parameters (type 2): codec, {profile, level, packetization mode}, attributes,
    /// RTP {payload type, SSRC, max bitrate kbps u16, min RTCP interval f32 s, max MTU u16}.
    public struct SelectedVideo: Sendable, Hashable {
        public var codec: UInt8
        public var profile: UInt8
        public var level: UInt8
        public var packetizationMode: UInt8
        public var resolution: Resolution
        public var payloadType: UInt8
        public var ssrc: UInt32
        public var maxBitrateKbps: UInt16
        public var rtcpInterval: Float
        /// Omitted from the TLV when nil (accessory default: 1378 on IPv4, 1228 on IPv6).
        public var maxMTU: UInt16?
        public init(codec: UInt8 = 0, profile: UInt8 = 1, level: UInt8 = 2, packetizationMode: UInt8 = 0, resolution: Resolution,
                    payloadType: UInt8 = 99, ssrc: UInt32, maxBitrateKbps: UInt16 = 2000, rtcpInterval: Float = 0.5, maxMTU: UInt16? = 1378) {
            self.codec = codec
            self.profile = profile
            self.level = level
            self.packetizationMode = packetizationMode
            self.resolution = resolution
            self.payloadType = payloadType
            self.ssrc = ssrc
            self.maxBitrateKbps = maxBitrateKbps
            self.rtcpInterval = rtcpInterval
            self.maxMTU = maxMTU
        }

        func encoded() -> TLVBuilder {
            var parameters = TLVBuilder()
            parameters.add(0x01, uint8: profile)
            parameters.add(0x02, uint8: level)
            parameters.add(0x03, uint8: packetizationMode)
            var rtp = TLVBuilder()
            rtp.add(0x01, uint8: payloadType)
            rtp.add(0x02, uint32LE: ssrc)
            rtp.add(0x03, uint16LE: maxBitrateKbps)
            rtp.add(0x04, float32LE: rtcpInterval)
            if let maxMTU { rtp.add(0x05, uint16LE: maxMTU) }
            var builder = TLVBuilder()
            builder.add(0x01, uint8: codec)
            builder.add(0x02, tlv: parameters)
            builder.add(0x03, tlv: resolution.encoded())
            builder.add(0x04, tlv: rtp)
            return builder
        }

        static func decode(_ data: Data) throws(ControllerTLVError) -> SelectedVideo {
            let reader = try ControllerTLVError.reader(data, "selected video parameters")
            guard let codec = reader.uint8(0x01) else { throw .missing("video codec") }
            guard let parametersData = reader.data(0x02), let attributes = reader.data(0x03), let rtpData = reader.data(0x04) else {
                throw .missing("video parameters")
            }
            let parameters = try ControllerTLVError.reader(parametersData, "video codec parameters")
            let rtp = try ControllerTLVError.reader(rtpData, "video RTP parameters")
            guard let profile = parameters.uint8(0x01), let level = parameters.uint8(0x02) else { throw .malformed("video codec parameters") }
            guard let payloadType = rtp.uint8(0x01), let ssrc = rtp.uint32LE(0x02), let bitrate = rtp.uint16LE(0x03),
                  let interval = rtp.float32LE(0x04) else {
                throw .malformed("video RTP parameters")
            }
            return SelectedVideo(codec: codec, profile: profile, level: level, packetizationMode: parameters.uint8(0x03) ?? 0,
                                 resolution: try Resolution.decode(attributes), payloadType: payloadType, ssrc: ssrc, maxBitrateKbps: bitrate,
                                 rtcpInterval: interval, maxMTU: rtp.uint16LE(0x05))
        }
    }

    /// Selected audio parameters (type 3): codec, {channels, bitrate mode, sample rate, packet time ms},
    /// RTP {payload type, SSRC, max bitrate, min RTCP interval, comfort-noise payload type}, comfort noise flag.
    public struct SelectedAudio: Sendable, Hashable {
        /// 0 PCMU, 1 PCMA, 2 AAC-ELD, 3 Opus, …
        public var codec: UInt8
        public var channels: UInt8
        /// 0 variable, 1 constant.
        public var bitrateMode: UInt8
        /// 0 = 8 kHz, 1 = 16 kHz, 2 = 24 kHz.
        public var sampleRate: UInt8
        public var packetTimeMs: UInt8
        public var payloadType: UInt8
        public var ssrc: UInt32
        public var maxBitrateKbps: UInt16
        public var rtcpInterval: Float
        public var comfortNoisePayloadType: UInt8
        public var comfortNoise: Bool
        public init(codec: UInt8 = 3, channels: UInt8 = 1, bitrateMode: UInt8 = 0, sampleRate: UInt8 = 2, packetTimeMs: UInt8 = 20,
                    payloadType: UInt8 = 110, ssrc: UInt32, maxBitrateKbps: UInt16 = 24, rtcpInterval: Float = 5,
                    comfortNoisePayloadType: UInt8 = 13, comfortNoise: Bool = false) {
            self.codec = codec
            self.channels = channels
            self.bitrateMode = bitrateMode
            self.sampleRate = sampleRate
            self.packetTimeMs = packetTimeMs
            self.payloadType = payloadType
            self.ssrc = ssrc
            self.maxBitrateKbps = maxBitrateKbps
            self.rtcpInterval = rtcpInterval
            self.comfortNoisePayloadType = comfortNoisePayloadType
            self.comfortNoise = comfortNoise
        }

        /// Sample rate in Hz (8000 / 16000 / 24000; 0 for unknown codes).
        public var sampleRateHz: Int {
            switch sampleRate {
            case 0: 8000
            case 1: 16_000
            case 2: 24_000
            default: 0
            }
        }

        func encoded() -> TLVBuilder {
            var parameters = TLVBuilder()
            parameters.add(0x01, uint8: channels)
            parameters.add(0x02, uint8: bitrateMode)
            parameters.add(0x03, uint8: sampleRate)
            parameters.add(0x04, uint8: packetTimeMs)
            var rtp = TLVBuilder()
            rtp.add(0x01, uint8: payloadType)
            rtp.add(0x02, uint32LE: ssrc)
            rtp.add(0x03, uint16LE: maxBitrateKbps)
            rtp.add(0x04, float32LE: rtcpInterval)
            rtp.add(0x06, uint8: comfortNoisePayloadType)
            var builder = TLVBuilder()
            builder.add(0x01, uint8: codec)
            builder.add(0x02, tlv: parameters)
            builder.add(0x03, tlv: rtp)
            builder.add(0x04, uint8: comfortNoise ? 1 : 0)
            return builder
        }

        static func decode(_ data: Data) throws(ControllerTLVError) -> SelectedAudio {
            let reader = try ControllerTLVError.reader(data, "selected audio parameters")
            guard let codec = reader.uint8(0x01) else { throw .missing("audio codec") }
            guard let parametersData = reader.data(0x02), let rtpData = reader.data(0x03) else { throw .missing("audio parameters") }
            let parameters = try ControllerTLVError.reader(parametersData, "audio codec parameters")
            let rtp = try ControllerTLVError.reader(rtpData, "audio RTP parameters")
            guard let channels = parameters.uint8(0x01), let mode = parameters.uint8(0x02), let rate = parameters.uint8(0x03),
                  let packetTime = parameters.uint8(0x04) else {
                throw .malformed("audio codec parameters")
            }
            guard let payloadType = rtp.uint8(0x01), let ssrc = rtp.uint32LE(0x02), let bitrate = rtp.uint16LE(0x03),
                  let interval = rtp.float32LE(0x04) else {
                throw .malformed("audio RTP parameters")
            }
            return SelectedAudio(codec: codec, channels: channels, bitrateMode: mode, sampleRate: rate, packetTimeMs: packetTime,
                                 payloadType: payloadType, ssrc: ssrc, maxBitrateKbps: bitrate, rtcpInterval: interval,
                                 comfortNoisePayloadType: rtp.uint8(0x06) ?? 13, comfortNoise: reader.uint8(0x04).map { $0 != 0 } ?? false)
        }
    }

    /// What the controller writes to SelectedRTPStreamConfiguration: session control {id, command} + parameters.
    /// `start` carries video and audio, `reconfigure` video only, `end`/`suspend`/`resume` neither.
    public struct SelectedRTPStreamConfiguration: Sendable, Hashable {
        public var sessionID: UUID
        public var command: StreamCommand
        public var video: SelectedVideo?
        public var audio: SelectedAudio?
        public init(sessionID: UUID, command: StreamCommand, video: SelectedVideo? = nil, audio: SelectedAudio? = nil) {
            self.sessionID = sessionID
            self.command = command
            self.video = video
            self.audio = audio
        }

        public func encoded() -> Data {
            var control = TLVBuilder()
            control.add(0x01, uuidBytes(sessionID))
            control.add(0x02, uint8: command.rawValue)
            var builder = TLVBuilder()
            builder.add(0x01, tlv: control)
            if let video { builder.add(0x02, tlv: video.encoded()) }
            if let audio { builder.add(0x03, tlv: audio.encoded()) }
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SelectedRTPStreamConfiguration {
            let reader = try ControllerTLVError.reader(data, "SelectedRTPStreamConfiguration")
            guard let controlData = reader.data(0x01) else { throw .missing("session control") }
            let control = try ControllerTLVError.reader(controlData, "session control")
            guard let session = control.data(0x01), let sessionID = uuid(session) else { throw .malformed("session identifier") }
            guard let raw = control.uint8(0x02), let command = StreamCommand(rawValue: raw) else { throw .malformed("session command") }
            var configuration = SelectedRTPStreamConfiguration(sessionID: sessionID, command: command)
            if let video = reader.data(0x02) { configuration.video = try SelectedVideo.decode(video) }
            if let audio = reader.data(0x03) { configuration.audio = try SelectedAudio.decode(audio) }
            return configuration
        }
    }

    // MARK: - Supported streaming configurations (0x114, 0x115, 0x116, 0x120)

    /// One video codec configuration: codec type, {profiles, levels, packetization modes}, resolutions.
    public struct VideoCodecConfiguration: Sendable, Hashable {
        public var codec: UInt8
        public var profiles: [UInt8]
        public var levels: [UInt8]
        /// Streaming only (recording configurations have none).
        public var packetizationModes: [UInt8]
        public var resolutions: [Resolution]
        public init(codec: UInt8 = 0, profiles: [UInt8], levels: [UInt8], packetizationModes: [UInt8] = [0], resolutions: [Resolution]) {
            self.codec = codec
            self.profiles = profiles
            self.levels = levels
            self.packetizationModes = packetizationModes
            self.resolutions = resolutions
        }

        func encoded() -> TLVBuilder {
            var parameters = TLVBuilder()
            addList(&parameters, type: 0x01, profiles.map { Data([$0]) })
            addList(&parameters, type: 0x02, levels.map { Data([$0]) })
            addList(&parameters, type: 0x03, packetizationModes.map { Data([$0]) })
            var builder = TLVBuilder()
            builder.add(0x01, uint8: codec)
            builder.add(0x02, tlv: parameters)
            addList(&builder, type: 0x03, resolutions.map { $0.encoded().data })
            return builder
        }

        static func decode(_ data: Data) throws(ControllerTLVError) -> VideoCodecConfiguration {
            let reader = try ControllerTLVError.reader(data, "video codec configuration")
            guard let codec = reader.uint8(0x01) else { throw .missing("video codec type") }
            guard let parametersData = reader.data(0x02) else { throw .missing("video codec parameters") }
            let parameters = try ControllerTLVError.reader(parametersData, "video codec parameters")
            var resolutions: [Resolution] = []
            for attributes in reader.all(0x03) { resolutions.append(try Resolution.decode(attributes)) }
            return VideoCodecConfiguration(codec: codec, profiles: try bytes(parameters.all(0x01), "profile"),
                                           levels: try bytes(parameters.all(0x02), "level"),
                                           packetizationModes: try bytes(parameters.all(0x03), "packetization mode"), resolutions: resolutions)
        }
    }

    /// SupportedVideoStreamConfiguration: a list of video codec configurations (type 1).
    public struct SupportedVideoStreamConfiguration: Sendable, Hashable {
        public var codecs: [VideoCodecConfiguration]
        public init(codecs: [VideoCodecConfiguration]) { self.codecs = codecs }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            addList(&builder, type: 0x01, codecs.map { $0.encoded().data })
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SupportedVideoStreamConfiguration {
            let reader = try ControllerTLVError.reader(data, "SupportedVideoStreamConfiguration")
            var codecs: [VideoCodecConfiguration] = []
            for codec in reader.all(0x01) { codecs.append(try VideoCodecConfiguration.decode(codec)) }
            return SupportedVideoStreamConfiguration(codecs: codecs)
        }
    }

    /// One audio codec configuration: codec type, {channels, bitrate mode, sample rates}.
    public struct AudioCodecConfiguration: Sendable, Hashable {
        public var codec: UInt8
        public var channels: UInt8
        public var bitrateMode: UInt8
        public var sampleRates: [UInt8]
        public init(codec: UInt8, channels: UInt8 = 1, bitrateMode: UInt8 = 0, sampleRates: [UInt8]) {
            self.codec = codec
            self.channels = channels
            self.bitrateMode = bitrateMode
            self.sampleRates = sampleRates
        }

        func encoded() -> TLVBuilder {
            var parameters = TLVBuilder()
            parameters.add(0x01, uint8: channels)
            parameters.add(0x02, uint8: bitrateMode)
            addList(&parameters, type: 0x03, sampleRates.map { Data([$0]) })
            var builder = TLVBuilder()
            builder.add(0x01, uint8: codec)
            builder.add(0x02, tlv: parameters)
            return builder
        }

        static func decode(_ data: Data) throws(ControllerTLVError) -> AudioCodecConfiguration {
            let reader = try ControllerTLVError.reader(data, "audio codec configuration")
            guard let codec = reader.uint8(0x01) else { throw .missing("audio codec type") }
            guard let parametersData = reader.data(0x02) else { throw .missing("audio codec parameters") }
            let parameters = try ControllerTLVError.reader(parametersData, "audio codec parameters")
            guard let channels = parameters.uint8(0x01), let mode = parameters.uint8(0x02) else { throw .malformed("audio codec parameters") }
            return AudioCodecConfiguration(codec: codec, channels: channels, bitrateMode: mode,
                                           sampleRates: try bytes(parameters.all(0x03), "sample rate"))
        }
    }

    /// SupportedAudioStreamConfiguration: codec configurations (type 1) + comfort noise (type 2).
    public struct SupportedAudioStreamConfiguration: Sendable, Hashable {
        public var codecs: [AudioCodecConfiguration]
        public var comfortNoise: Bool
        public init(codecs: [AudioCodecConfiguration], comfortNoise: Bool = false) {
            self.codecs = codecs
            self.comfortNoise = comfortNoise
        }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            addList(&builder, type: 0x01, codecs.map { $0.encoded().data })
            builder.add(0x02, uint8: comfortNoise ? 1 : 0)
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SupportedAudioStreamConfiguration {
            let reader = try ControllerTLVError.reader(data, "SupportedAudioStreamConfiguration")
            var codecs: [AudioCodecConfiguration] = []
            for codec in reader.all(0x01) { codecs.append(try AudioCodecConfiguration.decode(codec)) }
            return SupportedAudioStreamConfiguration(codecs: codecs, comfortNoise: (reader.uint8(0x02) ?? 0) != 0)
        }
    }

    /// SupportedRTPConfiguration: crypto suites (type 2).
    public struct SupportedRTPConfiguration: Sendable, Hashable {
        public var cryptoSuites: [UInt8]
        public init(cryptoSuites: [UInt8]) { self.cryptoSuites = cryptoSuites }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            addList(&builder, type: 0x02, cryptoSuites.map { Data([$0]) })
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SupportedRTPConfiguration {
            let reader = try ControllerTLVError.reader(data, "SupportedRTPConfiguration")
            return SupportedRTPConfiguration(cryptoSuites: try bytes(reader.all(0x02), "crypto suite"))
        }
    }

    /// StreamingStatus: 0 available, 1 in use, 2 unavailable.
    public struct StreamingStatus: Sendable, Hashable {
        public var status: UInt8
        public init(status: UInt8) { self.status = status }

        public static let available = StreamingStatus(status: 0)
        public static let inUse = StreamingStatus(status: 1)
        public static let unavailable = StreamingStatus(status: 2)

        public func encoded() -> Data {
            var builder = TLVBuilder()
            builder.add(0x01, uint8: status)
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> StreamingStatus {
            let reader = try ControllerTLVError.reader(data, "StreamingStatus")
            guard let status = reader.uint8(0x01) else { throw .missing("streaming status") }
            return StreamingStatus(status: status)
        }
    }

    // MARK: - Recording (0x205, 0x206, 0x207, 0x209)

    /// Media container configuration: type (0 = fragmented MP4) + {fragment length ms}.
    public struct MediaContainer: Sendable, Hashable {
        public var type: UInt8
        public var fragmentLengthMs: UInt32
        public init(type: UInt8 = 0, fragmentLengthMs: UInt32) {
            self.type = type
            self.fragmentLengthMs = fragmentLengthMs
        }

        func encoded() -> TLVBuilder {
            var parameters = TLVBuilder()
            parameters.add(0x01, uint32LE: fragmentLengthMs)
            var builder = TLVBuilder()
            builder.add(0x01, uint8: type)
            builder.add(0x02, tlv: parameters)
            return builder
        }

        static func decode(_ data: Data) throws(ControllerTLVError) -> MediaContainer {
            let reader = try ControllerTLVError.reader(data, "media container configuration")
            guard let type = reader.uint8(0x01), let parametersData = reader.data(0x02) else { throw .malformed("media container configuration") }
            let parameters = try ControllerTLVError.reader(parametersData, "media container parameters")
            guard let fragment = parameters.uint32LE(0x01) else { throw .malformed("fragment length") }
            return MediaContainer(type: type, fragmentLengthMs: fragment)
        }
    }

    /// SupportedCameraRecordingConfiguration: prebuffer ms (u32), event triggers (u64: bit 0 motion, bit 1 doorbell),
    /// media containers.
    public struct SupportedCameraRecordingConfiguration: Sendable, Hashable {
        public var prebufferLengthMs: UInt32
        public var eventTriggers: UInt64
        public var containers: [MediaContainer]
        public init(prebufferLengthMs: UInt32, eventTriggers: UInt64, containers: [MediaContainer]) {
            self.prebufferLengthMs = prebufferLengthMs
            self.eventTriggers = eventTriggers
            self.containers = containers
        }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            builder.add(0x01, uint32LE: prebufferLengthMs)
            builder.add(0x02, uint64LE: eventTriggers)
            addList(&builder, type: 0x03, containers.map { $0.encoded().data })
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SupportedCameraRecordingConfiguration {
            let reader = try ControllerTLVError.reader(data, "SupportedCameraRecordingConfiguration")
            guard let prebuffer = reader.uint32LE(0x01), let triggers = reader.uint64LE(0x02) else {
                throw .malformed("SupportedCameraRecordingConfiguration")
            }
            var containers: [MediaContainer] = []
            for container in reader.all(0x03) { containers.append(try MediaContainer.decode(container)) }
            return SupportedCameraRecordingConfiguration(prebufferLengthMs: prebuffer, eventTriggers: triggers, containers: containers)
        }
    }

    /// SupportedVideoRecordingConfiguration: video codec configurations (no packetization modes).
    public struct SupportedVideoRecordingConfiguration: Sendable, Hashable {
        public var codecs: [VideoCodecConfiguration]
        public init(codecs: [VideoCodecConfiguration]) { self.codecs = codecs }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            let codecs = self.codecs.map { codec in
                var codec = codec
                codec.packetizationModes = []
                return codec.encoded().data
            }
            addList(&builder, type: 0x01, codecs)
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SupportedVideoRecordingConfiguration {
            let reader = try ControllerTLVError.reader(data, "SupportedVideoRecordingConfiguration")
            var codecs: [VideoCodecConfiguration] = []
            for codec in reader.all(0x01) { codecs.append(try VideoCodecConfiguration.decode(codec)) }
            return SupportedVideoRecordingConfiguration(codecs: codecs)
        }
    }

    /// SupportedAudioRecordingConfiguration: audio codec configurations (0 AAC-LC, 1 AAC-ELD; sample rates 0 = 8 …
    /// 5 = 48 kHz).
    public struct SupportedAudioRecordingConfiguration: Sendable, Hashable {
        public var codecs: [AudioCodecConfiguration]
        public init(codecs: [AudioCodecConfiguration]) { self.codecs = codecs }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            addList(&builder, type: 0x01, codecs.map { $0.encoded().data })
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SupportedAudioRecordingConfiguration {
            let reader = try ControllerTLVError.reader(data, "SupportedAudioRecordingConfiguration")
            var codecs: [AudioCodecConfiguration] = []
            for codec in reader.all(0x01) { codecs.append(try AudioCodecConfiguration.decode(codec)) }
            return SupportedAudioRecordingConfiguration(codecs: codecs)
        }
    }

    /// What a hub writes to SelectedCameraRecordingConfiguration (brief §3.7):
    /// `1 {1 prebuffer, 2 triggers, 3 container}, 2 {1 codec, 2 {1 profile, 2 level, 3 bitrate, 4 iFrameInterval}, 3 attrs},
    /// 3 {1 codec, 2 {1 channels, 2 bitrate mode, 3 sample rate, 4 max bitrate}}`.
    public struct SelectedCameraRecordingConfiguration: Sendable, Hashable {
        public var prebufferLengthMs: UInt32
        public var eventTriggers: UInt64
        public var container: MediaContainer
        public var videoCodec: UInt8
        public var videoProfile: UInt8
        public var videoLevel: UInt8
        public var videoBitrateKbps: UInt32
        public var iFrameIntervalMs: UInt32
        public var resolution: Resolution
        public var audioCodec: UInt8
        public var audioChannels: UInt8
        public var audioBitrateMode: UInt8
        public var audioSampleRate: UInt8
        public var audioMaxBitrateKbps: UInt32

        public init(prebufferLengthMs: UInt32 = 4000, eventTriggers: UInt64 = 1, container: MediaContainer = MediaContainer(fragmentLengthMs: 4000),
                    videoCodec: UInt8 = 0, videoProfile: UInt8 = 1, videoLevel: UInt8 = 2, videoBitrateKbps: UInt32 = 2000,
                    iFrameIntervalMs: UInt32 = 4000, resolution: Resolution = Resolution(1920, 1080, 30), audioCodec: UInt8 = 0,
                    audioChannels: UInt8 = 1, audioBitrateMode: UInt8 = 0, audioSampleRate: UInt8 = 3, audioMaxBitrateKbps: UInt32 = 64) {
            self.prebufferLengthMs = prebufferLengthMs
            self.eventTriggers = eventTriggers
            self.container = container
            self.videoCodec = videoCodec
            self.videoProfile = videoProfile
            self.videoLevel = videoLevel
            self.videoBitrateKbps = videoBitrateKbps
            self.iFrameIntervalMs = iFrameIntervalMs
            self.resolution = resolution
            self.audioCodec = audioCodec
            self.audioChannels = audioChannels
            self.audioBitrateMode = audioBitrateMode
            self.audioSampleRate = audioSampleRate
            self.audioMaxBitrateKbps = audioMaxBitrateKbps
        }

        public func encoded() -> Data {
            var recording = TLVBuilder()
            recording.add(0x01, uint32LE: prebufferLengthMs)
            recording.add(0x02, uint64LE: eventTriggers)
            recording.add(0x03, tlv: container.encoded())
            var videoParameters = TLVBuilder()
            videoParameters.add(0x01, uint8: videoProfile)
            videoParameters.add(0x02, uint8: videoLevel)
            videoParameters.add(0x03, uint32LE: videoBitrateKbps)
            videoParameters.add(0x04, uint32LE: iFrameIntervalMs)
            var video = TLVBuilder()
            video.add(0x01, uint8: videoCodec)
            video.add(0x02, tlv: videoParameters)
            video.add(0x03, tlv: resolution.encoded())
            var audioParameters = TLVBuilder()
            audioParameters.add(0x01, uint8: audioChannels)
            audioParameters.add(0x02, uint8: audioBitrateMode)
            audioParameters.add(0x03, uint8: audioSampleRate)
            audioParameters.add(0x04, uint32LE: audioMaxBitrateKbps)
            var audio = TLVBuilder()
            audio.add(0x01, uint8: audioCodec)
            audio.add(0x02, tlv: audioParameters)
            var builder = TLVBuilder()
            builder.add(0x01, tlv: recording)
            builder.add(0x02, tlv: video)
            builder.add(0x03, tlv: audio)
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SelectedCameraRecordingConfiguration {
            let reader = try ControllerTLVError.reader(data, "SelectedCameraRecordingConfiguration")
            guard let recordingData = reader.data(0x01), let videoData = reader.data(0x02), let audioData = reader.data(0x03) else {
                throw .missing("recording, video or audio configuration")
            }
            let recording = try ControllerTLVError.reader(recordingData, "selected recording configuration")
            guard let prebuffer = recording.uint32LE(0x01), let triggers = recording.uint64LE(0x02), let containerData = recording.data(0x03) else {
                throw .malformed("selected recording configuration")
            }
            let video = try ControllerTLVError.reader(videoData, "selected video configuration")
            guard let videoCodec = video.uint8(0x01), let videoParametersData = video.data(0x02), let attributes = video.data(0x03) else {
                throw .malformed("selected video configuration")
            }
            let videoParameters = try ControllerTLVError.reader(videoParametersData, "selected video parameters")
            guard let profile = videoParameters.uint8(0x01), let level = videoParameters.uint8(0x02), let bitrate = videoParameters.uint32LE(0x03),
                  let iFrame = videoParameters.uint32LE(0x04) else {
                throw .malformed("selected video parameters")
            }
            let audio = try ControllerTLVError.reader(audioData, "selected audio configuration")
            guard let audioCodec = audio.uint8(0x01), let audioParametersData = audio.data(0x02) else {
                throw .malformed("selected audio configuration")
            }
            let audioParameters = try ControllerTLVError.reader(audioParametersData, "selected audio parameters")
            guard let channels = audioParameters.uint8(0x01), let mode = audioParameters.uint8(0x02), let rate = audioParameters.uint8(0x03),
                  let maxBitrate = audioParameters.uint32LE(0x04) else {
                throw .malformed("selected audio parameters")
            }
            return SelectedCameraRecordingConfiguration(
                prebufferLengthMs: prebuffer, eventTriggers: triggers, container: try MediaContainer.decode(containerData), videoCodec: videoCodec,
                videoProfile: profile, videoLevel: level, videoBitrateKbps: bitrate, iFrameIntervalMs: iFrame,
                resolution: try Resolution.decode(attributes), audioCodec: audioCodec, audioChannels: channels, audioBitrateMode: mode,
                audioSampleRate: rate, audioMaxBitrateKbps: maxBitrate)
        }
    }

    // MARK: - Data stream (0x130, 0x131)

    /// SetupDataStreamTransport write: command (0 start session), transport (0 HDS over TCP), controllerKeySalt (32).
    public struct SetupDataStreamTransportRequest: Sendable, Hashable {
        public var command: UInt8
        public var transportType: UInt8
        public var controllerKeySalt: Data
        public init(command: UInt8 = 0, transportType: UInt8 = 0, controllerKeySalt: Data = randomBytes(32)) {
            self.command = command
            self.transportType = transportType
            self.controllerKeySalt = controllerKeySalt
        }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            builder.add(0x01, uint8: command)
            builder.add(0x02, uint8: transportType)
            builder.add(0x03, controllerKeySalt)
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SetupDataStreamTransportRequest {
            let reader = try ControllerTLVError.reader(data, "SetupDataStreamTransport")
            guard let command = reader.uint8(0x01), let transport = reader.uint8(0x02), let salt = reader.data(0x03) else {
                throw .malformed("SetupDataStreamTransport")
            }
            return SetupDataStreamTransportRequest(command: command, transportType: transport, controllerKeySalt: salt)
        }
    }

    /// SetupDataStreamTransport write-response: status (0 success, 1 generic error, 2 busy), {TCP port}, accessoryKeySalt.
    public struct SetupDataStreamTransportResponse: Sendable, Hashable {
        public var status: UInt8
        public var tcpPort: UInt16?
        public var accessoryKeySalt: Data?
        public init(status: UInt8, tcpPort: UInt16? = nil, accessoryKeySalt: Data? = nil) {
            self.status = status
            self.tcpPort = tcpPort
            self.accessoryKeySalt = accessoryKeySalt
        }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            builder.add(0x01, uint8: status)
            if let tcpPort {
                var parameters = TLVBuilder()
                parameters.add(0x01, uint16LE: tcpPort)
                builder.add(0x02, tlv: parameters)
            }
            if let accessoryKeySalt { builder.add(0x03, accessoryKeySalt) }
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SetupDataStreamTransportResponse {
            let reader = try ControllerTLVError.reader(data, "SetupDataStreamTransport response")
            guard let status = reader.uint8(0x01) else { throw .missing("SetupDataStreamTransport status") }
            var response = SetupDataStreamTransportResponse(status: status, accessoryKeySalt: reader.data(0x03))
            if let parametersData = reader.data(0x02) {
                let parameters = try ControllerTLVError.reader(parametersData, "transport session parameters")
                guard let port = parameters.uint16LE(0x01) else { throw .malformed("TCP port") }
                response.tcpPort = port
            }
            return response
        }
    }

    /// SupportedDataStreamTransportConfiguration: transfer transport configurations, each {1 transport type}.
    public struct SupportedDataStreamTransportConfiguration: Sendable, Hashable {
        public var transportTypes: [UInt8]
        public init(transportTypes: [UInt8]) { self.transportTypes = transportTypes }

        public func encoded() -> Data {
            var builder = TLVBuilder()
            let configurations = transportTypes.map { type -> Data in
                var configuration = TLVBuilder()
                configuration.add(0x01, uint8: type)
                return configuration.data
            }
            addList(&builder, type: 0x01, configurations)
            return builder.data
        }

        public static func decode(_ data: Data) throws(ControllerTLVError) -> SupportedDataStreamTransportConfiguration {
            let reader = try ControllerTLVError.reader(data, "SupportedDataStreamTransportConfiguration")
            var types: [UInt8] = []
            for configuration in reader.all(0x01) {
                let nested = try ControllerTLVError.reader(configuration, "transfer transport configuration")
                guard let type = nested.uint8(0x01) else { throw .malformed("transport type") }
                types.append(type)
            }
            return SupportedDataStreamTransportConfiguration(transportTypes: types)
        }
    }

    // MARK: - Helpers

    /// `count` random bytes (SRTP keys, key salts).
    public static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// The 16 bytes of a UUID in the order HAP-NodeJS `uuid.write` produces (the textual order).
    public static func uuidBytes(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    /// Parses 16 bytes as a UUID; nil for any other length.
    public static func uuid(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Adds list elements of one type separated by `00 00`.
    static func addList(_ builder: inout TLVBuilder, type: UInt8, _ values: [Data]) {
        for (index, value) in values.enumerated() {
            if index > 0 { builder.addSeparator(type: 0x00) }
            builder.add(type, value)
        }
    }

    /// One-byte list values (profiles, levels, sample rates, suites).
    static func bytes(_ values: [Data], _ what: String) throws(ControllerTLVError) -> [UInt8] {
        var out: [UInt8] = []
        for value in values {
            guard value.count == 1, let byte = value.first else { throw .malformed(what) }
            out.append(byte)
        }
        return out
    }
}

public enum ControllerTLVError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The bytes are not valid TLV8.
    case invalidTLV(String)
    case missing(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .invalidTLV(let what): "invalid TLV8 in \(what)"
        case .missing(let what): "missing \(what)"
        case .malformed(let what): "malformed \(what)"
        }
    }

    static func reader(_ data: Data, _ what: String) throws(ControllerTLVError) -> TLVReader {
        do {
            return try TLVReader(data)
        } catch {
            throw .invalidTLV(what)
        }
    }
}
