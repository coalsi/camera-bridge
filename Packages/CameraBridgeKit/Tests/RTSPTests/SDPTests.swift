import BridgeSupport
import Foundation
import MediaCore
import Testing
@testable import RTSP

/// Parameter sets produced by VideoToolbox on macOS 27 (captured once; the VideoToolbox-backed tests regenerate them).
enum RealParameterSets {
    /// H.264 Main, 640×360: SPS, PPS.
    static let h264Main640x360 = (sps: Data(hex: "274d001eab281405ff2a")!, pps: Data(hex: "28ee3c80")!)
    /// H.264 High 4.0, 1920×1080.
    static let h264High1080p = (sps: Data(hex: "27640028ac56501e0089f950")!, pps: Data(hex: "28ee3cb0")!)
    /// HEVC Main, 640×360: VPS, SPS, PPS.
    static let hevcMain640x360 = (vps: Data(hex: "40010c01ffff016000000300b0000003000003003f15c090")!,
                                  sps: Data(hex: "420101016000000300b0000003000003003fa005020171f2e2057b916544")!,
                                  pps: Data(hex: "4401c02cbd14d9")!)
}

@Suite struct SDPParsingTests {
    static let hikvision = """
    v=0\r
    o=- 1109162014219182 1109162014219192 IN IP4 192.0.2.79\r
    s=Media Presentation\r
    e=NONE\r
    b=AS:5100\r
    t=0 0\r
    a=control:rtsp://192.0.2.79:554/ISAPI/Streaming/channels/101/?transportmode=unicast\r
    m=video 0 RTP/AVP 96\r
    c=IN IP4 0.0.0.0\r
    b=AS:5000\r
    a=recvonly\r
    a=x-dimensions:1920,1080\r
    a=control:rtsp://192.0.2.79:554/ISAPI/Streaming/channels/101/trackID=1?transportmode=unicast\r
    a=rtpmap:96 H264/90000\r
    a=fmtp:96 profile-level-id=640028; packetization-mode=1; sprop-parameter-sets=J2QAKKxWUB4AiflQ,KO48sA==\r
    m=audio 0 RTP/AVP 0\r
    c=IN IP4 0.0.0.0\r
    b=AS:50\r
    a=recvonly\r
    a=control:rtsp://192.0.2.79:554/ISAPI/Streaming/channels/101/trackID=2?transportmode=unicast\r
    a=rtpmap:0 PCMU/8000\r
    a=Media_header:MEDIAINFO=494D4B48010200000400000110710110401F000000FA000000000000000000000000000000000000;\r
    a=appversion:1.0\r

    """

    static let reolink = """
    v=0
    o=- 1695818166813405 1 IN IP4 192.0.2.120
    s=Session streamed by "preview"
    i=0
    t=0 0
    a=tool:BC Streaming Media v202210012022.10.01
    a=type:broadcast
    a=control:*
    a=range:npt=now-
    m=video 0 RTP/AVP 96
    a=control:track1
    a=rtpmap:96 H264/90000
    a=fmtp:96 packetization-mode=1;profile-level-id=4D001E;sprop-parameter-sets=J00AHqsoFAX/Kg,KO48gA
    m=audio 0 RTP/AVP 97
    a=control:track2
    a=rtpmap:97 MPEG4-GENERIC/16000
    a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1408
    """

    static let hevc = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=HEVC
    t=0 0
    m=video 0 RTP/AVP 98
    a=rtpmap:98 H265/90000
    a=fmtp:98 sprop-vps=QAEMAf//AWAAAAMAsAAAAwAAAwA/FcCQ; sprop-sps=QgEBAWAAAAMAsAAAAwAAAwA/oAUCAXHy4gV7kWVE; sprop-pps=RAHALL0U2Q==
    a=control:trackID=0
    """

    static let onvifBackchannel = """
    v=0
    o=- 2890844256 2890842807 IN IP4 192.168.0.1
    s=RTSP Session with audiobackchannel
    t=0 0
    m=video 0 RTP/AVP 96
    a=control:rtsp://192.168.0.1/video
    a=rtpmap:96 H264/90000
    a=fmtp:96 packetization-mode=1;sprop-parameter-sets=J00AHqsoFAX/Kg==,KO48gA==
    a=recvonly
    m=audio 0 RTP/AVP 0
    a=control:rtsp://192.168.0.1/audio
    a=recvonly
    m=audio 0 RTP/AVP 8 0
    a=control:rtsp://192.168.0.1/audioback
    a=rtpmap:0 PCMU/8000
    a=rtpmap:8 PCMA/8000
    a=sendonly
    m=application 0 RTP/AVP 107
    a=control:rtsp://192.168.0.1/metadata
    a=rtpmap:107 vnd.onvif.metadata/90000
    """

    @Test func hikvisionVideoAndPCMU() throws {
        let sdp = try SDPSession.parse(Self.hikvision)
        #expect(sdp.media.count == 2)
        #expect(sdp.control == "rtsp://192.0.2.79:554/ISAPI/Streaming/channels/101/?transportmode=unicast")

        let video = try #require(sdp.media.first)
        #expect(video.type == "video")
        #expect(video.port == 0)
        #expect(video.proto == "RTP/AVP")
        #expect(video.formats == [96])
        #expect(video.direction == "recvonly")
        #expect(video.control == "rtsp://192.0.2.79:554/ISAPI/Streaming/channels/101/trackID=1?transportmode=unicast")
        #expect(video.rtpmap(for: 96) == SDPRTPMap(encoding: "H264", clockRate: 90_000, channels: 1))
        let fmtp = video.fmtp(for: 96)
        #expect(fmtp["packetization-mode"] == "1")
        #expect(fmtp["sprop-parameter-sets"] == "J2QAKKxWUB4AiflQ,KO48sA==")
        #expect(video.attributes.contains { $0.0 == "x-dimensions" && $0.1 == "1920,1080" })

        let audio = sdp.media[1]
        #expect(audio.formats == [0])
        #expect(audio.rtpmap(for: 0) == SDPRTPMap(encoding: "PCMU", clockRate: 8000, channels: 1))

        let tracks = RTSPSessionDescription.tracks(in: sdp, backchannelRequested: false)
        #expect(tracks.map(\.kind) == [.video, .audio])
        #expect(tracks[0].encoding == "H264")
        #expect(tracks[0].payloadType == 96)
        #expect(tracks[0].clockRate == 90_000)
        #expect(tracks[1].encoding == "PCMU")
        #expect(tracks[1].clockRate == 8000)

        let format = try #require(RTSPSessionDescription.videoFormat(for: tracks[0]))
        #expect(format.codec == .h264)
        #expect(format.width == 1920)
        #expect(format.height == 1080)
        #expect(format.profile == 100)
        #expect(format.parameterSets == [RealParameterSets.h264High1080p.sps, RealParameterSets.h264High1080p.pps])
        #expect(RTSPSessionDescription.audioFormat(for: tracks[1]) == AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))
    }

    @Test func reolinkVideoAndAAC() throws {
        let sdp = try SDPSession.parse(Self.reolink)
        #expect(sdp.control == "*")
        let tracks = RTSPSessionDescription.tracks(in: sdp, backchannelRequested: false)
        #expect(tracks.map(\.kind) == [.video, .audio])
        #expect(tracks[0].control == "track1")
        #expect(tracks[1].control == "track2")
        #expect(tracks[1].encoding == "MPEG4-GENERIC")
        #expect(tracks[1].clockRate == 16_000)
        #expect(tracks[1].channels == 1)
        // fmtp keys are case-insensitive: stored lowercased.
        #expect(tracks[1].fmtp["sizelength"] == "13")
        #expect(tracks[1].fmtp["mode"] == "AAC-hbr")
        #expect(tracks[1].fmtp["config"] == "1408")

        // Base64 without padding is accepted.
        let video = try #require(RTSPSessionDescription.videoFormat(for: tracks[0]))
        #expect(video.width == 640)
        #expect(video.height == 360)

        let audio = try #require(RTSPSessionDescription.audioFormat(for: tracks[1]))
        #expect(audio.codec == .aac)
        #expect(audio.sampleRate == 16_000)
        #expect(audio.channels == 1)
        #expect(audio.audioSpecificConfig == Data([0x14, 0x08]))
    }

    @Test func hevcParameterSets() throws {
        let tracks = RTSPSessionDescription.tracks(in: try SDPSession.parse(Self.hevc), backchannelRequested: false)
        #expect(tracks.count == 1)
        #expect(tracks[0].encoding == "H265")
        #expect(tracks[0].fmtp["sprop-vps"] == "QAEMAf//AWAAAAMAsAAAAwAAAwA/FcCQ")
        let format = try #require(RTSPSessionDescription.videoFormat(for: tracks[0]))
        #expect(format.codec == .hevc)
        #expect(format.width == 640)
        #expect(format.height == 360)
        #expect(format.parameterSets == [RealParameterSets.hevcMain640x360.vps, RealParameterSets.hevcMain640x360.sps,
                                         RealParameterSets.hevcMain640x360.pps])
    }

    @Test func onvifBackchannelIsSendonlyAudio() throws {
        let sdp = try SDPSession.parse(Self.onvifBackchannel)
        #expect(sdp.media.map(\.type) == ["video", "audio", "audio", "application"])
        #expect(sdp.media[2].direction == "sendonly")
        #expect(sdp.media[2].formats == [8, 0])

        let tracks = RTSPSessionDescription.tracks(in: sdp, backchannelRequested: true)
        #expect(tracks.map(\.kind) == [.video, .audio, .backchannel])
        // Static payload type 0 without rtpmap is PCMU/8000.
        #expect(tracks[1].encoding == "PCMU")
        #expect(tracks[1].clockRate == 8000)
        // The backchannel prefers µ-law even when it is not listed first.
        #expect(tracks[2].payloadType == 0)
        #expect(tracks[2].encoding == "PCMU")
        #expect(tracks[2].control == "rtsp://192.168.0.1/audioback")
        #expect(RTSPSessionDescription.audioFormat(for: tracks[2]) == AudioFormat(codec: .pcmu, sampleRate: 8000, channels: 1))
    }

    @Test func sendonlyAudioIsPlainAudioWhenNoBackchannelWasRequested() throws {
        // Without `Require: www.onvif.org/ver20/backchannel` an ONVIF server lists no backchannel, so `sendonly` is the
        // server's own view (RFC 3264): the camera sends this audio.
        let sdp = try SDPSession.parse("v=0\na=sendonly\nm=video 0 RTP/AVP 96\na=rtpmap:96 H264/90000\nm=audio 0 RTP/AVP 0\n")
        #expect(RTSPSessionDescription.tracks(in: sdp, backchannelRequested: false).map(\.kind) == [.video, .audio])
        #expect(RTSPSessionDescription.tracks(in: sdp, backchannelRequested: true).map(\.kind) == [.video, .backchannel])
    }

    @Test func interleavedPacketizationModeIsUnsupported() throws {
        let sdp = try SDPSession.parse("""
        v=0
        m=video 0 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=fmtp:96 packetization-mode=2;sprop-interleaving-depth=4
        m=video 0 RTP/AVP 97
        a=rtpmap:97 H264/90000
        a=fmtp:97 packetization-mode=1
        """)
        let tracks = RTSPSessionDescription.tracks(in: sdp, backchannelRequested: false)
        #expect(tracks.map(RTSPSessionDescription.isSupportedVideo) == [false, true])
    }

    @Test func sessionLevelDirectionIsInherited() throws {
        let sdp = try SDPSession.parse("v=0\na=sendonly\nm=audio 0 RTP/AVP 0\nm=video 0 RTP/AVP 96\na=recvonly\n")
        #expect(sdp.media[0].direction == "sendonly")
        #expect(sdp.media[1].direction == "recvonly")
    }

    @Test func portWithCountAndAttributeValuesContainingColons() throws {
        let sdp = try SDPSession.parse("v=0\nm=video 5000/2 RTP/AVP 96 97\na=control:rtsp://h:554/a:b\na=rtpmap:97 H265/90000\na=flag\n")
        let media = try #require(sdp.media.first)
        #expect(media.port == 5000)
        #expect(media.formats == [96, 97])
        #expect(media.control == "rtsp://h:554/a:b")
        #expect(media.attributes.contains { $0.0 == "flag" && $0.1 == nil })
        // Video prefers a payload type with a supported codec.
        let tracks = RTSPSessionDescription.tracks(in: sdp, backchannelRequested: false)
        #expect(tracks.first?.payloadType == 97)
        #expect(tracks.first?.encoding == "H265")
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: RTSPError.self) { try SDPSession.parse("") }
        #expect(throws: RTSPError.self) { try SDPSession.parse("hello world") }
        #expect(throws: RTSPError.self) { try SDPSession.parse("v=0\nm=video\n") }
        #expect(throws: RTSPError.self) { try SDPSession.parse("v=0\nm=video abc RTP/AVP 96\n") }
    }

    @Test func unsupportedCodecsHaveNoFormat() throws {
        let sdp = try SDPSession.parse("v=0\nm=video 0 RTP/AVP 26\nm=audio 0 RTP/AVP 97\na=rtpmap:97 L16/16000/2\n")
        let tracks = RTSPSessionDescription.tracks(in: sdp, backchannelRequested: false)
        #expect(tracks.map(\.encoding) == ["JPEG", "L16"])
        #expect(tracks[1].channels == 2)
        #expect(RTSPSessionDescription.videoFormat(for: tracks[0]) == nil)
        #expect(RTSPSessionDescription.audioFormat(for: tracks[1]) == nil)
    }
}

@Suite struct ControlURLTests {
    @Test func relativeControlIsAppendedToBase() {
        #expect(RTSPURL.resolve(control: "trackID=1", base: "rtsp://h:554/ISAPI/Streaming/channels/101/")
            == "rtsp://h:554/ISAPI/Streaming/channels/101/trackID=1")
        #expect(RTSPURL.resolve(control: "track1", base: "rtsp://h/h264Preview_01_main") == "rtsp://h/h264Preview_01_main/track1")
    }

    @Test func absoluteControlIsKept() {
        #expect(RTSPURL.resolve(control: "rtsp://192.168.0.1/audioback", base: "rtsp://h/stream/") == "rtsp://192.168.0.1/audioback")
        #expect(RTSPURL.resolve(control: "RTSP://H/x", base: "rtsp://h/stream/") == "RTSP://H/x")
    }

    @Test func wildcardAndEmptyMeanBase() {
        #expect(RTSPURL.resolve(control: "*", base: "rtsp://h/stream/") == "rtsp://h/stream/")
        #expect(RTSPURL.resolve(control: "", base: "rtsp://h/stream") == "rtsp://h/stream")
    }

    @Test func absolutePathReplacesPath() {
        #expect(RTSPURL.resolve(control: "/media/track2", base: "rtsp://h:8554/stream/") == "rtsp://h:8554/media/track2")
    }

    @Test func requestURLNeverContainsCredentials() throws {
        let url = try #require(URL(string: "rtsp://admin:secret@192.168.1.5:554/Streaming/101?x=1"))
        #expect(RTSPURL.requestString(for: url) == "rtsp://192.168.1.5:554/Streaming/101?x=1")
        let credentials = RTSPURL.embeddedCredentials(in: url)
        #expect(credentials == HTTPCredentials(username: "admin", password: "secret"))
        #expect(RTSPURL.embeddedCredentials(in: try #require(URL(string: "rtsp://h/x"))) == nil)
    }
}
