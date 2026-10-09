import BridgeSupport
import Foundation
import HAPCore
import Testing
@testable import HAPCamera

/// Plan W2-1 item 1: Supported* TLVs byte-exact to the HAP-NodeJS goldens (W1-9), plus the request/response TLVs of
/// SetupEndpoints, SelectedRTPStreamConfiguration, SelectedCameraRecordingConfiguration and SetupDataStreamTransport.
@Suite struct CameraTLVGoldenTests {
    @Test func supportedStreamingConfigurationsMatchGoldens() throws {
        let goldens = try CameraTLVGoldens.load()
        let encoderCases = goldens.streaming.filter { $0.decodeOnly != true }
        #expect(encoderCases.count >= 5)
        for golden in encoderCases {
            let options = try golden.options.cameraStreamingOptions()
            #expect(CameraTLV.supportedVideoStreamConfiguration(options).hexString == golden.supportedVideoStreamConfiguration, "\(golden.name)")
            #expect(CameraTLV.supportedAudioStreamConfiguration(options).hexString == golden.supportedAudioStreamConfiguration, "\(golden.name)")
            #expect(CameraTLV.supportedRTPConfiguration(options).hexString == golden.supportedRTPConfiguration, "\(golden.name)")
        }
    }

    @Test func briefReferenceVideoGolden() throws {
        // Research brief §3.5 (1080p30 + 720p30, all profiles and levels).
        let options = CameraStreamingOptions(resolutions: [VideoResolution(1920, 1080, 30), VideoResolution(1280, 720, 30)],
                                             profiles: [.baseline, .main, .high], levels: [.level3_1, .level3_2, .level4_0], twoWayAudio: false)
        #expect(CameraTLV.supportedVideoStreamConfiguration(options).hexString
            == "013e010100021d0101000000010101000001010202010000000201010000020102030100030b010280070202380403011e0000030b010200050202d00203011e")
        #expect(CameraTLV.supportedRTPConfiguration(options).hexString == "020100")
    }

    /// The list-delimiter golden (two audio codecs, two crypto suites, comfort noise on) cannot be built through the
    /// contract options; it checks the `00 00` list reading used by the parsers.
    @Test func listDelimiterGoldenParses() throws {
        let goldens = try CameraTLVGoldens.load()
        let golden = try #require(goldens.streaming.first { $0.decodeOnly == true })
        let audio = try TLVReader(hex(golden.supportedAudioStreamConfiguration))
        let codecs = CameraTLV.listValues(audio.items, type: 0x01)
        #expect(codecs.count == 2)
        let first = try TLVReader(codecs[0])
        let second = try TLVReader(codecs[1])
        #expect(first.uint8(0x01) == StreamingAudioCodec.opus.rawValue)
        #expect(second.uint8(0x01) == StreamingAudioCodec.aacELD.rawValue)
        let firstParameters = try #require(try first.nested(0x02))
        #expect(CameraTLV.listValues(firstParameters.items, type: 0x03).map { $0.first } == [1, 2])
        #expect(audio.uint8(0x02) == 1)
        let rtp = try TLVReader(hex(golden.supportedRTPConfiguration))
        #expect(CameraTLV.listValues(rtp.items, type: 0x02).map { $0.first } == [0, 1])
        let video = try #require(try TLVReader(hex(golden.supportedVideoStreamConfiguration)).nested(0x01))
        #expect(CameraTLV.listValues(video.items, type: 0x03).count == 2)
    }

    @Test func supportedRecordingConfigurationsMatchGoldens() throws {
        let goldens = try CameraTLVGoldens.load()
        #expect(goldens.recording.count >= 4)
        for golden in goldens.recording {
            let options = try golden.options.cameraRecordingOptions()
            let triggers = CameraTLV.eventTriggers(isDoorbell: golden.options.isDoorbell)
            #expect(triggers == golden.options.eventTriggers, "\(golden.name)")
            #expect(CameraTLV.supportedCameraRecordingConfiguration(options, eventTriggers: triggers).hexString
                == golden.supportedCameraRecordingConfiguration, "\(golden.name)")
            #expect(CameraTLV.supportedVideoRecordingConfiguration(options).hexString == golden.supportedVideoRecordingConfiguration, "\(golden.name)")
            #expect(CameraTLV.supportedAudioRecordingConfiguration(options).hexString == golden.supportedAudioRecordingConfiguration, "\(golden.name)")
        }
    }

    @Test func briefReferenceRecordingGoldens() throws {
        // Research brief §3.7.
        let options = CameraRecordingOptions(resolutions: [VideoResolution(1920, 1080, 30)], profiles: [.high], levels: [.level4_0])
        #expect(CameraTLV.supportedCameraRecordingConfiguration(options, eventTriggers: RecordingEventTrigger.motion).hexString
            == "0104a00f000002080100000000000000030b01010002060104a00f0000")
        #expect(CameraTLV.supportedVideoRecordingConfiguration(options).hexString == "01180101000206010102020102030b010280070202380403011e")
    }

    @Test func dataStreamStreamingStatusAndSetupEndpointsDefaults() throws {
        let goldens = try CameraTLVGoldens.load()
        #expect(CameraTLV.supportedDataStreamTransportConfiguration.hexString == goldens.dataStreamTransport.supportedDataStreamTransportConfiguration)
        #expect(CameraTLV.supportedDataStreamTransportConfiguration.hexString == "0103010100")
        #expect(CameraTLV.streamingStatus(.available).hexString == goldens.streamingStatus.available)
        #expect(CameraTLV.streamingStatus(.inUse).hexString == goldens.streamingStatus.inUse)
        #expect(CameraTLV.streamingStatus(.unavailable).hexString == goldens.streamingStatus.unavailable)
        #expect(CameraTLV.SetupEndpointsResponse.defaultValue.hexString == goldens.setupEndpointsDefault)
    }

    @Test func selectedRecordingConfigurationDecodesAndEncodes() throws {
        let goldens = try CameraTLVGoldens.load()
        #expect(goldens.selectedRecordingConfiguration.count == 2)
        for golden in goldens.selectedRecordingConfiguration {
            let encoded = try hex(golden.encoded)
            let expected = try golden.configuration.cameraRecordingConfiguration()
            #expect(try CameraTLV.parseSelectedRecordingConfiguration(encoded) == expected, "\(golden.name)")
            #expect(CameraTLV.selectedRecordingConfiguration(expected) == encoded, "\(golden.name)")
        }
    }

    @Test func malformedSelectedRecordingConfigurationThrows() throws {
        let goldens = try CameraTLVGoldens.load()
        let encoded = try hex(goldens.selectedRecordingConfiguration[0].encoded)
        #expect(throws: CameraTLVError.self) { try CameraTLV.parseSelectedRecordingConfiguration(Data()) }
        #expect(throws: CameraTLVError.self) { try CameraTLV.parseSelectedRecordingConfiguration(encoded.prefix(20)) }
        #expect(throws: CameraTLVError.self) { try CameraTLV.parseSelectedRecordingConfiguration(Data([0x01, 0x02, 0xFF])) }
        // Unknown profile value.
        var reader = try TLVReader(encoded)
        var video = try #require(try reader.nested(0x02)).items
        var parameters = try TLVReader(try #require(video.first { $0.type == 0x02 }).value).items
        parameters[0] = TLV8.Item(0x01, Data([9]))
        video = video.map { $0.type == 0x02 ? TLV8.Item(0x02, TLV8.encode(parameters)) : $0 }
        reader = TLVReader(items: reader.items.map { $0.type == 0x02 ? TLV8.Item(0x02, TLV8.encode(video)) : $0 })
        #expect(throws: CameraTLVError.self) { try CameraTLV.parseSelectedRecordingConfiguration(TLV8.encode(reader.items)) }
    }
}

@Suite struct CameraTLVRequestTests {
    static let srtp = SRTPParameters(suite: .aesCm128HmacSha1_80, masterKey: Data(repeating: 0x11, count: 16), masterSalt: Data(repeating: 0x22, count: 14))

    @Test func setupEndpointsRequestRoundTrip() throws {
        let request = CameraTLV.SetupEndpointsRequest(sessionID: UUID(), controllerAddress: "192.168.1.20", isIPv6: false, videoPort: 51_000,
                                                      audioPort: 51_002, videoSRTP: Self.srtp, audioSRTP: Self.srtp)
        let encoded = request.encoded
        let reader = try TLVReader(encoded)
        #expect(reader.data(0x01)?.count == 16)
        let address = try #require(try reader.nested(0x03))
        #expect(address.uint8(0x01) == 0 && address.string(0x02) == "192.168.1.20" && address.uint16LE(0x03) == 51_000)
        #expect(try CameraTLV.SetupEndpointsRequest(parsing: encoded) == request)
        #expect(throws: CameraTLVError.self) { try CameraTLV.SetupEndpointsRequest(parsing: encoded.prefix(10)) }
        #expect(throws: CameraTLVError.self) { try CameraTLV.SetupEndpointsRequest(parsing: Data([0x01, 0x03, 1, 2, 3])) }
    }

    @Test func setupEndpointsResponseLayout() throws {
        let id = UUID()
        let response = CameraTLV.SetupEndpointsResponse(sessionID: id, status: .success, accessoryAddress: "10.0.0.5", isIPv6: false,
                                                        videoPort: 40_000, audioPort: 40_002, videoSRTP: Self.srtp, audioSRTP: Self.srtp,
                                                        videoSSRC: 0x0102_0304, audioSSRC: 0x0A0B_0C0D)
        let reader = try TLVReader(response.encoded)
        #expect(reader.items.map(\.type) == [1, 2, 3, 4, 5, 6, 7])
        #expect(reader.data(0x06) == Data([0x04, 0x03, 0x02, 0x01]))
        #expect(try CameraTLV.SetupEndpointsResponse(parsing: response.encoded) == response)
        let busy = CameraTLV.SetupEndpointsResponse.failure(sessionID: id, status: .busy)
        #expect(try TLVReader(busy).items.map(\.type) == [1, 2])
        #expect(try TLVReader(busy).uint8(0x02) == 1)
    }

    @Test func selectedRTPStreamConfigurationStartRoundTrip() throws {
        let video = SelectedVideoParameters(profile: .main, level: .level4_0, resolution: VideoResolution(1280, 720, 30), payloadType: 99,
                                            controllerSSRC: 0xDEAD_BEEF, maxBitrateKbps: 299, rtcpIntervalSeconds: 0.5, mtu: 1378)
        let audio = SelectedAudioParameters(codec: .opus, channels: 1, sampleRate: .khz24, packetTimeMs: 20, payloadType: 110,
                                            controllerSSRC: 0x1234_5678, maxBitrateKbps: 24, rtcpIntervalSeconds: 5, comfortNoisePayloadType: 13)
        let configuration = CameraTLV.SelectedRTPStreamConfiguration(sessionID: UUID(), command: .start, video: video, audio: audio)
        let parsed = try CameraTLV.SelectedRTPStreamConfiguration(parsing: configuration.encoded)
        #expect(parsed == configuration)

        // Without comfort noise the payload type is not reported.
        var quiet = audio
        quiet.comfortNoisePayloadType = nil
        let noComfort = CameraTLV.SelectedRTPStreamConfiguration(sessionID: configuration.sessionID, command: .start, video: video, audio: quiet)
        #expect(try CameraTLV.SelectedRTPStreamConfiguration(parsing: noComfort.encoded).audio?.comfortNoisePayloadType == nil)
    }

    @Test func selectedRTPStreamConfigurationDefaultsMTUAndFillsReconfigure() throws {
        let id = UUID()
        // Start without MTU: IPv4 default 1378, IPv6 default 1228 (HAP-NodeJS).
        var rtp = TLVBuilder()
        rtp.add(0x01, uint8: 99)
        rtp.add(0x02, uint32LE: 7)
        rtp.add(0x03, uint16LE: 800)
        rtp.add(0x04, float32LE: 0.5)
        let video = Self.videoTLV(rtp: rtp, withParameters: true)
        let start = Self.selected(id: id, command: 1, video: video)
        #expect(try CameraTLV.SelectedRTPStreamConfiguration(parsing: start, defaultMTU: 1378).video?.mtu == 1378)
        #expect(try CameraTLV.SelectedRTPStreamConfiguration(parsing: start, defaultMTU: 1228).video?.mtu == 1228)

        // Reconfigure carries attributes + RTP only; the rest comes from the running session; RTCP interval 0 → 0.5.
        var reRTP = TLVBuilder()
        reRTP.add(0x03, uint16LE: 1500)
        reRTP.add(0x04, float32LE: 0)
        let reconfigure = Self.selected(id: id, command: 4, video: Self.videoTLV(rtp: reRTP, withParameters: false))
        let base = try #require(try CameraTLV.SelectedRTPStreamConfiguration(parsing: start, defaultMTU: 1378).video)
        let parsed = try CameraTLV.SelectedRTPStreamConfiguration(parsing: reconfigure, defaultMTU: 1378, base: base)
        #expect(parsed.command == .reconfigure)
        #expect(parsed.video?.maxBitrateKbps == 1500 && parsed.video?.rtcpIntervalSeconds == 0.5 && parsed.video?.payloadType == 99)
        #expect(parsed.video?.resolution == VideoResolution(640, 360, 15))
        // Without a base the reconfigure lacks required fields.
        #expect(throws: CameraTLVError.self) { try CameraTLV.SelectedRTPStreamConfiguration(parsing: reconfigure, defaultMTU: 1378) }
    }

    @Test func selectedRTPStreamConfigurationRejectsGarbage() {
        #expect(throws: CameraTLVError.self) { try CameraTLV.SelectedRTPStreamConfiguration(parsing: Data()) }
        #expect(throws: CameraTLVError.self) { try CameraTLV.SelectedRTPStreamConfiguration(parsing: Data([0x01, 0x03, 0x02, 0x01, 0x01])) }
        #expect(throws: CameraTLVError.self) { try CameraTLV.SelectedRTPStreamConfiguration(parsing: Data([0x01, 0xFF])) }
        // Unknown command.
        var control = TLVBuilder()
        control.add(0x01, Data(repeating: 1, count: 16))
        control.add(0x02, uint8: 9)
        var outer = TLVBuilder()
        outer.add(0x01, tlv: control)
        #expect(throws: CameraTLVError.self) { try CameraTLV.SelectedRTPStreamConfiguration(parsing: outer.data) }
    }

    @Test func dataStreamTransportRoundTrip() throws {
        let salt = Data(repeating: 0x5A, count: 32)
        let request = CameraTLV.SetupDataStreamTransportRequest(command: 0, transportType: 0, controllerKeySalt: salt)
        #expect(request.encoded.hexString == "010100020100" + "0320" + salt.hexString)
        #expect(try CameraTLV.SetupDataStreamTransportRequest(parsing: request.encoded) == request)
        let response = CameraTLV.SetupDataStreamTransportResponse(status: .success, port: 0x1234, accessoryKeySalt: salt)
        #expect(response.encoded.hexString == "010100" + "020401023412" + "0320" + salt.hexString)
        #expect(try CameraTLV.SetupDataStreamTransportResponse(parsing: response.encoded) == response)
        #expect(response.encodedWithoutSalt.hexString == "010100020401023412")
        #expect(throws: CameraTLVError.self) { try CameraTLV.SetupDataStreamTransportRequest(parsing: Data([0x01, 0x01])) }
    }

    // MARK: - Helpers

    static func videoTLV(rtp: TLVBuilder, withParameters: Bool) -> TLVBuilder {
        var video = TLVBuilder()
        if withParameters {
            video.add(0x01, uint8: 0)
            var parameters = TLVBuilder()
            parameters.add(0x01, uint8: 1)
            parameters.add(0x02, uint8: 2)
            parameters.add(0x03, uint8: 0)
            video.add(0x02, tlv: parameters)
        }
        var attributes = TLVBuilder()
        attributes.add(0x01, uint16LE: withParameters ? 1280 : 640)
        attributes.add(0x02, uint16LE: withParameters ? 720 : 360)
        attributes.add(0x03, uint8: withParameters ? 30 : 15)
        video.add(0x03, tlv: attributes)
        video.add(0x04, tlv: rtp)
        return video
    }

    static func selected(id: UUID, command: UInt8, video: TLVBuilder?) -> Data {
        var control = TLVBuilder()
        control.add(0x01, CameraTLV.bytes(of: id))
        control.add(0x02, uint8: command)
        var outer = TLVBuilder()
        outer.add(0x01, tlv: control)
        if let video { outer.add(0x02, tlv: video) }
        return outer.data
    }
}
