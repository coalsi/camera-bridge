import BridgeSupport
import Foundation
import HAP
import HAPCamera
import HAPCore
import HDS
import MediaCore
import RTP
import Synchronization
import TestSupport
import Testing
#if os(macOS)
import PlatformApple
#endif

/// Self-tests of TestSupport's HomeKit controller (plan task W2-2; `swift test --filter IntegrationTests.ControllerSelfTests`):
/// typed camera TLVs against the research brief §3.5/§3.7 goldens and the W1-9 HAP-NodeJS fixture, dataSend
/// reassembly, H.264 depacketization, the SRTP receiver against RTP's LiveStreamSession, the controller / HDS client /
/// cbctl against a plain HAP accessory that stands in for a camera (negative cases, knobs), and — once W2-1's
/// `CameraController` is present — the controller end to end against a real HAPCamera accessory with fake delegates
/// (`HAPCameraAccessoryTests`, enabled automatically when `install` adds the camera services). Loopback only; nothing
/// is advertised. Every suite is nested here so the plan's filter selects all of them.
@Suite struct ControllerSelfTests {}

private func hex(_ string: String) throws -> Data { try #require(Data(hex: string)) }

private func bytes(_ range: ClosedRange<UInt8>) -> Data { Data(range) }

private func randomData(_ count: Int) -> Data { ControllerTLV.randomBytes(count) }

// MARK: - Goldens (research brief §3.5, §3.7, §3.8 and the W1-9 camera fixture)

/// Brief §3.5 / §3.7 golden values (HAP-NodeJS output).
private enum BriefGolden {
    static let supportedVideoStream = "013e010100021d0101000000010101000001010202010000000201010000020102030100030b010280070202380403011e0000030b010200050202d00203011e"
    static let supportedRTP = "020100"
    static let supportedCameraRecording = "0104a00f000002080100000000000000030b01010002060104a00f0000"
    static let supportedVideoRecording = "01180101000206010102020102030b010280070202380403011e"
    static let supportedDataStreamTransport = "0103010100"
    /// v1 streaming audio (Opus 16/24 kHz, mono, variable bitrate, no comfort noise) from the camera fixture.
    static let supportedAudioStream = "0113010103020e0101010201000301010000030102020100"
    /// v1 camera recording options (camera fixture "v1 camera").
    static let v1VideoRecording = "013b010100021a0101000000010101000001010202010000000201010000020102030b010200050202d00203011e0000030b010280070202380403011e"
    static let v1AudioRecording = "010e0101000209010101020100030103"
}

struct ControllerTLVFixture: Decodable {
    struct AudioCodecOption: Decodable {
        var codec: UInt8
        var sampleRates: [UInt8]
        var channels: UInt8
        var bitrateMode: UInt8
    }

    struct StreamingOptions: Decodable {
        var resolutions: [[Int]]
        var profiles: [UInt8]
        var levels: [UInt8]
        var audioCodecs: [AudioCodecOption]
        var comfortNoise: Bool
        var cryptoSuites: [UInt8]
    }

    struct Streaming: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var decodeOnly: Bool?
        var options: StreamingOptions
        var supportedVideoStreamConfiguration: String
        var supportedAudioStreamConfiguration: String
        var supportedRTPConfiguration: String
        var testDescription: String { name }
    }

    struct RecordingOptions: Decodable {
        var prebufferLengthMs: UInt32
        var fragmentLengthMs: UInt32
        var resolutions: [[Int]]
        var profiles: [UInt8]
        var levels: [UInt8]
        var audioCodec: UInt8
        var audioSampleRates: [UInt8]
        var audioChannels: UInt8
        var audioBitrateMode: UInt8
        var eventTriggers: UInt64
    }

    struct Recording: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var options: RecordingOptions
        var supportedCameraRecordingConfiguration: String
        var supportedVideoRecordingConfiguration: String
        var supportedAudioRecordingConfiguration: String
        var testDescription: String { name }
    }

    struct SelectedResolution: Decodable {
        var width: Int
        var height: Int
        var fps: Int
    }

    struct SelectedConfiguration: Decodable {
        var prebufferLengthMs: UInt32
        var eventTriggers: UInt64
        var fragmentLengthMs: UInt32
        var videoProfile: UInt8
        var videoLevel: UInt8
        var videoBitrateKbps: UInt32
        var iFrameIntervalMs: UInt32
        var resolution: SelectedResolution
        var audioCodec: UInt8
        var audioChannels: UInt8
        var audioSampleRate: UInt8
        var audioMaxBitrateKbps: UInt32
    }

    struct Selected: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var encoded: String
        var configuration: SelectedConfiguration
        var testDescription: String { name }
    }

    var streaming: [Streaming]
    var recording: [Recording]
    var selectedRecordingConfiguration: [Selected]
    var dataStreamTransport: [String: String]
    var streamingStatus: [String: String]
    var setupEndpointsDefault: String

    /// HAPCamera's fixture (W1-9, generated by HAP-NodeJS), read in place via #filePath.
    static let shared: ControllerTLVFixture? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HAPCameraTests/Fixtures/camera-tlv.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ControllerTLVFixture.self, from: data)
    }()
}

private func resolutions(_ list: [[Int]]) -> [ControllerTLV.Resolution] {
    list.compactMap { $0.count == 3 ? ControllerTLV.Resolution($0[0], $0[1], $0[2]) : nil }
}

extension ControllerSelfTests {
    @Suite struct ControllerTLVGoldenTests {
        @Test func supportedVideoStreamConfigurationBriefGolden() throws {
            let decoded = try ControllerTLV.SupportedVideoStreamConfiguration.decode(try hex(BriefGolden.supportedVideoStream))
            let codec = try #require(decoded.codecs.first)
            #expect(decoded.codecs.count == 1)
            #expect(codec.codec == 0)
            #expect(codec.profiles == [0, 1, 2])
            #expect(codec.levels == [0, 1, 2])
            #expect(codec.packetizationModes == [0])
            #expect(codec.resolutions == [ControllerTLV.Resolution(1920, 1080, 30), ControllerTLV.Resolution(1280, 720, 30)])
            #expect(decoded.encoded().hexString == BriefGolden.supportedVideoStream)
        }

        @Test func supportedRTPAndDataStreamGoldens() throws {
            let rtp = try ControllerTLV.SupportedRTPConfiguration.decode(try hex(BriefGolden.supportedRTP))
            #expect(rtp.cryptoSuites == [0])
            #expect(rtp.encoded().hexString == BriefGolden.supportedRTP)
            let transport = try ControllerTLV.SupportedDataStreamTransportConfiguration.decode(try hex(BriefGolden.supportedDataStreamTransport))
            #expect(transport.transportTypes == [0])
            #expect(transport.encoded().hexString == BriefGolden.supportedDataStreamTransport)
        }

        @Test func supportedRecordingBriefGoldens() throws {
            let camera = try ControllerTLV.SupportedCameraRecordingConfiguration.decode(try hex(BriefGolden.supportedCameraRecording))
            #expect(camera.prebufferLengthMs == 4000)
            #expect(camera.eventTriggers == 1)
            #expect(camera.containers == [ControllerTLV.MediaContainer(type: 0, fragmentLengthMs: 4000)])
            #expect(camera.encoded().hexString == BriefGolden.supportedCameraRecording)

            let video = try ControllerTLV.SupportedVideoRecordingConfiguration.decode(try hex(BriefGolden.supportedVideoRecording))
            let codec = try #require(video.codecs.first)
            #expect(codec.profiles == [2])
            #expect(codec.levels == [2])
            #expect(codec.packetizationModes.isEmpty)
            #expect(codec.resolutions == [ControllerTLV.Resolution(1920, 1080, 30)])
            #expect(video.encoded().hexString == BriefGolden.supportedVideoRecording)
        }

        @Test func fixtureIsPresent() throws {
            let fixture = try #require(ControllerTLVFixture.shared)
            #expect(fixture.streaming.count >= 5)
            #expect(fixture.recording.count >= 3)
            #expect(fixture.selectedRecordingConfiguration.count >= 2)
        }

        @Test(arguments: ControllerTLVFixture.shared?.streaming ?? [])
        func streamingFixture(_ testCase: ControllerTLVFixture.Streaming) throws {
            let video = try ControllerTLV.SupportedVideoStreamConfiguration.decode(try hex(testCase.supportedVideoStreamConfiguration))
            let audio = try ControllerTLV.SupportedAudioStreamConfiguration.decode(try hex(testCase.supportedAudioStreamConfiguration))
            let rtp = try ControllerTLV.SupportedRTPConfiguration.decode(try hex(testCase.supportedRTPConfiguration))
            let options = testCase.options
            let expectedVideo = ControllerTLV.VideoCodecConfiguration(profiles: options.profiles, levels: options.levels,
                                                                      resolutions: resolutions(options.resolutions))
            let expectedAudio = options.audioCodecs.map {
                ControllerTLV.AudioCodecConfiguration(codec: $0.codec, channels: $0.channels, bitrateMode: $0.bitrateMode, sampleRates: $0.sampleRates)
            }
            #expect(video.codecs == [expectedVideo])
            #expect(audio.codecs == expectedAudio)
            #expect(audio.comfortNoise == options.comfortNoise)
            #expect(rtp.cryptoSuites == options.cryptoSuites)
            // Encoding from the options reproduces HAP-NodeJS byte for byte (list delimiters included).
            #expect(ControllerTLV.SupportedVideoStreamConfiguration(codecs: [expectedVideo]).encoded().hexString == testCase.supportedVideoStreamConfiguration)
            #expect(ControllerTLV.SupportedAudioStreamConfiguration(codecs: expectedAudio, comfortNoise: options.comfortNoise).encoded().hexString
                    == testCase.supportedAudioStreamConfiguration)
            #expect(ControllerTLV.SupportedRTPConfiguration(cryptoSuites: options.cryptoSuites).encoded().hexString == testCase.supportedRTPConfiguration)
        }

        @Test(arguments: ControllerTLVFixture.shared?.recording ?? [])
        func recordingFixture(_ testCase: ControllerTLVFixture.Recording) throws {
            let options = testCase.options
            let camera = try ControllerTLV.SupportedCameraRecordingConfiguration.decode(try hex(testCase.supportedCameraRecordingConfiguration))
            #expect(camera == ControllerTLV.SupportedCameraRecordingConfiguration(
                prebufferLengthMs: options.prebufferLengthMs, eventTriggers: options.eventTriggers,
                containers: [ControllerTLV.MediaContainer(fragmentLengthMs: options.fragmentLengthMs)]))
            #expect(camera.encoded().hexString == testCase.supportedCameraRecordingConfiguration)

            let video = try ControllerTLV.SupportedVideoRecordingConfiguration.decode(try hex(testCase.supportedVideoRecordingConfiguration))
            let expectedVideo = ControllerTLV.VideoCodecConfiguration(profiles: options.profiles, levels: options.levels, packetizationModes: [],
                                                                      resolutions: resolutions(options.resolutions))
            #expect(video.codecs == [expectedVideo])
            #expect(ControllerTLV.SupportedVideoRecordingConfiguration(codecs: [expectedVideo]).encoded().hexString == testCase.supportedVideoRecordingConfiguration)

            let audio = try ControllerTLV.SupportedAudioRecordingConfiguration.decode(try hex(testCase.supportedAudioRecordingConfiguration))
            let expectedAudio = ControllerTLV.AudioCodecConfiguration(codec: options.audioCodec, channels: options.audioChannels,
                                                                      bitrateMode: options.audioBitrateMode, sampleRates: options.audioSampleRates)
            #expect(audio.codecs == [expectedAudio])
            #expect(ControllerTLV.SupportedAudioRecordingConfiguration(codecs: [expectedAudio]).encoded().hexString == testCase.supportedAudioRecordingConfiguration)
        }

        /// The hub's SelectedCameraRecordingConfiguration write (brief §3.7 layout) encodes byte-exactly.
        @Test(arguments: ControllerTLVFixture.shared?.selectedRecordingConfiguration ?? [])
        func selectedRecordingFixture(_ testCase: ControllerTLVFixture.Selected) throws {
            let c = testCase.configuration
            let expected = ControllerTLV.SelectedCameraRecordingConfiguration(
                prebufferLengthMs: c.prebufferLengthMs, eventTriggers: c.eventTriggers, container: ControllerTLV.MediaContainer(fragmentLengthMs: c.fragmentLengthMs),
                videoCodec: 0, videoProfile: c.videoProfile, videoLevel: c.videoLevel, videoBitrateKbps: c.videoBitrateKbps, iFrameIntervalMs: c.iFrameIntervalMs,
                resolution: ControllerTLV.Resolution(c.resolution.width, c.resolution.height, c.resolution.fps), audioCodec: c.audioCodec,
                audioChannels: c.audioChannels, audioBitrateMode: 0, audioSampleRate: c.audioSampleRate, audioMaxBitrateKbps: c.audioMaxBitrateKbps)
            #expect(expected.encoded().hexString == testCase.encoded)
            #expect(try ControllerTLV.SelectedCameraRecordingConfiguration.decode(try hex(testCase.encoded)) == expected)
        }

        @Test func streamingStatusAndDefaultEndpoints() throws {
            let fixture = try #require(ControllerTLVFixture.shared)
            #expect(try ControllerTLV.StreamingStatus.decode(try hex(try #require(fixture.streamingStatus["available"]))) == .available)
            #expect(try ControllerTLV.StreamingStatus.decode(try hex(try #require(fixture.streamingStatus["inUse"]))) == .inUse)
            #expect(try ControllerTLV.StreamingStatus.decode(try hex(try #require(fixture.streamingStatus["unavailable"]))) == .unavailable)
            #expect(ControllerTLV.StreamingStatus.inUse.encoded().hexString == fixture.streamingStatus["inUse"])
            #expect(fixture.dataStreamTransport["supportedDataStreamTransportConfiguration"] == BriefGolden.supportedDataStreamTransport)
            // The accessory's SetupEndpoints value before any write is {2:2} (brief §3.5).
            let initial = try ControllerTLV.SetupEndpointsResponse.decode(try hex(fixture.setupEndpointsDefault))
            #expect(initial.status == 2)
            #expect(!initial.isSuccess)
            #expect(initial.accessory == nil)
        }

        private static let session = UUID(uuid: (0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF))

        /// SetupEndpoints write, assembled by hand from the brief §3.5 layout.
        @Test func setupEndpointsRequestLayout() throws {
            let request = ControllerTLV.SetupEndpointsRequest(
                sessionID: Self.session, controller: ControllerTLV.Address(isIPv6: false, ip: "127.0.0.1", videoPort: 5000, audioPort: 5002),
                video: ControllerTLV.SRTPKeys(masterKey: bytes(0x00...0x0F), masterSalt: bytes(0x10...0x1D)),
                audio: ControllerTLV.SRTPKeys(masterKey: bytes(0x20...0x2F), masterSalt: bytes(0x30...0x3D)))
            let expected = "0110" + "00112233445566778899aabbccddeeff"
                + "0316" + "010100" + "0209" + "3132372e302e302e31" + "03028813" + "04028a13"
                + "0425" + "010100" + "0210" + "000102030405060708090a0b0c0d0e0f" + "030e" + "101112131415161718191a1b1c1d"
                + "0525" + "010100" + "0210" + "202122232425262728292a2b2c2d2e2f" + "030e" + "303132333435363738393a3b3c3d"
            #expect(request.encoded().hexString == expected)
            #expect(try ControllerTLV.SetupEndpointsRequest.decode(try hex(expected)) == request)
        }

        @Test func setupEndpointsResponseDecodes() throws {
            let response = "0110" + "00112233445566778899aabbccddeeff" + "020100"
                + "0316" + "010100" + "0209" + "3132372e302e302e31" + "03027017" + "04027217"
                + "0425" + "010100" + "0210" + "000102030405060708090a0b0c0d0e0f" + "030e" + "101112131415161718191a1b1c1d"
                + "0525" + "010100" + "0210" + "202122232425262728292a2b2c2d2e2f" + "030e" + "303132333435363738393a3b3c3d"
                + "0604" + "efbeadde" + "0704" + "0dd0fe0f"
            let decoded = try ControllerTLV.SetupEndpointsResponse.decode(try hex(response))
            #expect(decoded.sessionID == Self.session)
            #expect(decoded.isSuccess)
            #expect(decoded.accessory == ControllerTLV.Address(isIPv6: false, ip: "127.0.0.1", videoPort: 6000, audioPort: 6002))
            #expect(decoded.video == ControllerTLV.SRTPKeys(masterKey: bytes(0x00...0x0F), masterSalt: bytes(0x10...0x1D)))
            #expect(decoded.audio?.masterKey == bytes(0x20...0x2F))
            #expect(decoded.videoSSRC == 0xDEAD_BEEF)
            #expect(decoded.audioSSRC == 0x0FFE_D00D)
            #expect(decoded.encoded().hexString == response)
        }

        /// SelectedRTPStreamConfiguration start, assembled by hand from the brief §3.5 layout (and HAP-NodeJS's parser).
        @Test func selectedStreamStartLayout() throws {
            let configuration = ControllerTLV.SelectedRTPStreamConfiguration(
                sessionID: Self.session, command: .start,
                video: ControllerTLV.SelectedVideo(profile: 1, level: 2, resolution: ControllerTLV.Resolution(1280, 720, 30), payloadType: 99,
                                                   ssrc: 0x1122_3344, maxBitrateKbps: 2000, rtcpInterval: 0.5, maxMTU: 1378),
                audio: ControllerTLV.SelectedAudio(codec: 3, channels: 1, bitrateMode: 0, sampleRate: 2, packetTimeMs: 20, payloadType: 110,
                                                   ssrc: 0x5566_7788, maxBitrateKbps: 24, rtcpInterval: 5, comfortNoisePayloadType: 13))
            let expected = "0115" + "0110" + "00112233445566778899aabbccddeeff" + "020101"
                + "0234" + "010100" + "0209" + "010101" + "020102" + "030100" + "030b" + "01020005" + "0202d002" + "03011e"
                + "0417" + "010163" + "020444332211" + "0302d007" + "04040000003f" + "05026205"
                + "032c" + "010103" + "020c" + "010101" + "020100" + "030102" + "040114"
                + "0316" + "01016e" + "020488776655" + "03021800" + "04040000a040" + "06010d" + "040100"
            #expect(configuration.encoded().hexString == expected)
            #expect(try ControllerTLV.SelectedRTPStreamConfiguration.decode(try hex(expected)) == configuration)

            let end = ControllerTLV.SelectedRTPStreamConfiguration(sessionID: Self.session, command: .end)
            #expect(end.encoded().hexString == "0115" + "0110" + "00112233445566778899aabbccddeeff" + "020100")
        }

        @Test func setupDataStreamTransportLayout() throws {
            let salt = Data(0x00...0x1F)
            let request = ControllerTLV.SetupDataStreamTransportRequest(controllerKeySalt: salt)
            #expect(request.encoded().hexString == "010100" + "020100" + "0320" + salt.hexString)
            let response = try ControllerTLV.SetupDataStreamTransportResponse.decode(try hex("010100" + "0204" + "010250c3" + "0320" + salt.hexString))
            #expect(response.status == 0)
            #expect(response.tcpPort == 50_000)
            #expect(response.accessoryKeySalt == salt)
            let busy = try ControllerTLV.SetupDataStreamTransportResponse.decode(try hex("010102"))
            #expect(busy.status == 2)
            #expect(busy.tcpPort == nil)
        }

        @Test func malformedValuesThrowTypedErrors() {
            #expect(throws: ControllerTLVError.invalidTLV("SetupEndpoints response")) { try ControllerTLV.SetupEndpointsResponse.decode(Data([0x01, 0x05, 0x00])) }
            #expect(throws: ControllerTLVError.missing("SetupEndpoints status")) { try ControllerTLV.SetupEndpointsResponse.decode(Data([0x01, 0x00])) }
            #expect(throws: ControllerTLVError.malformed("video attributes")) {
                try ControllerTLV.SupportedVideoStreamConfiguration.decode(try hex("010a010100020003030101ff"))
            }
            #expect(throws: ControllerTLVError.malformed("session command")) {
                try ControllerTLV.SelectedRTPStreamConfiguration.decode(try hex("0115" + "0110" + "00112233445566778899aabbccddeeff" + "020109"))
            }
        }

        @Test func hubLikeRecordingSelection() throws {
            let camera = try ControllerTLV.SupportedCameraRecordingConfiguration.decode(try hex(BriefGolden.supportedCameraRecording))
            let video = try ControllerTLV.SupportedVideoRecordingConfiguration.decode(try hex(BriefGolden.v1VideoRecording))
            let audio = try ControllerTLV.SupportedAudioRecordingConfiguration.decode(try hex(BriefGolden.v1AudioRecording))
            let selection = try ControllerTLV.SelectedCameraRecordingConfiguration.preferred(camera: camera, video: video, audio: audio)
            #expect(selection.resolution == ControllerTLV.Resolution(1920, 1080, 30))
            #expect(selection.videoProfile == 1)
            #expect(selection.videoLevel == 2)
            #expect(selection.iFrameIntervalMs == 4000)
            #expect(selection.audioSampleRate == 3)
            #expect(selection.eventTriggers == 1)
            #expect(selection.prebufferLengthMs == 4000)
        }

        @Test func accessoryDatabaseTypeMatching() {
            #expect(HAPAccessoryDatabase.shortType("00000022-0000-1000-8000-0026BB765291") == "22")
            #expect(HAPAccessoryDatabase.shortType("0000021A-0000-1000-8000-0026bb765291") == "21A")
            #expect(HAPAccessoryDatabase.shortType("22") == "22")
            #expect(HAPAccessoryDatabase.shortType("0x110") == "110")
            #expect(HostPort(parsing: "127.0.0.1:51826") == HostPort(host: "127.0.0.1", port: 51826))
            #expect(HostPort(parsing: "[::1]:8080") == HostPort(host: "::1", port: 8080))
            #expect(HostPort(parsing: "[::1]:8080")?.description == "[::1]:8080")
            #expect(HostPort(parsing: "::1:8080") == nil)
            #expect(HostPort(parsing: "host:0") == nil)
            #expect(HostPort(parsing: "host") == nil)
        }
    }
}

// MARK: - dataSend reassembly

/// `dataSend/data` event bodies exactly as HAP-NodeJS's CameraRecordingStream chunks packets (brief §3.8).
private func dataEvents(streamID: Int64, packets: [Data], chunkSize: Int = 0x40000, endOfStream: Bool = true) -> [HDSDictionary] {
    var events: [HDSDictionary] = []
    for (index, packet) in packets.enumerated() {
        var offset = 0
        var chunk: Int64 = 1
        while offset < packet.count {
            let end = min(offset + chunkSize, packet.count)
            let isLast = end == packet.count
            var metadata = HDSDictionary([("dataType", .string(index == 0 ? "mediaInitialization" : "mediaFragment")),
                                          ("dataSequenceNumber", .int(Int64(index + 1))), ("dataChunkSequenceNumber", .int(chunk)),
                                          ("isLastDataChunk", .bool(isLast))])
            if chunk == 1 { metadata["dataTotalSize"] = .int(Int64(packet.count)) }
            var body = HDSDictionary([("streamId", .int(streamID)),
                                      ("packets", .array([.dictionary(HDSDictionary([("data", .data(Data(packet[offset..<end]))),
                                                                                     ("metadata", .dictionary(metadata))]))]))])
            if isLast && index == packets.count - 1 && endOfStream { body["endOfStream"] = .bool(true) }
            events.append(body)
            offset = end
            chunk += 1
        }
    }
    return events
}

private func metadataEvent(stream: Int64 = 1, type: String = "mediaInitialization", sequence: Int64 = 1, chunk: Int64 = 1, isLast: Bool = true,
                           total: Int64? = nil, data: Data = Data([1, 2, 3]), endOfStream: Bool? = nil) -> HDSDictionary {
    var metadata = HDSDictionary([("dataType", .string(type)), ("dataSequenceNumber", .int(sequence)), ("dataChunkSequenceNumber", .int(chunk)),
                                  ("isLastDataChunk", .bool(isLast))])
    if let total { metadata["dataTotalSize"] = .int(total) }
    var body = HDSDictionary([("streamId", .int(stream)),
                              ("packets", .array([.dictionary(HDSDictionary([("data", .data(data)), ("metadata", .dictionary(metadata))]))]))])
    if let endOfStream { body["endOfStream"] = .bool(endOfStream) }
    return body
}

extension ControllerSelfTests {
    @Suite struct DataSendReassemblerTests {
        @Test func reassemblesChunkedPacketsLikeHAPNodeJS() throws {
            let packets = [randomData(1200), randomData(600_000), randomData(10), randomData(0x40000)]
            var reassembler = DataSendReassembler(streamID: 7)
            var out: [DataSendReassembler.Packet] = []
            for event in dataEvents(streamID: 7, packets: packets) { out += try reassembler.consume(event) }
            #expect(out.map(\.data) == packets)
            #expect(out.map(\.chunkCount) == [1, 3, 1, 1])
            #expect(out.map(\.sequenceNumber) == [1, 2, 3, 4])
            #expect(out.first?.isInitialization == true)
            #expect(reassembler.endOfStream)
            #expect(reassembler.chunksReceived == 6)
            #expect(!reassembler.hasPartialPacket)
        }

        @Test func rejectsProtocolViolations() throws {
            var reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.unexpectedDataType(sequence: 1, got: "mediaFragment")) {
                try reassembler.consume(metadataEvent(type: "mediaFragment"))
            }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.wrongStream(expected: 1, got: 2)) { try reassembler.consume(metadataEvent(stream: 2)) }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.sequenceOutOfOrder(expected: 1, got: 2)) {
                try reassembler.consume(metadataEvent(type: "mediaFragment", sequence: 2))
            }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.chunkOutOfOrder(sequence: 1, expected: 1, got: 2)) { try reassembler.consume(metadataEvent(chunk: 2)) }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.totalSizeMismatch(sequence: 1, declared: 4, actual: 3)) { try reassembler.consume(metadataEvent(total: 4)) }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.chunkTooLarge(sequence: 1, chunk: 1, size: 0x40001)) {
                try reassembler.consume(metadataEvent(data: randomData(0x40001)))
            }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.endOfStreamBeforeLastChunk(sequence: 1)) {
                try reassembler.consume(metadataEvent(isLast: false, total: 6, endOfStream: true))
            }
            reassembler = DataSendReassembler(streamID: 1)
            _ = try reassembler.consume(metadataEvent(isLast: false, total: 6))
            #expect(throws: DataSendReassembler.Violation.totalSizeOnLaterChunk(sequence: 1, chunk: 2)) {
                try reassembler.consume(metadataEvent(chunk: 2, total: 6))
            }
            reassembler = DataSendReassembler(streamID: 1)
            _ = try reassembler.consume(metadataEvent(total: 3, endOfStream: true))
            #expect(throws: DataSendReassembler.Violation.dataAfterEndOfStream) {
                try reassembler.consume(metadataEvent(type: "mediaFragment", sequence: 2, total: 3))
            }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.malformed("packets")) { try reassembler.consume(HDSDictionary([("streamId", .int(1))])) }
        }

        /// Brief §3.8 / HAP-NodeJS: `dataTotalSize` is on chunk 1 of every packet (the oracle must not accept its absence).
        @Test func requiresTotalSizeOnTheFirstChunk() throws {
            var reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.missingTotalSize(sequence: 1)) { try reassembler.consume(metadataEvent()) }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.missingTotalSize(sequence: 1)) { try reassembler.consume(metadataEvent(isLast: false)) }
            // A later packet without it fails the same way.
            reassembler = DataSendReassembler(streamID: 1)
            _ = try reassembler.consume(metadataEvent(total: 3))
            #expect(throws: DataSendReassembler.Violation.missingTotalSize(sequence: 2)) {
                try reassembler.consume(metadataEvent(type: "mediaFragment", sequence: 2))
            }
        }

        /// A packet that outgrows its declared size fails at that chunk, not only at the last one (bounds memory too).
        @Test func failsAsSoonAsAPacketOutgrowsItsDeclaredSize() throws {
            var reassembler = DataSendReassembler(streamID: 1)
            _ = try reassembler.consume(metadataEvent(isLast: false, total: 4, data: Data([1, 2, 3])))
            #expect(throws: DataSendReassembler.Violation.totalSizeMismatch(sequence: 1, declared: 4, actual: 6)) {
                try reassembler.consume(metadataEvent(chunk: 2, isLast: false, data: Data([4, 5, 6])))
            }
            reassembler = DataSendReassembler(streamID: 1)
            #expect(throws: DataSendReassembler.Violation.totalSizeMismatch(sequence: 1, declared: 2, actual: 3)) {
                try reassembler.consume(metadataEvent(isLast: false, total: 2))
            }
            #expect(throws: DataSendReassembler.Violation.malformed("dataTotalSize")) {
                var fresh = DataSendReassembler(streamID: 1)
                _ = try fresh.consume(metadataEvent(total: -1))
            }
        }

        @Test func toleratesAbsentOrFalseEndOfStreamAndNullTotals() throws {
            var reassembler = DataSendReassembler(streamID: 1)
            var packets = try reassembler.consume(metadataEvent(total: 3, endOfStream: false))
            var event = metadataEvent(type: "mediaFragment", sequence: 2, isLast: false, total: 4, data: Data([9, 9]))
            packets += try reassembler.consume(event)
            event = metadataEvent(type: "mediaFragment", sequence: 2, chunk: 2, data: Data([8, 8]))
            if case .array(var list)? = event["packets"], case .dictionary(var packet)? = list.first, case .dictionary(var metadata)? = packet["metadata"] {
                metadata["dataTotalSize"] = .null
                packet["metadata"] = .dictionary(metadata)
                list[0] = .dictionary(packet)
                event["packets"] = .array(list)
            }
            packets += try reassembler.consume(event)
            #expect(packets.map(\.data) == [Data([1, 2, 3]), Data([9, 9, 8, 8])])
            #expect(!reassembler.endOfStream)
        }
    }
}

// MARK: - H.264 depacketization

private let testSPS = Data([0x67, 0x4D, 0x00, 0x28, 0x95, 0xA0, 0x14, 0x01, 0x6E, 0x40])
private let testPPS = Data([0x68, 0xEE, 0x3C, 0x80])
private let testFormat = VideoFormat(codec: .h264, width: 1280, height: 720, parameterSets: [testSPS, testPPS])

private func testFrame(index: Int, keyframe: Bool, size: Int) -> EncodedVideoFrame {
    EncodedVideoFrame(format: testFormat, nalUnits: [SyntheticNALSource.videoNAL(index: index, isKeyframe: keyframe, size: size, codec: .h264)],
                      isKeyframe: keyframe, pts: MediaTime(value: Int64(index) * 3000, timescale: 90_000), wallClock: Date())
}

extension ControllerSelfTests {
    @Suite struct H264AccessUnitAssemblerTests {
        @Test func reassemblesSTAPAndFUAAndSingleNALUnits() {
            var packetizer = H264Packetizer(payloadType: 99, ssrc: 42, maxPacketSize: 1200, initialSequence: 65_530)
            var assembler = H264AccessUnitAssembler()
            let frames = [testFrame(index: 0, keyframe: true, size: 9000), testFrame(index: 1, keyframe: false, size: 700),
                          testFrame(index: 2, keyframe: false, size: 3000)]
            var units: [ReceivedVideoFrame] = []
            for frame in frames {
                for packet in packetizer.packetize(frame, rtpTimestamp: UInt32(truncatingIfNeeded: frame.pts.value)) { units += assembler.push(packet) }
            }
            #expect(units.count == 3)
            #expect(units.allSatisfy { $0.isComplete })
            #expect(units.allSatisfy { $0.hadMarker })
            #expect(units[0].nalUnits == [testSPS, testPPS] + frames[0].nalUnits)
            #expect(units[0].isKeyframe)
            #expect(units[0].sps == testSPS && units[0].pps == testPPS)
            #expect(units[0].sliceNALUnits == frames[0].nalUnits)
            #expect(units[0].packetCount > 7)
            #expect(units[1].nalUnits == frames[1].nalUnits)
            #expect(!units[1].isKeyframe)
            #expect(units[2].nalUnits == frames[2].nalUnits)
            #expect(units[2].rtpTimestamp == 6000)
            #expect(assembler.sequenceGaps == 0)
            #expect(units[0].annexB.prefix(5) == Data([0, 0, 0, 1, 0x67]))
        }

        @Test func lossMarksTheUnitIncomplete() {
            var packetizer = H264Packetizer(payloadType: 99, ssrc: 42, maxPacketSize: 1200)
            var assembler = H264AccessUnitAssembler()
            var packets = packetizer.packetize(testFrame(index: 0, keyframe: true, size: 6000), rtpTimestamp: 0)
            packets.remove(at: 2)   // an FU-A fragment in the middle
            var units = packets.flatMap { assembler.push($0) }
            units += packetizer.packetize(testFrame(index: 1, keyframe: false, size: 500), rtpTimestamp: 3000).flatMap { assembler.push($0) }
            #expect(units.count == 2)
            #expect(!units[0].isComplete)
            #expect(units[1].isComplete)
            #expect(assembler.sequenceGaps == 1)
        }

        /// Losing the marker packet of a unit: that unit is truncated (not complete), and the gap cannot be attributed
        /// to one side of the timestamp change, so the next unit is flagged too.
        @Test func lossOfTheMarkerPacketFlagsBothNeighbours() {
            func packet(_ sequence: UInt16, _ timestamp: UInt32, marker: Bool, nal: UInt8) -> RTPPacket {
                RTPPacket(marker: marker, payloadType: 99, sequenceNumber: sequence, timestamp: timestamp, ssrc: 1, payload: Data([nal, 1, 2, 3]))
            }
            // Unit 0: two IDR slices sent as single NAL packets; the second one (with the marker) is lost.
            var assembler = H264AccessUnitAssembler()
            var units = assembler.push(packet(1, 0, marker: false, nal: 0x65))
            // (sequence 2, the marker packet of unit 0, never arrives)
            units += assembler.push(packet(3, 3000, marker: true, nal: 0x41))
            units += assembler.push(packet(4, 6000, marker: true, nal: 0x41))
            #expect(units.count == 3)
            #expect(units.map(\.isComplete) == [false, false, true])
            #expect(units[0].hadMarker == false)
            #expect(units[0].isKeyframe)
            #expect(units[0].nalUnits.count == 1)
            #expect(assembler.sequenceGaps == 1)

            // A gap after a unit that ended with its marker only concerns the new unit.
            assembler = H264AccessUnitAssembler()
            units = assembler.push(packet(1, 0, marker: true, nal: 0x65))
            units += assembler.push(packet(3, 6000, marker: true, nal: 0x41))
            #expect(units.map(\.isComplete) == [true, false])
        }

        @Test func timestampChangeEndsAUnitWithoutMarker() {
            var assembler = H264AccessUnitAssembler()
            let first = RTPPacket(marker: false, payloadType: 99, sequenceNumber: 1, timestamp: 100, ssrc: 1, payload: Data([0x41, 1, 2]))
            let second = RTPPacket(marker: true, payloadType: 99, sequenceNumber: 2, timestamp: 200, ssrc: 1, payload: Data([0x41, 3, 4]))
            let none = assembler.push(first)
            #expect(none.isEmpty)
            let units = assembler.push(second)
            #expect(units.count == 2)
            #expect(units[0].hadMarker == false && units[0].nalUnits == [Data([0x41, 1, 2])])
            #expect(units[1].hadMarker && units[1].rtpTimestamp == 200)
            let rest = assembler.flush()
            #expect(rest == nil)
        }
    }
}

#if os(macOS)

// MARK: - Media generators (a fake camera's live source)

/// Real-time H.264-shaped video (keyframe every `gop` frames) and Opus-sized audio, as `LiveStreamSession` input.
private func liveMedia(fps: Int = 30, gop: Int = 30, audioRate: Int = 24_000, packetTimeMs: Int = 20)
    -> (video: AsyncStream<EncodedVideoFrame>, audio: AsyncStream<EncodedAudioFrame>, tasks: [Task<Void, Never>]) {
    let (video, videoContinuation) = AsyncStream.makeStream(of: EncodedVideoFrame.self)
    let (audio, audioContinuation) = AsyncStream.makeStream(of: EncodedAudioFrame.self)
    let videoTask = Task {
        let clock = ContinuousClock()
        let start = clock.now
        var index = 0
        while !Task.isCancelled {
            try? await clock.sleep(until: start + .milliseconds(Int64(index * 1000 / fps)))
            let keyframe = index % gop == 0
            videoContinuation.yield(EncodedVideoFrame(format: testFormat,
                                                      nalUnits: [SyntheticNALSource.videoNAL(index: index, isKeyframe: keyframe, size: keyframe ? 12_000 : 900, codec: .h264)],
                                                      isKeyframe: keyframe, pts: MediaTime(value: Int64(index * 90_000 / fps), timescale: 90_000),
                                                      wallClock: Date()))
            index += 1
        }
        videoContinuation.finish()
    }
    let audioTask = Task {
        let clock = ContinuousClock()
        let start = clock.now
        let samples = audioRate * packetTimeMs / 1000
        let format = AudioFormat(codec: .opus, sampleRate: audioRate, channels: 1)
        var index = 0
        while !Task.isCancelled {
            try? await clock.sleep(until: start + .milliseconds(Int64(index * packetTimeMs)))
            audioContinuation.yield(EncodedAudioFrame(format: format, data: Data([0xFC, UInt8(truncatingIfNeeded: index)]) + Data(repeating: 0x55, count: 58),
                                                      pts: MediaTime(value: Int64(index * samples), timescale: Int32(audioRate)),
                                                      sampleCount: samples, wallClock: Date()))
            index += 1
        }
        audioContinuation.finish()
    }
    return (video, audio, [videoTask, audioTask])
}

// MARK: - SRTP receiver against RTP's LiveStreamSession

extension ControllerSelfTests {
    @Suite struct SRTPTestReceiverTests {
        @Test(.timeLimit(.minutes(1)))
        func receivesDecryptsAndTalksBack() async throws {
            let receiver = try await SRTPTestReceiver.start()
            let videoSocket = try UDPSocket.bind(host: "127.0.0.1")
            let audioSocket = try UDPSocket.bind(host: "127.0.0.1")
            let session = LiveStreamSession(
                controller: SocketAddress(host: "127.0.0.1", port: 0), videoPort: receiver.videoPort, audioPort: receiver.audioPort,
                videoSocket: videoSocket, audioSocket: audioSocket,
                video: LiveVideoParameters(payloadType: 99, ssrc: 0xA1A1_A1A1, srtpKey: receiver.videoKeys.masterKey, srtpSalt: receiver.videoKeys.masterSalt,
                                           rtcpInterval: .milliseconds(200)),
                audio: LiveAudioParameters(codec: .opus, payloadType: 110, ssrc: 0xB2B2_B2B2, srtpKey: receiver.audioKeys.masterKey,
                                           srtpSalt: receiver.audioKeys.masterSalt, rtpClockRate: 24_000, packetTime: .milliseconds(20),
                                           rtcpInterval: .milliseconds(200)),
                controllerTimeout: .seconds(1))
            await receiver.connect(to: SRTPTestReceiver.Peer(host: "127.0.0.1", videoPort: videoSocket.localPort, audioPort: audioSocket.localPort,
                                                             videoSSRC: 0xA1A1_A1A1, audioSSRC: 0xB2B2_B2B2, controllerVideoSSRC: 0x1234,
                                                             controllerAudioSSRC: 0x5678, videoPayloadType: 99, audioPayloadType: 110),
                                   keepaliveInterval: .milliseconds(200))

            let media = liveMedia()
            defer { media.tasks.forEach { $0.cancel() } }
            await session.start(video: media.video, audio: media.audio)
            let pli = Task { () -> Bool in
                for await _ in session.keyframeRequests { return true }
                return false
            }
            let returned = Task { () -> [EncodedAudioFrame] in
                var frames: [EncodedAudioFrame] = []
                for await frame in session.returnAudio {
                    frames.append(frame)
                    if frames.count == 3 { break }
                }
                return frames
            }

            var frames: [ReceivedVideoFrame] = []
            for await frame in receiver.videoFrames {
                frames.append(frame)
                if frames.count == 45 { break }
            }
            // First unit is the keyframe with in-band SPS/PPS (STAP-A); every unit is whole and in order.
            #expect(frames.first?.isKeyframe == true)
            #expect(frames.first?.sps == testSPS)
            #expect(frames.first?.pps == testPPS)
            #expect(frames.allSatisfy { $0.isComplete })
            let indices = frames.compactMap { $0.sliceNALUnits.first }.map { nal in
                (1..<5).reduce(0) { $0 << 7 | Int(nal[nal.startIndex + $1] & 0x7F) }
            }
            #expect(indices == Array(0..<45))
            #expect(frames.filter(\.isKeyframe).count >= 2)
            let rate = try #require(await receiver.measuredFrameRate())
            #expect(abs(rate - 30) < 1)

            #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.audioFrames >= 20 && $0.videoSenderReports >= 1 && $0.audioSenderReports >= 1 })
            var audioPayloads: [ReceivedAudioFrame] = []
            for await frame in receiver.audioFrames {
                audioPayloads.append(frame)
                if audioPayloads.count == 10 { break }
            }
            #expect(audioPayloads.allSatisfy { $0.payloadType == 110 && $0.ssrc == 0xB2B2_B2B2 && $0.payload.count == 60 })
            let timestampSteps = zip(audioPayloads.dropFirst(), audioPayloads).map { $0.rtpTimestamp &- $1.rtpTimestamp }
            #expect(timestampSteps.allSatisfy { $0 == 480 })   // 20 ms at the negotiated 24 kHz

            // Controller → accessory: PLI and return audio arrive decrypted.
            await receiver.requestKeyframe()
            #expect(await pli.value)
            for index in 0..<3 { try await receiver.sendReturnAudio(Data([0xFC, UInt8(index)]) + Data(repeating: 1, count: 40), samples: 480) }
            let back = await returned.value
            #expect(back.map { $0.data.first } == [0xFC, 0xFC, 0xFC])
            #expect(back.map { $0.data.dropFirst().first } == [0, 1, 2])

            // Keepalive: the session (1 s controller timeout) keeps running on our receiver reports alone …
            let framesBefore = await receiver.statistics.videoFrames
            try await Task.sleep(for: .milliseconds(1500))
            let stats = await receiver.statistics
            #expect(stats.videoFrames >= framesBefore + 30)
            #expect(stats.receiverReportsSent >= 5)
            #expect(stats.authenticationFailures == 0)
            #expect(stats.unexpectedSSRCPackets == 0)
            #expect(stats.malformedPackets == 0)
            #expect(stats.largestVideoDatagram <= 1200)
            #expect(await receiver.isStopped == false)
            // … and ends with a timeout (sending BYE) once they stop.
            await receiver.stopKeepalive()
            let end = await session.waitForEnd()
            #expect(end == .controllerTimeout)
            #expect(await receiver.waitFor(timeout: .seconds(2)) { $0.byes >= 1 })
            await receiver.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func dropsForgedAndForeignPackets() async throws {
            let receiver = try await SRTPTestReceiver.start()
            let sender = try UDPSocket.bind(host: "127.0.0.1")
            defer { sender.close() }
            await receiver.connect(to: SRTPTestReceiver.Peer(host: "127.0.0.1", videoPort: sender.localPort, audioPort: sender.localPort, videoSSRC: 7,
                                                             audioSSRC: 8, controllerVideoSSRC: 1, controllerAudioSSRC: 2), keepaliveInterval: nil)
            var wrongKey = try SRTPContext(masterKey: randomData(16), masterSalt: randomData(14))
            var rightKey = try SRTPContext(masterKey: receiver.videoKeys.masterKey, masterSalt: receiver.videoKeys.masterSalt)
            let packet = RTPPacket(marker: true, payloadType: 99, sequenceNumber: 1, timestamp: 1, ssrc: 7, payload: Data([0x65, 1, 2, 3]))
            try sender.send(try wrongKey.protectRTP(packet.serialized()), to: SocketAddress(host: "127.0.0.1", port: receiver.videoPort))
            var foreign = packet
            foreign.ssrc = 99
            try sender.send(try rightKey.protectRTP(foreign.serialized()), to: SocketAddress(host: "127.0.0.1", port: receiver.videoPort))
            try sender.send(try rightKey.protectRTP(packet.serialized()), to: SocketAddress(host: "127.0.0.1", port: receiver.videoPort))
            #expect(await receiver.waitFor(timeout: .seconds(5)) { $0.videoFrames == 1 })
            let stats = await receiver.statistics
            #expect(stats.authenticationFailures == 1)
            #expect(stats.unexpectedSSRCPackets == 1)
            #expect(stats.keyframes == 1)
            await receiver.stop()
            #expect(await receiver.isStopped)
        }
    }
}

// MARK: - A plain HAP accessory standing in for a camera

/// A camera-shaped HAP accessory built directly on the HAP module: every service a controller touches, with handlers
/// written against brief §3.5/§3.7/§3.8 (SetupEndpoints → UDP sockets, SelectedRTPStreamConfiguration → a real
/// `LiveStreamSession`, SetupDataStreamTransport → a real `DataStreamServer`, `dataSend` chunked like HAP-NodeJS).
private final class FakeCamera: Sendable {
    struct Prepared: Sendable {
        var request: ControllerTLV.SetupEndpointsRequest
        var response: ControllerTLV.SetupEndpointsResponse
        var video: UDPSocket
        var audio: UDPSocket
    }

    struct State: Sendable {
        var endpointsValue = Data([0x02, 0x01, 0x02])
        var prepared: Prepared?
        var selections: [ControllerTLV.SelectedRTPStreamConfiguration] = []
        var session: LiveStreamSession?
        var mediaTasks: [Task<Void, Never>] = []
        var selectedRecording: Data?
        var snapshotRequests: [HAPResourceRequest] = []
        var opens: [HDSDictionary] = []
        var dataSendEvents: [HDSMessage] = []
        var refuseOpenWith: HDSProtocolReason?
        var dataStreamPreparations = 0
        /// Makes the next SetupEndpoints answer inconsistent with the request (negative tests of the controller).
        var endpointsFault: EndpointsFault?
        /// `/resource` answers only after this delay (cancellation tests).
        var snapshotDelay: Duration?
    }

    enum EndpointsFault: Sendable, CaseIterable {
        /// SRTP keys other than the controller's (the test receiver decrypts with the controller's keys).
        case otherKeys
        /// No accessory SSRCs (media could not be filtered by SSRC).
        case missingSSRCs
        /// An IPv6 accessory address on an IPv4 HAP connection.
        case wrongFamily
    }

    let accessory: Accessory
    let server: AccessoryServer
    let dataStream: DataStreamServer
    let transport: AppleNetworkTransport
    let state = Box(State())
    let motion: Characteristic
    let port: UInt16
    let setupCode: String
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x42, count: 3000) + Data([0xFF, 0xD9])
    /// init + fragments `dataSend` delivers (a 600 KB fragment spans three 0x40000 chunks).
    let recordingPackets = [randomData(1500), randomData(600_000), randomData(5000), randomData(300_000)]

    private init(accessory: Accessory, server: AccessoryServer, dataStream: DataStreamServer, transport: AppleNetworkTransport, motion: Characteristic,
                 port: UInt16, setupCode: String) {
        self.accessory = accessory
        self.server = server
        self.dataStream = dataStream
        self.transport = transport
        self.motion = motion
        self.port = port
        self.setupCode = setupCode
    }

    static func start() async throws -> FakeCamera {
        let transport = AppleNetworkTransport()
        let accessory = Accessory(info: AccessoryInfo(name: "Fake Camera", manufacturer: "CameraBridge", model: "FakeCam",
                                                      serialNumber: "FAKE-\(UUID().uuidString.prefix(8))", firmwareRevision: "1.0.0"),
                                  category: .ipCamera)
        let motionService = accessory.addService(Service(.motionSensor, name: "Motion"))
        let stream = accessory.addService(Service(.cameraRTPStreamManagement))
        stream.characteristic(.supportedVideoStreamConfiguration).update(.data(try hex(BriefGolden.supportedVideoStream)))
        stream.characteristic(.supportedAudioStreamConfiguration).update(.data(try hex(BriefGolden.supportedAudioStream)))
        stream.characteristic(.supportedRTPConfiguration).update(.data(try hex(BriefGolden.supportedRTP)))
        stream.characteristic(.streamingStatus).update(.data(ControllerTLV.StreamingStatus.available.encoded()))
        let recording = accessory.addService(Service(.cameraRecordingManagement))
        recording.characteristic(.supportedCameraRecordingConfiguration).update(.data(try hex(BriefGolden.supportedCameraRecording)))
        recording.characteristic(.supportedVideoRecordingConfiguration).update(.data(try hex(BriefGolden.v1VideoRecording)))
        recording.characteristic(.supportedAudioRecordingConfiguration).update(.data(try hex(BriefGolden.v1AudioRecording)))
        recording.characteristic(.recordingAudioActive)
        accessory.addService(Service(.cameraOperatingMode)).characteristic(.periodicSnapshotsActive)
        let dataStreamService = accessory.addService(Service(.dataStreamTransportManagement))
        dataStreamService.characteristic(.version).update(.string("1.0"))
        dataStreamService.characteristic(.supportedDataStreamTransportConfiguration).update(.data(try hex(BriefGolden.supportedDataStreamTransport)))

        let server = AccessoryServer(accessory: accessory, configuration: AccessoryServerConfiguration(port: 0, advertise: false,
                                                                                                        serviceName: "Fake Camera", loopbackOnly: true),
                                     store: InMemoryHAPStore(), transport: transport, advertiser: NullServiceAdvertiser())
        let dataStream = DataStreamServer(transport: transport, loopbackOnly: true)
        try await server.start()
        let camera = FakeCamera(accessory: accessory, server: server, dataStream: dataStream, transport: transport,
                                motion: motionService.characteristic(.motionDetected), port: try #require(await server.port),
                                setupCode: try await server.setupCode.formatted)
        await camera.wire(stream: stream, recording: recording, dataStreamService: dataStreamService)
        return camera
    }

    private func wire(stream: Service, recording: Service, dataStreamService: Service) async {
        let state = self.state
        let jpeg = self.jpeg
        let dataStream = self.dataStream
        let packets = recordingPackets

        let endpoints = stream.characteristic(.setupEndpoints)
        endpoints.onWrite { (value: HAPValue, context: HAPRequestContext) async throws(HAPStatus) -> HAPValue? in
            guard let data = value.dataValue, let request = try? ControllerTLV.SetupEndpointsRequest.decode(data) else { throw .invalidValue }
            let video: UDPSocket
            let audio: UDPSocket
            do {
                video = try UDPSocket.bind(host: "127.0.0.1")
                audio = try UDPSocket.bind(host: "127.0.0.1")
            } catch {
                throw .resourceBusy
            }
            var response = ControllerTLV.SetupEndpointsResponse(
                sessionID: request.sessionID, status: 0,
                accessory: ControllerTLV.Address(isIPv6: false, ip: context.session.localAddress, videoPort: video.localPort, audioPort: audio.localPort),
                video: request.video, audio: request.audio, videoSSRC: UInt32.random(in: 1...UInt32.max), audioSSRC: UInt32.random(in: 1...UInt32.max))
            switch state.value.endpointsFault {
            case .otherKeys?:
                response.video = .random()
            case .missingSSRCs?:
                response.videoSSRC = nil
                response.audioSSRC = nil
            case .wrongFamily?:
                response.accessory = ControllerTLV.Address(isIPv6: true, ip: "::1", videoPort: video.localPort, audioPort: audio.localPort)
            case nil:
                break
            }
            let replaced = state.update { state -> Prepared? in
                defer {
                    state.prepared = Prepared(request: request, response: response, video: video, audio: audio)
                    state.endpointsValue = response.encoded()
                }
                return state.session == nil ? state.prepared : nil
            }
            replaced?.video.close()
            replaced?.audio.close()
            return nil
        }
        endpoints.onRead { (_: HAPRequestContext?) async throws(HAPStatus) -> HAPValue in .data(state.value.endpointsValue) }

        let status = stream.characteristic(.streamingStatus)
        stream.characteristic(.selectedRTPStreamConfiguration).onWrite { (value: HAPValue, _: HAPRequestContext) async throws(HAPStatus) -> HAPValue? in
            guard let data = value.dataValue, let selection = try? ControllerTLV.SelectedRTPStreamConfiguration.decode(data) else { throw .invalidValue }
            state.update { $0.selections.append(selection) }
            switch selection.command {
            case .start:
                guard let prepared = state.value.prepared, prepared.request.sessionID == selection.sessionID, let video = selection.video else {
                    throw .invalidValue
                }
                let audio = selection.audio.map { audio in
                    LiveAudioParameters(codec: .opus, payloadType: audio.payloadType, ssrc: prepared.response.audioSSRC ?? 0,
                                        srtpKey: prepared.request.audio.masterKey, srtpSalt: prepared.request.audio.masterSalt,
                                        rtpClockRate: audio.sampleRateHz, packetTime: .milliseconds(Int64(audio.packetTimeMs)))
                }
                let session = LiveStreamSession(
                    controller: SocketAddress(host: prepared.request.controller.ip, port: 0), videoPort: prepared.request.controller.videoPort,
                    audioPort: prepared.request.controller.audioPort, videoSocket: prepared.video, audioSocket: prepared.audio,
                    video: LiveVideoParameters(payloadType: video.payloadType, ssrc: prepared.response.videoSSRC ?? 0,
                                               srtpKey: prepared.request.video.masterKey, srtpSalt: prepared.request.video.masterSalt),
                    audio: audio, controllerTimeout: .seconds(10))
                let media = liveMedia(fps: video.resolution.fps, audioRate: selection.audio?.sampleRateHz ?? 24_000)
                await session.start(video: media.video, audio: media.audio)
                state.update {
                    $0.session = session
                    $0.mediaTasks = media.tasks
                }
                status.update(.data(ControllerTLV.StreamingStatus.inUse.encoded()))
            case .end:
                let (session, tasks) = state.update { state -> (LiveStreamSession?, [Task<Void, Never>]) in
                    defer {
                        state.session = nil
                        state.mediaTasks = []
                        state.prepared = nil
                    }
                    return (state.session, state.mediaTasks)
                }
                tasks.forEach { $0.cancel() }
                await session?.stop()
                status.update(.data(ControllerTLV.StreamingStatus.available.encoded()))
            case .reconfigure:
                break
            case .suspend, .resume:
                throw .invalidValue
            }
            return nil
        }

        let selected = recording.characteristic(.selectedCameraRecordingConfiguration)
        selected.onWrite { (value: HAPValue, _: HAPRequestContext) async throws(HAPStatus) -> HAPValue? in
            guard let data = value.dataValue else { throw .invalidValue }
            state.update { $0.selectedRecording = data }
            return nil
        }
        selected.onRead { (_: HAPRequestContext?) async throws(HAPStatus) -> HAPValue in
            guard let data = state.value.selectedRecording else { throw .serviceCommunicationFailure }
            return .data(data)
        }

        accessory.onResourceRequest { (request: HAPResourceRequest, _: HAPRequestContext) async throws(HAPStatus) -> Data in
            let delay = state.update { state -> Duration? in
                state.snapshotRequests.append(request)
                return state.snapshotDelay
            }
            if let delay { try? await Task.sleep(for: delay) }
            return jpeg
        }

        dataStreamService.characteristic(.setupDataStreamTransport).onWrite { (value: HAPValue, context: HAPRequestContext) async throws(HAPStatus) -> HAPValue? in
            guard let data = value.dataValue, let request = try? ControllerTLV.SetupDataStreamTransportRequest.decode(data),
                  request.command == 0, request.transportType == 0 else {
                throw .invalidValue
            }
            do {
                let prepared = try await dataStream.prepareSession(controllerKeySalt: request.controllerKeySalt, session: context.session)
                state.update { $0.dataStreamPreparations += 1 }
                return .data(ControllerTLV.SetupDataStreamTransportResponse(status: 0, tcpPort: prepared.port, accessoryKeySalt: prepared.accessoryKeySalt).encoded())
            } catch {
                throw .serviceCommunicationFailure
            }
        }

        await dataStream.setHandler(protocol: "dataSend") { message, connection in
            switch (message.kind, message.topic) {
            case (.request, "open"):
                state.update { $0.opens.append(message.body) }
                guard message.body["type"] == .string("ipcamera.recording"), message.body["target"] == .string("controller"),
                      case .int(let streamID)? = message.body["streamId"] else {
                    try? await connection.sendResponse(to: message, status: .protocolSpecificError,
                                                       body: HDSDictionary([("status", .int(HDSProtocolReason.unexpectedFailure.rawValue))]))
                    return
                }
                if let reason = state.value.refuseOpenWith {
                    try? await connection.sendResponse(to: message, status: .protocolSpecificError, body: HDSDictionary([("status", .int(reason.rawValue))]))
                    return
                }
                try? await connection.sendResponse(to: message, status: .success, body: HDSDictionary([("status", .int(0))]))
                Task {
                    for body in dataEvents(streamID: streamID, packets: packets) {
                        do {
                            try await connection.sendEvent(protocol: "dataSend", topic: "data", body: body)
                        } catch {
                            return
                        }
                    }
                }
            default:
                state.update { $0.dataSendEvents.append(message) }
            }
        }
    }

    /// A controller paired with a real pair-setup (SRP) and pair-verified.
    func pairedController() async throws -> HAPTestController {
        try await HAPTestController.paired(port: port, setupCode: setupCode)
    }

    /// Another admin controller, added through `admin`'s `/pairings` and pair-verified (no second SRP run).
    func additionalController(via admin: HAPTestController) async throws -> HAPTestController {
        let identity = HAPControllerIdentity.generate()
        try await admin.addPairing(identifier: identity.pairingID, publicKey: identity.publicKey, isAdmin: true)
        let pairing = try #require(await admin.pairing)
        return try await HAPTestController.connectVerified(host: "127.0.0.1", port: port, transport: transport, identity: identity, pairing: pairing)
    }

    func stop() async {
        let (session, tasks, prepared) = state.update { state in
            defer {
                state.session = nil
                state.mediaTasks = []
                state.prepared = nil
            }
            return (state.session, state.mediaTasks, state.prepared)
        }
        tasks.forEach { $0.cancel() }
        await session?.stop()
        if session == nil {
            prepared?.video.close()
            prepared?.audio.close()
        }
        await dataStream.stop()
        await server.stop()
    }
}

// MARK: - Controller against the HAP accessory

extension ControllerSelfTests {
    @Suite struct HAPTestControllerTests {
        @Test(.timeLimit(.minutes(1)))
        func pairsReadsWritesAndReportsStatuses() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await camera.pairedController()
            #expect(await controller.isVerified)
            #expect(await controller.sharedSecret?.count == 32)
            #expect(await camera.server.isPaired)

            let database = try await controller.accessories()
            let accessory = try #require(database.accessory(aid: 1))
            #expect(accessory.information(.name) == "Fake Camera")
            #expect(accessory.information(.manufacturer) == "CameraBridge")
            #expect(database.services(.cameraRTPStreamManagement).count == 1)
            let motion = try database.characteristic(.motionDetected, in: .motionSensor)
            #expect(motion.iid == camera.motion.iid)

            // Reads: values, metadata, and per-item statuses (207) for an unknown iid.
            let name = try database.characteristic(.name, in: .accessoryInformation)
            #expect(try await controller.readValue(name) == .string("Fake Camera"))
            let results = try await controller.read([name, HAPCharacteristicID(aid: 1, iid: 9999)], meta: true, permissions: true, type: true)
            #expect(results.map(\.status) == [0, HAPStatus.resourceDoesNotExist.rawValue])
            await #expect(throws: HAPControllerError.characteristicStatus(aid: 1, iid: 9999, status: HAPStatus.resourceDoesNotExist.rawValue)) {
                try await controller.readValue(HAPCharacteristicID(aid: 1, iid: 9999))
            }

            // Writes: read-only refused, timed-write characteristic needs /prepare, tlv8 data round trip.
            await #expect(throws: HAPControllerError.characteristicStatus(aid: 1, iid: name.iid, status: HAPStatus.readOnly.rawValue)) {
                try await controller.writeValue(name, .string("x"))
            }
            let ids = try CameraAccessoryIDs(database: database)
            let audioActive = try #require(ids.recording?.recordingAudioActive)
            await #expect(throws: HAPControllerError.characteristicStatus(aid: 1, iid: audioActive.iid, status: HAPStatus.invalidValue.rawValue)) {
                try await controller.writeValue(audioActive, .int(1))
            }
            try await controller.writeValue(audioActive, .int(1), timedWriteTTL: .seconds(2))
            #expect(try await controller.readValue(audioActive) == .int(1))
            let recording = try #require(ids.recording)
            await #expect(throws: HAPControllerError.characteristicStatus(aid: 1, iid: recording.selectedConfiguration.iid,
                                                                         status: HAPStatus.serviceCommunicationFailure.rawValue)) {
                try await controller.readData(recording.selectedConfiguration)
            }
            await controller.close()
            await camera.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func subscribesAndStreamsEvents() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await camera.pairedController()
            let other = try await camera.additionalController(via: controller)
            let database = try await controller.accessories()
            let motion = try database.characteristic(.motionDetected, in: .motionSensor)
            try await controller.subscribe([motion])
            let stream = controller.eventStream()
            camera.motion.update(.bool(true))
            let event = try await controller.nextEvent(for: motion)
            #expect(event.id == motion)
            #expect(event.value.hapBool == true)
            var iterator = stream.makeAsyncIterator()
            let streamed = await iterator.next()
            #expect(streamed?.value.hapBool == true)
            // Not subscribed: the other controller gets nothing.
            await #expect(throws: HAPControllerError.timedOut) { try await other.nextEvent(timeout: .milliseconds(400)) }
            try await controller.unsubscribe([motion])
            camera.motion.update(.bool(false))
            await #expect(throws: HAPControllerError.timedOut) { try await controller.nextEvent(for: motion, timeout: .milliseconds(500)) }
            // Values changed by a write are not echoed to the writer, but reach other subscribers.
            let ids = try CameraAccessoryIDs(database: database)
            let periodic = try #require(ids.periodicSnapshotsActive)
            try await other.subscribe([periodic])
            try await controller.writeValue(periodic, .int(1))
            #expect(try await other.nextEvent(for: periodic).value == .int(1))
            await other.close()
            await controller.close()
            await camera.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func snapshotsAndPairingManagement() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await camera.pairedController()
            let jpeg = try await controller.snapshot(width: 640, height: 360, aid: 1, reason: 1)
            #expect(jpeg == camera.jpeg)
            let request = try #require(camera.state.value.snapshotRequests.first)
            #expect(request.type == "image" && request.width == 640 && request.height == 360 && request.aid == 1 && request.reason == 1)

            // /pairings: list, add, remove.
            let own = controller.identity
            #expect(try await controller.listPairings().map(\.identifier) == [own.pairingID])
            let guest = HAPControllerIdentity.generate()
            try await controller.addPairing(identifier: guest.pairingID, publicKey: guest.publicKey, isAdmin: false)
            let listed = try await controller.listPairings()
            #expect(Set(listed.map(\.identifier)) == [own.pairingID, guest.pairingID])
            #expect(listed.first { $0.identifier == guest.pairingID }?.isAdmin == false)
            #expect(listed.first { $0.identifier == own.pairingID }?.publicKey == own.publicKey)
            try await controller.removePairing(identifier: guest.pairingID)
            #expect(try await controller.listPairings().count == 1)

            // A stored pairing verifies on a new connection; after removing ourselves it no longer does.
            let pairing = try #require(await controller.pairing)
            let second = try await HAPTestController.connectVerified(host: "127.0.0.1", port: camera.port, transport: camera.transport, identity: own,
                                                                     pairing: pairing)
            #expect(try await second.accessories().accessories.count == 1)
            await second.close()
            try await controller.removePairing()
            #expect(await eventually { await !camera.server.isPaired })
            let third = try await HAPTestController.connect(host: "127.0.0.1", port: camera.port, transport: camera.transport, identity: own, pairing: pairing)
            await #expect(throws: HAPControllerError.self) { try await third.pairVerify() }
            await third.close()
            await controller.close()
            await camera.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func wrongSetupCodeFailsAtM4() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await HAPTestController.connect(host: "127.0.0.1", port: camera.port, transport: camera.transport)
            let wrong = camera.setupCode == "111-22-333" ? "111-22-334" : "111-22-333"
            await #expect(throws: HAPControllerError.pairing(step: 4, error: 2)) { try await controller.pairSetup(setupCode: wrong) }
            await #expect(throws: HAPControllerError.invalidArgument("setup code must be 8 digits (XXX-XX-XXX)")) {
                try await controller.pairSetup(setupCode: "12-34")
            }
            await #expect(throws: HAPControllerError.notPaired) { try await controller.pairVerify() }
            // Unverified requests are refused with 470.
            let response = try await controller.request("GET", "/accessories")
            #expect(response.status == 470)
            await controller.close()
            await camera.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func liveStreamThroughSetupEndpointsAndSelectedConfiguration() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await camera.pairedController()
            let ids = try await controller.cameraIDs()
            let stream = try #require(ids.streams.first)
            let supported = try await controller.supportedStreamingConfiguration(stream)
            #expect(supported.video.codecs.first?.resolutions.contains(ControllerTLV.Resolution(1280, 720, 30)) == true)
            #expect(supported.audio.codecs.map(\.codec) == [3])
            #expect(supported.rtp.cryptoSuites == [0])
            #expect(try await controller.streamingStatus(stream) == .available)
            #expect(try ControllerTLV.SetupEndpointsResponse.decode(try await controller.readData(stream.setupEndpoints)).status == 2)

            let started = ContinuousClock.now
            let live = try await controller.startLiveStream(stream)
            #expect(live.endpoints.isSuccess)
            #expect(live.endpoints.accessory?.ip == "127.0.0.1")
            // What the accessory saw is what the options asked for.
            let seen = try #require(camera.state.value.selections.last)
            #expect(seen.command == .start)
            #expect(seen.sessionID == live.sessionID)
            #expect(seen.video == live.video)
            #expect(seen.audio == live.audio)
            #expect(seen.video?.resolution == ControllerTLV.Resolution(1280, 720, 30))
            #expect(try await controller.streamingStatus(stream) == .inUse)

            var frames: [ReceivedVideoFrame] = []
            for await frame in live.receiver.videoFrames {
                frames.append(frame)
                if frames.count == 20 { break }
            }
            #expect(frames.first?.isKeyframe == true)
            #expect(frames.allSatisfy { $0.isComplete })
            let firstKeyframe = try #require(await live.receiver.firstKeyframeAt)
            #expect(firstKeyframe - started < .seconds(2))
            #expect(await live.receiver.waitFor(timeout: .seconds(5)) { $0.audioFrames >= 5 })

            try await live.reconfigure(resolution: ControllerTLV.Resolution(640, 360, 30), maxBitrateKbps: 500)
            #expect(camera.state.value.selections.last?.command == .reconfigure)
            #expect(camera.state.value.selections.last?.video?.resolution == ControllerTLV.Resolution(640, 360, 30))

            try await live.stop(keepReceiver: true)
            #expect(camera.state.value.selections.last?.command == .end)
            #expect(await live.receiver.waitFor(timeout: .seconds(3)) { $0.byes >= 1 })
            #expect(try await controller.streamingStatus(stream) == .available)
            await live.receiver.stop()
            await controller.close()
            await camera.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func recordingThroughDataStream() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await camera.pairedController()
            let ids = try await controller.cameraIDs()
            let recording = try #require(ids.recording)
            let supported = try await controller.supportedRecordingConfiguration(recording)
            #expect(supported.camera.prebufferLengthMs == 4000)
            #expect(supported.video.codecs.first?.resolutions == [ControllerTLV.Resolution(1280, 720, 30), ControllerTLV.Resolution(1920, 1080, 30)])
            #expect(supported.audio.codecs.first?.sampleRates == [3])
            let selection = try ControllerTLV.SelectedCameraRecordingConfiguration.preferred(camera: supported.camera, video: supported.video,
                                                                                             audio: supported.audio)
            try await controller.selectRecordingConfiguration(recording, selection)
            #expect(try ControllerTLV.SelectedCameraRecordingConfiguration.decode(try #require(camera.state.value.selectedRecording)) == selection)
            #expect(try ControllerTLV.SelectedCameraRecordingConfiguration.decode(try await controller.readData(recording.selectedConfiguration)) == selection)
            try await controller.enableRecording(ids, audio: true)
            #expect(try await controller.readValue(recording.active) == .int(1))
            #expect(try await controller.readValue(try #require(ids.homeKitCameraActive)) == .int(1))

            let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
            #expect(camera.state.value.dataStreamPreparations == 1)
            #expect(await eventually { await camera.dataStream.connectionCount == 1 })

            camera.state.update { $0.refuseOpenWith = .busy }
            let refused = try await dataStream.openRecording(streamID: 3)
            #expect(!refused.isAccepted)
            #expect(refused.status == .protocolSpecificError)
            #expect(refused.protocolReason == .busy)
            let wrongType = try await dataStream.openRecording(streamID: 3, type: "ipcamera.snapshot")
            #expect(wrongType.protocolReason == .unexpectedFailure)
            camera.state.update { $0.refuseOpenWith = nil }

            let open = try await dataStream.openRecording(streamID: 5, reason: "motion")
            #expect(open.isAccepted)
            #expect(camera.state.value.opens.last?["reason"] == .string("motion"))
            let capture = try await dataStream.receiveRecording(streamID: 5)
            #expect(capture.endOfStream)
            #expect(capture.initialization == camera.recordingPackets[0])
            #expect(capture.fragments == Array(camera.recordingPackets.dropFirst()))
            #expect(capture.chunkCounts == [1, 3, 1, 2])
            #expect(capture.mp4 == camera.recordingPackets.reduce(Data(), +))
            try await dataStream.ackRecording(streamID: 5)
            try await dataStream.closeRecording(streamID: 5, reason: .cancelled)
            #expect(await eventually { camera.state.value.dataSendEvents.count == 2 })
            let events = camera.state.value.dataSendEvents
            #expect(events.map(\.topic) == ["ack", "close"])
            #expect(events.first?.body["endOfStream"] == .bool(true))
            #expect(events.last?.body["reason"] == .int(HDSProtocolReason.cancelled.rawValue))

            // Closing the HAP session closes its data stream (the server ties HDS to the HAP connection).
            await controller.close()
            #expect(await dataStream.waitUntilClosed(timeout: .seconds(5)))
            await camera.stop()
        }

        /// SetupEndpoints answers that contradict the request are reported as protocol errors (instead of silent SRTP
        /// authentication failures or unfiltered media): other SRTP keys, missing SSRCs, another address family.
        @Test(.timeLimit(.minutes(1)))
        func startLiveStreamRejectsInconsistentSetupEndpointsAnswers() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await camera.pairedController()
            let stream = try #require(try await controller.cameraIDs().streams.first)
            let expectedWording: [FakeCamera.EndpointsFault: String] = [.otherKeys: "SRTP", .missingSSRCs: "SSRC", .wrongFamily: "address family"]
            for fault in FakeCamera.EndpointsFault.allCases {
                camera.state.update { $0.endpointsFault = fault }
                do {
                    let live = try await controller.startLiveStream(stream)
                    Issue.record("startLiveStream accepted a SetupEndpoints answer with \(fault)")
                    try await live.stop()
                } catch HAPControllerError.malformedResponse(let what) {
                    #expect(what.contains(try #require(expectedWording[fault])), "\(fault): \(what)")
                }
                #expect(camera.state.value.selections.isEmpty, "no start command after a bad SetupEndpoints answer")
            }
            #expect(await !controller.isClosed)
            camera.state.update { $0.endpointsFault = nil }
            let live = try await controller.startLiveStream(stream)
            #expect(live.endpoints.videoSSRC != nil && live.endpoints.audioSSRC != nil)
            try await live.stop()
            await controller.close()
            await camera.stop()
        }

        /// A cancelled caller returns at once instead of waiting for its timeout: an event wait just ends, a request
        /// still queued behind another leaves the connection usable, and an in-flight request closes the connection
        /// (its late answer would otherwise be taken for the next request's).
        @Test(.timeLimit(.minutes(1)))
        func cancellationEndsWaitsPromptly() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await camera.pairedController()
            let name = try await controller.accessories().characteristic(.name, in: .accessoryInformation)
            let clock = ContinuousClock()

            let waiting = Task { try await controller.nextEvent(timeout: .seconds(20)) }
            try await Task.sleep(for: .milliseconds(100))
            var cancelledAt = clock.now
            waiting.cancel()
            await #expect(throws: CancellationError.self) { try await waiting.value }
            #expect(clock.now - cancelledAt < .seconds(2))
            #expect(await !controller.isClosed)

            // The accessory answers /resource only after 10 s; a read waits behind it.
            camera.state.update { $0.snapshotDelay = .seconds(10) }
            let slow = Task { try await controller.snapshot(width: 64, height: 36, timeout: .seconds(20)) }
            #expect(await eventually { camera.state.value.snapshotRequests.count == 1 })
            let queued = Task { try await controller.readValue(name) }
            try await Task.sleep(for: .milliseconds(100))
            cancelledAt = clock.now
            queued.cancel()
            await #expect(throws: CancellationError.self) { try await queued.value }
            #expect(clock.now - cancelledAt < .seconds(2))
            #expect(await !controller.isClosed)

            cancelledAt = clock.now
            slow.cancel()
            await #expect(throws: CancellationError.self) { try await slow.value }
            #expect(clock.now - cancelledAt < .seconds(2))
            #expect(await controller.isClosed)
            // Already cancelled before the call: nothing is sent.
            let fresh = try await controller.reconnect()
            try await fresh.pairVerify()
            let early = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await fresh.readValue(name)
            }
            await #expect(throws: CancellationError.self) { try await early.value }
            #expect(try await fresh.readValue(name) == .string("Fake Camera"))
            await fresh.close()
            await camera.stop()
        }

        /// Events nobody takes are kept up to `eventBufferLimit` (oldest dropped and counted), so a controller that only
        /// reads `eventStream()` does not keep every event forever.
        @Test(.timeLimit(.minutes(1)))
        func unclaimedEventsAreCapped() async throws {
            let camera = try await FakeCamera.start()
            let controller = try await camera.pairedController()
            let motion = try await controller.accessories().characteristic(.motionDetected, in: .motionSensor)
            #expect(await controller.eventBufferLimit == HAPTestController.defaultEventBufferLimit)
            await controller.setEventBufferLimit(4)
            try await controller.subscribe([motion])
            let stream = controller.eventStream()
            for index in 0..<10 { camera.motion.update(.bool(index % 2 == 0)) }
            var iterator = stream.makeAsyncIterator()
            var streamed = 0
            while streamed < 10, await iterator.next() != nil { streamed += 1 }
            #expect(streamed == 10)
            #expect(await controller.droppedEventCount == 6)
            #expect(await controller.drainEvents().count == 4)
            await controller.close()
            await camera.stop()
        }
    }
}

// MARK: - HDS client against a DataStreamServer with a fake HAP session

extension ControllerSelfTests {
    @Suite struct HDSTestClientTests {
        @Test(.timeLimit(.minutes(1)))
        func helloRequestsEventsAndRecordingAgainstFakeSession() async throws {
            let transport = AppleNetworkTransport()
            let server = DataStreamServer(transport: transport, loopbackOnly: true)
            let received = Box<[HDSMessage]>([])
            let packets = [randomData(700), randomData(0x40000 + 17)]
            await server.setHandler(protocol: "dataSend") { message, connection in
                received.update { $0.append(message) }
                guard case .request = message.kind, message.topic == "open", case .int(let streamID)? = message.body["streamId"] else { return }
                try? await connection.sendResponse(to: message, status: .success, body: HDSDictionary([("status", .int(0))]))
                Task {
                    for body in dataEvents(streamID: streamID, packets: packets, endOfStream: false) {
                        try? await connection.sendEvent(protocol: "dataSend", topic: "data", body: body)
                    }
                    try? await connection.sendEvent(protocol: "dataSend", topic: "close",
                                                    body: HDSDictionary([("streamId", .int(streamID)), ("reason", .int(HDSProtocolReason.timeout.rawValue))]))
                }
            }
            await server.setHandler(protocol: "echo") { message, connection in
                guard case .request = message.kind else { return }
                try? await connection.sendResponse(to: message, status: .success, body: message.body)
                try? await connection.sendEvent(protocol: "echo", topic: "later", body: HDSDictionary([("n", .int(7))]))
            }
            let session = TestHAPSession()
            let controllerSalt = ControllerTLV.randomBytes(32)
            let prepared = try await server.prepareSession(controllerKeySalt: controllerSalt, session: session)
            let client = try await HDSTestClient.connect(host: "127.0.0.1", port: prepared.port, transport: transport, sharedSecret: session.sharedSecret,
                                                         controllerKeySalt: controllerSalt, accessoryKeySalt: prepared.accessoryKeySalt)
            try await client.hello()

            let echo = try await client.sendRequest(protocol: "echo", topic: "ping", body: HDSDictionary([("value", .string("hi"))]))
            #expect(echo.kind == .response(id: 2, status: .success))
            #expect(echo.body["value"] == .string("hi"))
            #expect(try await client.nextEvent(protocol: "echo").body["n"] == .int(7))
            let missing = try await client.sendRequest(protocol: "nobody", topic: "x", body: HDSDictionary())
            #expect(missing.kind == .response(id: 3, status: .missingProtocol))

            let open = try await client.openRecording(streamID: 9)
            #expect(open.isAccepted)
            let capture = try await client.receiveRecording(streamID: 9)
            #expect(capture.initialization == packets[0])
            #expect(capture.fragments == [packets[1]])
            #expect(capture.chunkCounts == [1, 2])
            #expect(!capture.endOfStream)
            #expect(capture.closeReason == .timeout)
            try await client.closeRecording(streamID: 9, reason: .normal)
            #expect(await eventually { received.value.contains { $0.topic == "close" } })

            // The HAP session closing ends the data stream connection.
            session.close()
            #expect(await client.waitUntilClosed(timeout: .seconds(5)))
            await #expect(throws: HDSTestClientError.self) { try await client.hello() }
            await server.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func wrongKeysAreDropped() async throws {
            let transport = AppleNetworkTransport()
            let server = DataStreamServer(transport: transport, loopbackOnly: true)
            let session = TestHAPSession()
            let controllerSalt = ControllerTLV.randomBytes(32)
            let prepared = try await server.prepareSession(controllerKeySalt: controllerSalt, session: session)
            let client = try await HDSTestClient.connect(host: "127.0.0.1", port: prepared.port, transport: transport, sharedSecret: ControllerTLV.randomBytes(32),
                                                         controllerKeySalt: controllerSalt, accessoryKeySalt: prepared.accessoryKeySalt)
            await #expect(throws: (any Error).self) { try await client.hello(timeout: .seconds(5)) }
            #expect(await client.isClosed)
            await server.stop()
        }

        /// A DataStreamServer with an `echo` protocol (answers requests with their body, records every message), a
        /// `silent` one (never answers) and `burst` (answers, then sends `count` events `n` = 0, 1, …), and a client
        /// that said hello.
        private static func echoServer() async throws -> (server: DataStreamServer, client: HDSTestClient, received: Box<[HDSMessage]>) {
            let transport = AppleNetworkTransport()
            let server = DataStreamServer(transport: transport, loopbackOnly: true)
            let received = Box<[HDSMessage]>([])
            await server.setHandler(protocol: "echo") { message, connection in
                received.update { $0.append(message) }
                guard case .request = message.kind else { return }
                try? await connection.sendResponse(to: message, status: .success, body: message.body)
            }
            await server.setHandler(protocol: "silent") { message, _ in received.update { $0.append(message) } }
            await server.setHandler(protocol: "burst") { message, connection in
                guard case .request = message.kind, case .int(let count)? = message.body["count"] else { return }
                try? await connection.sendResponse(to: message, status: .success, body: HDSDictionary())
                for n in 0..<count { try? await connection.sendEvent(protocol: "burst", topic: "n", body: HDSDictionary([("n", .int(n))])) }
            }
            let session = TestHAPSession()
            let controllerSalt = ControllerTLV.randomBytes(32)
            let prepared = try await server.prepareSession(controllerKeySalt: controllerSalt, session: session)
            let client = try await HDSTestClient.connect(host: "127.0.0.1", port: prepared.port, transport: transport, sharedSecret: session.sharedSecret,
                                                         controllerKeySalt: controllerSalt, accessoryKeySalt: prepared.accessoryKeySalt)
            try await client.hello()
            return (server, client, received)
        }

        /// Frames reach the socket in nonce-counter order however many tasks send at once (the accessory drops the
        /// connection at the first frame that does not decrypt with the next counter).
        @Test(.timeLimit(.minutes(1)))
        func concurrentRequestsAndEventsKeepTheStreamAlive() async throws {
            let (server, client, received) = try await Self.echoServer()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in Int64(0)..<40 {
                    group.addTask {
                        let answer = try await client.sendRequest(protocol: "echo", topic: "ping", body: HDSDictionary([("n", .int(index))]))
                        #expect(answer.body["n"] == .int(index))
                    }
                    group.addTask { try await client.sendEvent(protocol: "echo", topic: "note", body: HDSDictionary([("n", .int(index))])) }
                    group.addTask {
                        let answer = try await client.sendRequest(protocol: "nobody", topic: "x", body: HDSDictionary())
                        #expect(answer.kind.isMissingProtocolResponse)
                    }
                }
                try await group.waitForAll()
            }
            #expect(await !client.isClosed)
            #expect(await eventually { received.value.count == 80 })
            let eventNumbers = received.value.filter { $0.kind == .event }.compactMap { message -> Int64? in
                if case .int(let n)? = message.body["n"] { n } else { nil }
            }
            #expect(Set(eventNumbers) == Set(0..<40))
            let after = try await client.sendRequest(protocol: "echo", topic: "ping", body: HDSDictionary([("n", .int(99))]))
            #expect(after.body["n"] == .int(99))
            await client.close()
            await server.stop()
        }

        /// A cancelled `nextEvent` / `sendRequest` returns at once with CancellationError; the stream stays usable (a
        /// late response is matched by id and dropped).
        @Test(.timeLimit(.minutes(1)))
        func cancellationEndsWaitsPromptly() async throws {
            let (server, client, received) = try await Self.echoServer()
            let clock = ContinuousClock()
            let waiting = Task { try await client.nextEvent(timeout: .seconds(20)) }
            try await Task.sleep(for: .milliseconds(100))
            var cancelledAt = clock.now
            waiting.cancel()
            await #expect(throws: CancellationError.self) { try await waiting.value }
            #expect(clock.now - cancelledAt < .seconds(2))

            let request = Task { try await client.sendRequest(protocol: "silent", topic: "x", body: HDSDictionary(), timeout: .seconds(20)) }
            #expect(await eventually { received.value.contains { $0.protocolName == "silent" } })
            cancelledAt = clock.now
            request.cancel()
            await #expect(throws: CancellationError.self) { try await request.value }
            #expect(clock.now - cancelledAt < .seconds(2))

            #expect(await !client.isClosed)
            let after = try await client.sendRequest(protocol: "echo", topic: "ping", body: HDSDictionary([("n", .int(1))]))
            #expect(after.body["n"] == .int(1))
            // waitUntilClosed ends on cancellation too (it used to spin until its deadline).
            let closedWait = Task { await client.waitUntilClosed(timeout: .seconds(20)) }
            try await Task.sleep(for: .milliseconds(50))
            cancelledAt = clock.now
            closedWait.cancel()
            #expect(await closedWait.value == false)
            #expect(clock.now - cancelledAt < .seconds(2))
            await client.close()
            await server.stop()
        }

        /// Events nobody takes are kept up to `eventBufferLimit`; the oldest are dropped and counted.
        @Test(.timeLimit(.minutes(1)))
        func unclaimedEventsAreCapped() async throws {
            let (server, client, _) = try await Self.echoServer()
            #expect(await client.eventBufferLimit == HDSTestClient.defaultEventBufferLimit)
            await client.setEventBufferLimit(4)
            _ = try await client.sendRequest(protocol: "burst", topic: "go", body: HDSDictionary([("count", .int(10))]))
            #expect(await eventually { await client.droppedEventCount == 6 })
            #expect(await client.queuedEvents.map { $0.body["n"] } == [6, 7, 8, 9].map { HDSValue.int($0) })
            await client.close()
            await server.stop()
        }
    }
}

extension HDSMessage.Kind {
    fileprivate var isMissingProtocolResponse: Bool {
        if case .response(_, .missingProtocol) = self { return true }
        return false
    }
}

// MARK: - cbctl

/// `AppleNetworkTransport`, except that a connection dies when it sends a pair-verify request (plaintext), so
/// pair-setup succeeds and pair-verify fails.
private struct PairVerifyFailingTransport: NetworkTransport {
    let base = AppleNetworkTransport()

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        try await base.listen(port: port, loopbackOnly: loopbackOnly)
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        PairVerifyFailingConnection(try await base.connect(host: host, port: port, timeout: timeout))
    }
}

private final class PairVerifyFailingConnection: TCPConnection {
    let base: any TCPConnection
    init(_ base: any TCPConnection) { self.base = base }
    var id: UUID { base.id }
    var localAddress: String { base.localAddress }
    var remoteAddress: String { base.remoteAddress }
    var isIPv6: Bool { base.isIPv6 }
    func receive(maximumLength: Int) async throws -> Data? { try await base.receive(maximumLength: maximumLength) }
    func close() { base.close() }

    func send(_ data: Data) async throws {
        if data.range(of: Data("POST /pair-verify".utf8)) != nil {
            base.close()
            throw TransportError.closed
        }
        try await base.send(data)
    }
}

private final class CapturedOutput: Sendable {
    private let lines = Box<[(isError: Bool, text: String)]>([])
    var output: ControllerCLI.Output {
        ControllerCLI.Output(standard: { text in self.lines.update { $0.append((false, text)) } },
                             error: { text in self.lines.update { $0.append((true, text)) } })
    }

    var standard: String { lines.value.filter { !$0.isError }.map(\.text).joined(separator: "\n") }
    var error: String { lines.value.filter(\.isError).map(\.text).joined(separator: "\n") }
    var all: String { lines.value.map(\.text).joined(separator: "\n") }
}

extension ControllerSelfTests {
    @Suite struct ControllerCLITests {
        /// Each command is required to succeed: a failure reports what cbctl printed to stderr and stops the test (later
        /// steps read the files it writes).
        @Test(.timeLimit(.minutes(1)))
        func everyCommandAgainstALoopbackAccessory() async throws {
            let camera = try await FakeCamera.start()
            let home = try TestSupportModule.makeTemporaryDirectory(prefix: "cbctl")
            defer { try? FileManager.default.removeItem(at: home) }
            let captured = CapturedOutput()
            let cli = ControllerCLI(store: HAPControllerStore(directory: home.appending(path: "store")), transport: camera.transport, output: captured.output)
            let endpoint = "127.0.0.1:\(camera.port)"

            try #require(await cli.run(["pair", endpoint, camera.setupCode]) == 0, "\(captured.error)")
            #expect(captured.standard.contains("Paired with Fake Camera"))
            let store = home.appending(path: "store")
            let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            for file in ["controller.json", "accessories.json"] {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.appending(path: file).path)
                #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            }
            let stored = try HAPControllerStore(directory: store).accessories()
            #expect(stored.map(\.port) == [camera.port])

            try #require(await cli.run(["accessories"]) == 0, "\(captured.error)")
            #expect(captured.standard.contains("\"accessories\""))

            // Flip motion only once the CLI has subscribed and printed the current value ("Watching …" follows both).
            let motionFlip = Task {
                let watching = await eventually(timeout: .seconds(30)) { captured.standard.contains("Watching") }
                camera.motion.update(.bool(true))
                return watching
            }
            try #require(await cli.run(["watch-motion", "--seconds", "1.5"]) == 0, "\(captured.error)")
            #expect(await motionFlip.value)
            #expect(captured.standard.contains("MotionDetected = false"))
            #expect(captured.standard.contains("MotionDetected = true"))

            let jpegPath = home.appending(path: "snap.jpg")
            try #require(await cli.run(["snapshot", jpegPath.path, "--width", "320", "--height", "180"]) == 0, "\(captured.error)")
            #expect(try Data(contentsOf: jpegPath) == camera.jpeg)
            #expect(camera.state.value.snapshotRequests.last?.width == 320)

            let h264Path = home.appending(path: "live.h264")
            try #require(await cli.run(["live", "1.5", h264Path.path]) == 0, "\(captured.error)")
            let elementary = try Data(contentsOf: h264Path)
            #expect(elementary.prefix(5) == Data([0, 0, 0, 1, 0x67]))
            #expect(elementary.count > 20_000)
            #expect(camera.state.value.selections.map(\.command) == [.start, .end])

            let mp4Path = home.appending(path: "rec.mp4")
            try #require(await cli.run(["record", mp4Path.path, "--seconds", "20"]) == 0, "\(captured.error)")
            #expect(try Data(contentsOf: mp4Path) == camera.recordingPackets.reduce(Data(), +))
            #expect(captured.standard.contains("end of stream"))
            #expect(await eventually { camera.state.value.dataSendEvents.map(\.topic) == ["ack"] })

            try #require(await cli.run(["unpair"]) == 0, "\(captured.error)")
            #expect(await eventually { await !camera.server.isPaired })
            #expect(try HAPControllerStore(directory: store).accessories().isEmpty)
            #expect(await cli.run(["accessories"]) == 1)
            #expect(captured.error.contains("no paired accessory"))

            // Secrets never reach the output.
            let identity = try #require(try HAPControllerStore(directory: store).loadIdentity())
            #expect(!captured.all.contains(camera.setupCode))
            #expect(!captured.all.contains(camera.setupCode.replacingOccurrences(of: "-", with: "")))
            #expect(!captured.all.contains(identity.longTermKey.base64EncodedString()))
            #expect(!captured.all.contains(identity.longTermKey.hexString))
            await camera.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func usageAndArgumentErrors() async throws {
            let home = try TestSupportModule.makeTemporaryDirectory(prefix: "cbctl")
            defer { try? FileManager.default.removeItem(at: home) }
            let captured = CapturedOutput()
            let cli = ControllerCLI(store: HAPControllerStore(directory: home), transport: AppleNetworkTransport(), output: captured.output)
            #expect(await cli.run(["--help"]) == 0)
            #expect(captured.standard.contains("watch-motion"))
            #expect(await cli.run([]) == 0)
            #expect(await cli.run(["frobnicate"]) == 64)
            #expect(await cli.run(["pair", "no-port", "123-45-678"]) == 64)
            #expect(await cli.run(["pair", "127.0.0.1:1"]) == 64)
            #expect(await cli.run(["live", "abc", "out.h264"]) == 64)
            #expect(await cli.run(["snapshot", "a.jpg", "--width"]) == 64)
            #expect(await cli.run(["watch-motion"]) == 1)
            #expect(captured.error.contains("no paired accessory"))
            // --home switches the store directory.
            let other = home.appending(path: "other")
            #expect(await cli.run(["--home", other.path, "accessories"]) == 1)
            #expect(!FileManager.default.fileExists(atPath: other.appending(path: "controller.json").path))
        }

        /// Pair-setup succeeded but pair-verify failed: the accessory now counts this controller as its admin and
        /// refuses a new pair-setup, so the pairing must already be stored — later commands verify with it and `unpair`
        /// can release the accessory.
        @Test(.timeLimit(.minutes(1)))
        func pairStoresThePairingBeforeVerifying() async throws {
            let camera = try await FakeCamera.start()
            let home = try TestSupportModule.makeTemporaryDirectory(prefix: "cbctl")
            defer { try? FileManager.default.removeItem(at: home) }
            let store = HAPControllerStore(directory: home.appending(path: "store"))
            let captured = CapturedOutput()
            let failing = ControllerCLI(store: store, transport: PairVerifyFailingTransport(), output: captured.output)
            #expect(await failing.run(["pair", "127.0.0.1:\(camera.port)", camera.setupCode]) == 1)
            #expect(await camera.server.isPaired)
            #expect(captured.error.contains("pair-verify failed"))
            #expect(captured.error.contains("cbctl unpair"))
            #expect(try store.accessories().map(\.port) == [camera.port])

            let cli = ControllerCLI(store: store, transport: camera.transport, output: captured.output)
            try #require(await cli.run(["accessories"]) == 0, "\(captured.error)")
            try #require(await cli.run(["unpair"]) == 0, "\(captured.error)")
            #expect(await eventually { await !camera.server.isPaired })
            #expect(try store.accessories().isEmpty)
            #expect(!captured.all.contains(camera.setupCode))
            await camera.stop()
        }

        /// The store creates its directory 0700; an existing directory is used only if it is private (never chmodded:
        /// `--home ~/Shared` must not silently change a shared folder), and no secret is written into a shared one.
        @Test func storeDirectoryMustBePrivate() throws {
            let home = try TestSupportModule.makeTemporaryDirectory(prefix: "cbctl-perms")
            defer { try? FileManager.default.removeItem(at: home) }
            let manager = FileManager.default
            func mode(_ url: URL) throws -> Int {
                try #require((manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue) & 0o777
            }
            let fresh = home.appending(path: "fresh")
            _ = try HAPControllerStore(directory: fresh).loadOrCreateIdentity()
            #expect(try mode(fresh) == 0o700)
            #expect(try mode(fresh.appending(path: "controller.json")) == 0o600)

            let own = home.appending(path: "own")
            try manager.createDirectory(at: own, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            _ = try HAPControllerStore(directory: own).loadOrCreateIdentity()
            #expect(try mode(own) == 0o700)

            let shared = home.appending(path: "shared")
            try manager.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            #expect(throws: HAPControllerStoreError.insecureDirectory(shared.path)) { try HAPControllerStore(directory: shared).loadOrCreateIdentity() }
            #expect(try mode(shared) == 0o755)
            #expect(!manager.fileExists(atPath: shared.appending(path: "controller.json").path))
            // Reading (no pairing yet) does not touch the directory either.
            #expect(try HAPControllerStore(directory: shared).loadIdentity() == nil)
            #expect(try mode(shared) == 0o755)
        }

        @Test func storeDirectoryHonoursCBCTLHome() {
            #expect(HAPControllerStore.defaultDirectory(environment: ["CBCTL_HOME": "/tmp/cbctl-home"]).path == "/tmp/cbctl-home")
            #expect(HAPControllerStore.defaultDirectory(environment: [:]).lastPathComponent == ".cbctl")
        }

        @Test func storeKeepsTheMostRecentPairingPerAccessory() throws {
            let home = try TestSupportModule.makeTemporaryDirectory(prefix: "cbctl-store")
            defer { try? FileManager.default.removeItem(at: home) }
            let store = HAPControllerStore(directory: home.appending(path: "store"))
            #expect(try store.loadIdentity() == nil)
            let identity = try store.loadOrCreateIdentity()
            #expect(try store.loadOrCreateIdentity() == identity)
            let first = HAPAccessoryPairing(accessoryPairingID: "AA:AA:AA:AA:AA:01", accessoryLongTermPublicKey: randomData(32))
            let second = HAPAccessoryPairing(accessoryPairingID: "AA:AA:AA:AA:AA:02", accessoryLongTermPublicKey: randomData(32))
            try store.save(HAPControllerStore.StoredAccessory(host: "127.0.0.1", port: 1000, pairing: first))
            try store.save(HAPControllerStore.StoredAccessory(host: "::1", port: 2000, pairing: second))
            #expect(try store.accessory(matching: nil).pairing == second)
            #expect(try store.accessory(matching: "127.0.0.1:1000").pairing == first)
            #expect(try store.accessory(matching: "[::1]:2000").pairing == second)
            #expect(try store.accessory(matching: "aa:aa:aa:aa:aa:01").pairing == first)
            #expect(throws: HAPControllerStoreError.unknownAccessory("127.0.0.1:3000")) { try store.accessory(matching: "127.0.0.1:3000") }
            // Re-pairing the same endpoint replaces the old entry and becomes the most recent.
            let renewed = HAPAccessoryPairing(accessoryPairingID: "AA:AA:AA:AA:AA:03", accessoryLongTermPublicKey: randomData(32))
            try store.save(HAPControllerStore.StoredAccessory(host: "127.0.0.1", port: 1000, pairing: renewed))
            #expect(try store.accessories().map(\.pairing) == [second, renewed])
            try store.remove(accessoryPairingID: renewed.accessoryPairingID)
            #expect(try store.accessories().map(\.pairing) == [second])
        }
    }
}


// MARK: - The controller against a real HAPCamera accessory (W2-1) with fake delegates

private struct FakeDelegateError: Error {}

/// Streaming delegate of the HAPCamera accessory: `prepareStream` binds two loopback UDP sockets and echoes the
/// controller's SRTP keys, `.start` runs a real `LiveStreamSession` fed by `liveMedia`, `.stop` ends it.
private final class CameraStreamingFake: CameraStreamingDelegate {
    struct Prepared: Sendable {
        var request: PrepareStreamRequest
        var response: PrepareStreamResponse
        var video: UDPSocket
        var audio: UDPSocket
    }

    struct Running: Sendable {
        var session: LiveStreamSession
        var tasks: [Task<Void, Never>]
    }

    struct State: Sendable {
        var prepares: [PrepareStreamRequest] = []
        var requests: [StreamRequest] = []
        var snapshots: [SnapshotRequest] = []
        var prepared: [UUID: Prepared] = [:]
        var running: [UUID: Running] = [:]
    }

    let state = Box(State())
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x24, count: 2000) + Data([0xFF, 0xD9])

    func snapshot(_ request: SnapshotRequest) async throws -> Data {
        state.update { $0.snapshots.append(request) }
        return jpeg
    }

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        let video = try UDPSocket.bind(host: request.localAddress)
        let audio = try UDPSocket.bind(host: request.localAddress)
        let response = PrepareStreamResponse(accessoryAddress: request.localAddress, videoPort: video.localPort, audioPort: audio.localPort,
                                             videoSSRC: UInt32.random(in: 1...UInt32.max), audioSSRC: UInt32.random(in: 1...UInt32.max),
                                             videoSRTP: request.videoSRTP, audioSRTP: request.audioSRTP)
        state.update {
            $0.prepares.append(request)
            $0.prepared[request.sessionID] = Prepared(request: request, response: response, video: video, audio: audio)
        }
        return response
    }

    func handleStreamRequest(_ request: StreamRequest) async throws {
        state.update { $0.requests.append(request) }
        switch request {
        case .start(let sessionID, let video, let audio):
            guard let prepared = state.value.prepared[sessionID] else { throw FakeDelegateError() }
            let response = prepared.response
            let audioParameters = audio.map { audio in
                LiveAudioParameters(codec: .opus, payloadType: audio.payloadType, ssrc: response.audioSSRC, srtpKey: response.audioSRTP.masterKey,
                                    srtpSalt: response.audioSRTP.masterSalt, rtpClockRate: audio.sampleRate.hertz,
                                    packetTime: .milliseconds(Int64(audio.packetTimeMs)))
            }
            let session = LiveStreamSession(
                controller: SocketAddress(host: prepared.request.controllerAddress, port: 0), videoPort: prepared.request.controllerVideoPort,
                audioPort: prepared.request.controllerAudioPort, videoSocket: prepared.video, audioSocket: prepared.audio,
                video: LiveVideoParameters(payloadType: video.payloadType, ssrc: response.videoSSRC, srtpKey: response.videoSRTP.masterKey,
                                           srtpSalt: response.videoSRTP.masterSalt),
                audio: audioParameters, controllerTimeout: .seconds(10))
            let media = liveMedia(fps: video.resolution.fps, audioRate: audio?.sampleRate.hertz ?? 24_000)
            await session.start(video: media.video, audio: media.audio)
            state.update { $0.running[sessionID] = Running(session: session, tasks: media.tasks) }
        case .reconfigure:
            break
        case .stop(let sessionID):
            await end(sessionID)
        }
    }

    private func end(_ sessionID: UUID) async {
        let (running, prepared) = state.update { ($0.running.removeValue(forKey: sessionID), $0.prepared.removeValue(forKey: sessionID)) }
        running?.tasks.forEach { $0.cancel() }
        if let running {
            await running.session.stop()
        } else {
            prepared?.video.close()
            prepared?.audio.close()
        }
    }

    func stopAll() async {
        for sessionID in Set(state.value.prepared.keys).union(state.value.running.keys) { await end(sessionID) }
    }

    var startRequests: [(sessionID: UUID, video: SelectedVideoParameters, audio: SelectedAudioParameters?)] {
        state.value.requests.compactMap { if case .start(let id, let video, let audio) = $0 { (id, video, audio) } else { nil } }
    }

    var reconfigureRequests: [(sessionID: UUID, video: SelectedVideoParameters)] {
        state.value.requests.compactMap { if case .reconfigure(let id, let video) = $0 { (id, video) } else { nil } }
    }

    var stopRequests: [UUID] {
        state.value.requests.compactMap { if case .stop(let id) = $0 { id } else { nil } }
    }
}

/// Recording delegate: records every call; `recordingStream` hands out `packets` (the last one `isLast`) and keeps
/// the stream open until HAPCamera ends it.
private final class CameraRecordingFake: CameraRecordingDelegate {
    enum Call: Equatable, Sendable {
        case active(Bool)
        case configuration(CameraRecordingConfiguration?)
        case audioActive(Bool)
        case stream(Int)
        case acknowledge(Int)
        case close(Int, HDSProtocolReason?)
    }

    let packets: [Data]
    let calls = Box<[Call]>([])
    private let continuations = Box<[Int: AsyncThrowingStream<RecordingPacket, any Error>.Continuation]>([:])

    init(packets: [Data]) { self.packets = packets }

    func updateRecordingActive(_ active: Bool) async { calls.update { $0.append(.active(active)) } }
    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) async { calls.update { $0.append(.configuration(configuration)) } }
    func updateRecordingAudioActive(_ active: Bool) async { calls.update { $0.append(.audioActive(active)) } }

    func recordingStream(streamID: Int) async throws -> AsyncThrowingStream<RecordingPacket, any Error> {
        calls.update { $0.append(.stream(streamID)) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RecordingPacket.self)
        for (index, data) in packets.enumerated() { continuation.yield(RecordingPacket(data: data, isLast: index == packets.count - 1)) }
        continuations.update { $0[streamID] = continuation }
        return stream
    }

    func acknowledgeStream(streamID: Int) async { calls.update { $0.append(.acknowledge(streamID)) } }
    func closeRecordingStream(streamID: Int, reason: HDSProtocolReason?) async { calls.update { $0.append(.close(streamID, reason)) } }

    func finishAll() {
        for continuation in continuations.update({ $0.values.map { $0 } }) { continuation.finish() }
    }
}

/// A HAPCamera accessory (W2-1 `CameraController`) on a loopback `AccessoryServer` (never advertised).
private struct HAPCameraAccessory {
    static let info = AccessoryInfo(name: "Loopback Camera", manufacturer: "CameraBridge", model: "HAPCamera", serialNumber: "CAM-SELFTEST",
                                    firmwareRevision: "1.0.0")
    static func configuration(isDoorbell: Bool = false) -> CameraControllerConfiguration {
        CameraControllerConfiguration(
            streamCount: 2,
            streaming: CameraStreamingOptions(resolutions: [VideoResolution(1920, 1080, 30), VideoResolution(1280, 720, 30),
                                                            VideoResolution(640, 360, 30)],
                                              twoWayAudio: false),
            recording: CameraRecordingOptions(resolutions: [VideoResolution(1280, 720, 30), VideoResolution(1920, 1080, 30)]),
            isDoorbell: isDoorbell)
    }

    let server: AccessoryServer
    let dataStream: DataStreamServer
    let camera: CameraController
    let transport: AppleNetworkTransport
    let port: UInt16
    let setupCode: String

    static func start(streaming: CameraStreamingFake, recording: CameraRecordingFake, isDoorbell: Bool = false) async throws -> HAPCameraAccessory {
        let transport = AppleNetworkTransport()
        let accessory = Accessory(info: info, category: isDoorbell ? .videoDoorbell : .ipCamera)
        let server = AccessoryServer(accessory: accessory, configuration: AccessoryServerConfiguration(port: 0, advertise: false,
                                                                                                        serviceName: "Loopback Camera", loopbackOnly: true),
                                     store: InMemoryHAPStore(), transport: transport, advertiser: NullServiceAdvertiser())
        let dataStream = DataStreamServer(transport: transport, loopbackOnly: true)
        let camera = CameraController(configuration: configuration(isDoorbell: isDoorbell), streamingDelegate: streaming, recordingDelegate: recording,
                                      dataStreamServer: dataStream)
        await camera.install(on: accessory, server: server)
        try await server.start()
        return HAPCameraAccessory(server: server, dataStream: dataStream, camera: camera, transport: transport, port: try #require(await server.port),
                                  setupCode: try await server.setupCode.formatted)
    }

    func stop() async {
        await dataStream.stop()
        await server.stop()
    }
}

extension ControllerSelfTests {
    /// Plan W2-2: the controller end to end against a real HAPCamera accessory with fake delegates — pair,
    /// /accessories, SetupEndpoints → start → reconfigure → suspend (-70410) → end, snapshot, motion events, recording
    /// selection and activation, SetupDataStreamTransport → HDS → `dataSend` open → init + fragments → ack. Always runs:
    /// a `CameraController.install` that stopped adding the camera services fails it.
    @Suite struct HAPCameraAccessoryTests {
        @Test(.timeLimit(.minutes(3)))
        func pairStreamSnapshotMotionAndRecord() async throws {
            let streaming = CameraStreamingFake()
            let packets = [randomData(1500), randomData(300_000), randomData(4000)]
            let recording = CameraRecordingFake(packets: packets)
            let accessory = try await HAPCameraAccessory.start(streaming: streaming, recording: recording)
            let controller = try await HAPTestController.paired(port: accessory.port, setupCode: accessory.setupCode)

            // /accessories: the services a hub uses, found by type.
            let ids = try await controller.cameraIDs()
            #expect(ids.streams.count == 2)
            let recordingIDs = try #require(ids.recording)
            let motion = try #require(ids.motionDetected)
            let setupTransport = try #require(ids.setupDataStreamTransport)
            #expect(ids.homeKitCameraActive != nil)
            let stream = ids.streams[0]
            let supported = try await controller.supportedStreamingConfiguration(stream)
            #expect(supported.video.codecs.first?.resolutions.contains(ControllerTLV.Resolution(1280, 720, 30)) == true)
            #expect(supported.audio.codecs.first?.codec == 3)
            #expect(supported.rtp.cryptoSuites == [0])
            #expect(try await controller.streamingStatus(stream) == .available)

            // Live stream: SetupEndpoints → prepareStream, start → the delegate's LiveStreamSession → our receiver.
            let started = ContinuousClock.now
            let live = try await controller.startLiveStream(stream)
            let prepare = try #require(streaming.state.value.prepares.first)
            #expect(prepare.sessionID == live.sessionID)
            #expect(prepare.controllerAddress == "127.0.0.1" && !prepare.isIPv6 && prepare.localAddress == "127.0.0.1")
            #expect(prepare.controllerVideoPort == live.receiver.videoPort && prepare.controllerAudioPort == live.receiver.audioPort)
            #expect(prepare.videoSRTP.masterKey == live.receiver.videoKeys.masterKey && prepare.videoSRTP.masterSalt == live.receiver.videoKeys.masterSalt)
            #expect(prepare.audioSRTP.masterKey == live.receiver.audioKeys.masterKey)
            let start = try #require(streaming.startRequests.first)
            #expect(start.sessionID == live.sessionID)
            #expect(start.video.resolution == VideoResolution(1280, 720, 30))
            #expect(start.video.profile == .main && start.video.level == .level4_0)
            #expect(start.video.payloadType == live.video.payloadType && start.video.controllerSSRC == live.video.ssrc)
            #expect(start.video.maxBitrateKbps == Int(live.video.maxBitrateKbps) && start.video.mtu == 1378)
            #expect(start.audio?.codec == .opus && start.audio?.sampleRate == .khz24 && start.audio?.packetTimeMs == 20)
            #expect(start.audio?.controllerSSRC == live.audio?.ssrc)
            #expect(try await controller.streamingStatus(stream) == .inUse)
            #expect(accessory.camera.activeLiveStreams == 1)
            var frames: [ReceivedVideoFrame] = []
            for await frame in live.receiver.videoFrames {
                frames.append(frame)
                if frames.count == 20 { break }
            }
            #expect(frames.first?.isKeyframe == true)
            #expect(frames.allSatisfy { $0.isComplete })
            let firstKeyframe = try #require(await live.receiver.firstKeyframeAt)
            #expect(firstKeyframe - started < .seconds(2))
            #expect(await live.receiver.waitFor(timeout: .seconds(5)) { $0.audioFrames >= 5 })
            let stats = await live.receiver.statistics
            #expect(stats.authenticationFailures == 0 && stats.unexpectedSSRCPackets == 0)

            try await live.reconfigure(resolution: ControllerTLV.Resolution(640, 360, 30), maxBitrateKbps: 500)
            let reconfigured = try #require(streaming.reconfigureRequests.last)
            #expect(reconfigured.sessionID == live.sessionID)
            #expect(reconfigured.video.resolution == VideoResolution(640, 360, 30) && reconfigured.video.maxBitrateKbps == 500)
            await #expect(throws: HAPControllerError.characteristicStatus(aid: stream.aid, iid: stream.selectedConfiguration.iid,
                                                                         status: HAPStatus.invalidValue.rawValue)) {
                try await controller.selectStream(stream, ControllerTLV.SelectedRTPStreamConfiguration(sessionID: live.sessionID, command: .suspend))
            }
            try await live.stop(keepReceiver: true)
            #expect(streaming.stopRequests == [live.sessionID])
            #expect(await live.receiver.waitFor(timeout: .seconds(3)) { $0.byes >= 1 })
            #expect(try await controller.streamingStatus(stream) == .available)
            await live.receiver.stop()

            // Recording configuration and activation reach the recording delegate.
            let supportedRecording = try await controller.supportedRecordingConfiguration(recordingIDs)
            let selection = try ControllerTLV.SelectedCameraRecordingConfiguration.preferred(camera: supportedRecording.camera,
                                                                                             video: supportedRecording.video,
                                                                                             audio: supportedRecording.audio)
            try await controller.selectRecordingConfiguration(recordingIDs, selection)
            try await controller.enableRecording(ids, audio: true)
            #expect(await eventually { recording.calls.value.contains(.active(true)) && recording.calls.value.contains(.audioActive(true)) })
            let configurations = recording.calls.value.compactMap { call -> CameraRecordingConfiguration? in
                if case .configuration(let configuration?) = call { configuration } else { nil }
            }
            let configured = try #require(configurations.last)
            #expect(configured.resolution == VideoResolution(selection.resolution.width, selection.resolution.height, selection.resolution.fps))
            #expect(configured.fragmentLengthMs == Int(selection.container.fragmentLengthMs))
            #expect(configured.prebufferLengthMs == Int(selection.prebufferLengthMs))
            #expect(configured.eventTriggers == selection.eventTriggers)
            #expect(configured.videoProfile.rawValue == selection.videoProfile && configured.videoLevel.rawValue == selection.videoLevel)
            #expect(configured.videoBitrateKbps == Int(selection.videoBitrateKbps) && configured.iFrameIntervalMs == Int(selection.iFrameIntervalMs))
            #expect(configured.audioSampleRate.rawValue == selection.audioSampleRate && configured.audioMaxBitrateKbps == Int(selection.audioMaxBitrateKbps))

            // Snapshot through /resource (event snapshots are on now) and a motion event.
            let jpeg = try await controller.snapshot(width: 640, height: 360, aid: ids.aid, reason: 1)
            #expect(jpeg == streaming.jpeg)
            let snapshot = try #require(streaming.state.value.snapshots.last)
            #expect(snapshot.width == 640 && snapshot.height == 360 && snapshot.reason == .event)
            try await controller.subscribe([motion])
            accessory.camera.setMotionDetected(true)
            #expect(try await controller.nextEvent(for: motion).value.hapBool == true)

            // HKSV: SetupDataStreamTransport → HDS → dataSend open → init + fragments → ack.
            let dataStream = try await controller.openDataStream(setupTransport)
            let open = try await dataStream.openRecording(streamID: 1)
            #expect(open.isAccepted)
            let capture = try await dataStream.receiveRecording(streamID: 1)
            #expect(capture.initialization == packets[0])
            #expect(capture.fragments == Array(packets.dropFirst()))
            #expect(capture.chunkCounts == [1, 2, 1])
            #expect(capture.endOfStream)
            #expect(capture.mp4 == packets.reduce(Data(), +))
            try await dataStream.ackRecording(streamID: 1)
            #expect(await eventually { recording.calls.value.contains(.acknowledge(1)) })
            #expect(recording.calls.value.contains(.stream(1)))
            #expect(await eventually { accessory.camera.activeRecordingStreams == 0 })

            await dataStream.close()
            await controller.close()
            recording.finishAll()
            await streaming.stopAll()
            await accessory.stop()
        }

        /// `dataSend/open` refusals as the controller reads them (brief §3.8: inactive → 1, wrong type → 5, busy → 2),
        /// and a doorbell ring reaching a subscriber.
        @Test(.timeLimit(.minutes(3)))
        func dataSendRefusalsAndDoorbell() async throws {
            let streaming = CameraStreamingFake()
            let recording = CameraRecordingFake(packets: [randomData(800), randomData(2000)])
            let accessory = try await HAPCameraAccessory.start(streaming: streaming, recording: recording, isDoorbell: true)
            let controller = try await HAPTestController.paired(port: accessory.port, setupCode: accessory.setupCode)
            let ids = try await controller.cameraIDs()
            let recordingIDs = try #require(ids.recording)

            let doorbell = try #require(ids.programmableSwitchEvent)
            try await controller.subscribe([doorbell])
            accessory.camera.ringDoorbell()
            #expect(try await controller.nextEvent(for: doorbell).value == .int(0))

            let supported = try await controller.supportedRecordingConfiguration(recordingIDs)
            try await controller.selectRecordingConfiguration(recordingIDs, try .preferred(camera: supported.camera, video: supported.video,
                                                                                          audio: supported.audio))
            let dataStream = try await controller.openDataStream(try #require(ids.setupDataStreamTransport))
            try await controller.writeValue(recordingIDs.active, .int(0))
            let inactive = try await dataStream.openRecording(streamID: 1)
            #expect(!inactive.isAccepted && inactive.status == .protocolSpecificError && inactive.protocolReason == .notAllowed)

            try await controller.enableRecording(ids, audio: false)
            let wrongType = try await dataStream.openRecording(streamID: 1, type: "ipcamera.snapshot")
            #expect(wrongType.protocolReason == .unexpectedFailure)
            let open = try await dataStream.openRecording(streamID: 2)
            #expect(open.isAccepted)
            let busy = try await dataStream.openRecording(streamID: 3)
            #expect(busy.protocolReason == .busy)
            let capture = try await dataStream.receiveRecording(streamID: 2)
            #expect(capture.endOfStream && capture.fragments.count == 1)
            try await dataStream.closeRecording(streamID: 2, reason: .cancelled)
            #expect(await eventually { recording.calls.value.contains(.close(2, .cancelled)) })

            await dataStream.close()
            await controller.close()
            recording.finishAll()
            await accessory.stop()
        }
    }
}

#endif
