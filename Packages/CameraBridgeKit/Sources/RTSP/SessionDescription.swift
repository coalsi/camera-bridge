import BridgeSupport
import Foundation
import MediaCore

/// Maps a parsed SDP to `RTSPTrack`s and media formats.
enum RTSPSessionDescription {
    static let supportedVideoEncodings: Set<String> = ["H264", "H265"]
    /// Receive audio we can depacketize.
    static let supportedAudioEncodings: Set<String> = ["PCMU", "PCMA", "MPEG4-GENERIC"]
    /// Backchannel preference (µ-law first: Hikvision and Reolink talkback use G.711µ).
    static let backchannelPreference = ["PCMU", "PCMA", "MPEG4-GENERIC"]

    /// RTP clock rates accepted from an SDP: video is 90 kHz and audio at most 192 kHz, so anything outside is bogus.
    static let clockRateRange = 1...1_000_000
    /// Channel counts above this (7.1 audio) are bogus and clamped.
    static let maxChannels = 8

    /// One track per `m=video` / `m=audio` section. With `backchannelRequested` (the DESCRIBE carried
    /// `Require: www.onvif.org/ver20/backchannel`), audio sections marked `sendonly` are ONVIF backchannels; otherwise
    /// `sendonly` is the server's own view (RFC 3264: the camera sends) and the section is plain audio. Other media
    /// types (e.g. ONVIF metadata) are skipped. Per section, the payload type with a supported codec is chosen
    /// (backchannel: by `backchannelPreference`), else the first listed one.
    ///
    /// A clock rate outside `clockRateRange` (or missing) becomes 90 kHz for video (RFC 6184 §8.2.1 / RFC 7798 §7.1
    /// require it) and 8 kHz for G.711; other audio gets 0, which `isUsableAudio` rejects. Channel counts are clamped
    /// to 1…`maxChannels`.
    static func tracks(in sdp: SDPSession, backchannelRequested: Bool) -> [RTSPTrack] {
        sdp.media.compactMap { media -> RTSPTrack? in
            let kind: RTSPTrack.Kind
            switch media.type {
            case "video": kind = .video
            case "audio": kind = backchannelRequested && media.direction == "sendonly" ? .backchannel : .audio
            default: return nil
            }
            let candidates = media.formats.map { (payloadType: $0, map: media.rtpmap(for: $0)) }
            let chosen: (payloadType: UInt8, map: SDPRTPMap?)?
            switch kind {
            case .video:
                chosen = candidates.first { $0.map.map { supportedVideoEncodings.contains($0.encoding) } ?? false } ?? candidates.first
            case .audio:
                chosen = candidates.first { $0.map.map { supportedAudioEncodings.contains($0.encoding) } ?? false } ?? candidates.first
            case .backchannel:
                chosen = backchannelPreference.lazy.compactMap { name in candidates.first { $0.map?.encoding == name } }.first
                    ?? candidates.first
            }
            guard let chosen else { return nil }
            let map = chosen.map ?? SDPRTPMap(encoding: "", clockRate: kind == .video ? 90_000 : 8000)
            var clockRate = map.clockRate
            if !clockRateRange.contains(clockRate) {
                clockRate = kind == .video ? 90_000 : (["PCMU", "PCMA"].contains(map.encoding) ? 8000 : 0)
            }
            return RTSPTrack(kind: kind, control: media.control ?? "", payloadType: chosen.payloadType, encoding: map.encoding,
                             clockRate: clockRate, channels: min(max(1, map.channels), maxChannels), fmtp: media.fmtp(for: chosen.payloadType))
        }
    }

    /// H.264 or H.265 that `VideoDepacketizer` handles: not H.264 interleaved mode (`packetization-mode=2`: STAP-B,
    /// MTAP and FU-B in decoding-order-number order).
    static func isSupportedVideo(_ track: RTSPTrack) -> Bool {
        guard track.kind == .video, supportedVideoEncodings.contains(track.encoding) else { return false }
        if track.encoding == "H264", track.fmtp["packetization-mode"]?.trimmingCharacters(in: .whitespaces) == "2" { return false }
        return true
    }

    /// Why `isSupportedVideo` is false, for `RTSPError.unsupportedCodec`. The encoding name is the camera's text (an
    /// SDP may be megabytes long): cut and without control characters (`Redact.cameraText`).
    static func unsupportedDescription(_ track: RTSPTrack) -> String {
        supportedVideoEncodings.contains(track.encoding) ? "\(track.encoding) packetization-mode=2" : Redact.cameraText(track.encoding)
    }

    /// Receive audio this module can depacketize and describe, with a sane clock rate.
    static func isUsableAudio(_ track: RTSPTrack) -> Bool {
        track.kind == .audio && clockRateRange.contains(track.clockRate) && AudioDepacketizer(track: track) != nil && audioFormat(for: track) != nil
    }

    /// Format from `sprop-parameter-sets` (H.264) or `sprop-vps/sps/pps` (H.265); nil when the SDP carries no
    /// parameter sets (they then arrive in band) or the codec is unsupported.
    static func videoFormat(for track: RTSPTrack) -> VideoFormat? {
        switch track.encoding {
        case "H264":
            let units = (track.fmtp["sprop-parameter-sets"] ?? "").split(separator: ",").compactMap { decodeBase64(String($0)) }
            // Every SPS and PPS the SDP lists (a stream may use several PPS), not just the first of each.
            return H264ParameterSetStore(parameterSets: units).format
        case "H265":
            func first(_ key: String) -> Data? {
                (track.fmtp[key] ?? "").split(separator: ",").lazy.compactMap { decodeBase64(String($0)) }.first
            }
            guard let vps = first("sprop-vps"), let sps = first("sprop-sps"), let pps = first("sprop-pps") else { return nil }
            return makeHEVCFormat(vps: vps, sps: sps, pps: pps)
        default:
            return nil
        }
    }

    /// PCMU / PCMA at the rtpmap rate, or AAC (`mpeg4-generic` with `config=`) from its AudioSpecificConfig.
    static func audioFormat(for track: RTSPTrack) -> AudioFormat? {
        switch track.encoding {
        case "PCMU":
            return AudioFormat(codec: .pcmu, sampleRate: track.clockRate > 0 ? track.clockRate : 8000, channels: track.channels)
        case "PCMA":
            return AudioFormat(codec: .pcma, sampleRate: track.clockRate > 0 ? track.clockRate : 8000, channels: track.channels)
        case "MPEG4-GENERIC":
            let mode = (track.fmtp["mode"] ?? "").lowercased()
            guard mode.hasPrefix("aac"), let hex = track.fmtp["config"], let config = Data(hex: hex), !config.isEmpty else { return nil }
            let parsed = AudioSpecificConfig(config)
            let codec: AudioCodec = parsed?.objectType == AudioSpecificConfig.aacELD ? .aacELD : .aac
            let sampleRate = parsed?.sampleRate ?? track.clockRate
            let channels = parsed.map { $0.channels > 0 ? $0.channels : track.channels } ?? track.channels
            return AudioFormat(codec: codec, sampleRate: sampleRate, channels: channels, audioSpecificConfig: config)
        default:
            return nil
        }
    }

    /// `VideoFormat.h264`, or a format without dimensions when the SPS does not parse (the parameter sets are still
    /// what a decoder needs).
    static func makeH264Format(sps: Data, pps: Data) -> VideoFormat {
        if let format = VideoFormat.h264(sps: sps, pps: pps) { return format }
        let bytes = [UInt8](sps)
        return VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: [sps, pps],
                           profile: bytes.count > 1 ? bytes[1] : 0, profileCompatibility: bytes.count > 2 ? bytes[2] : 0,
                           level: bytes.count > 3 ? bytes[3] : 0)
    }

    static func makeHEVCFormat(vps: Data, sps: Data, pps: Data) -> VideoFormat {
        VideoFormat.hevc(vps: vps, sps: sps, pps: pps)
            ?? VideoFormat(codec: .hevc, width: 0, height: 0, parameterSets: [vps, sps, pps])
    }

    /// Standard or URL-safe base64, with or without padding.
    static func decodeBase64(_ text: String) -> Data? {
        var normalized = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty else { return nil }
        while normalized.count % 4 != 0 { normalized.append("=") }
        guard let data = Data(base64Encoded: normalized), !data.isEmpty else { return nil }
        return data
    }
}

/// RTSP URL helpers.
enum RTSPURL {
    /// Resolves an SDP `a=control` value against the session base URL the way ffmpeg and live555 do: absolute URLs
    /// are kept, `*` or empty means the base, an absolute path replaces the base path, and anything else is appended
    /// to the base with one `/` in between.
    static func resolve(control: String, base: String) -> String {
        let trimmed = control.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "*" { return base }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("rtsp://") || lower.hasPrefix("rtsps://") || lower.hasPrefix("rtspu://") { return trimmed }
        if trimmed.hasPrefix("/") {
            if let schemeEnd = base.range(of: "://") {
                let authorityEnd = base[schemeEnd.upperBound...].firstIndex(where: { $0 == "/" || $0 == "?" }) ?? base.endIndex
                return String(base[..<authorityEnd]) + trimmed
            }
            return trimmed
        }
        return base.hasSuffix("/") ? base + trimmed : base + "/" + trimmed
    }

    /// The URL as sent in request lines: user info removed.
    static func requestString(for url: URL) -> String {
        url.removingUserInfo.absoluteString
    }

    /// `user:password@` from the URL (percent-decoded), if present.
    static func embeddedCredentials(in url: URL) -> HTTPCredentials? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let user = components.user, !user.isEmpty else {
            return nil
        }
        return HTTPCredentials(username: user, password: components.password ?? "")
    }
}
