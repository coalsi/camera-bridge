import Foundation

public enum VideoCodec: String, Sendable, Codable { case h264, hevc }

public enum AudioCodec: String, Sendable, Codable { case aac, aacELD, opus, pcmu, pcma, linearPCM }

/// A rational media timestamp. Equality, hashing and ordering compare the represented time, so
/// `90000/90000 == 48000/48000`. A negative timescale negates the time (`1/-1` is −1 s); a zero timescale
/// represents time 0 (as in `seconds` and `converted(to:)`).
public struct MediaTime: Sendable, Hashable, Comparable, Codable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    /// Rounds to the nearest tick. Never traps: NaN → 0, and values beyond Int64 (including ±infinity) saturate
    /// to `Int64.max` / `Int64.min`.
    public static func seconds(_ s: Double, timescale: Int32 = 90_000) -> MediaTime {
        let ticks = (s * Double(timescale)).rounded()
        let value: Int64
        if let exact = Int64(exactly: ticks) {
            value = exact
        } else if ticks.isNaN {
            value = 0
        } else {
            value = ticks < 0 ? .min : .max
        }
        return MediaTime(value: value, timescale: timescale)
    }

    public var seconds: Double {
        timescale == 0 ? 0 : Double(value) / Double(timescale)
    }

    /// Rescales to `timescale`, rounding to nearest (half away from zero). Uses 128-bit intermediates.
    public func converted(to timescale: Int32) -> MediaTime {
        guard timescale != self.timescale else { return self }
        guard self.timescale != 0, timescale != 0 else { return MediaTime(value: 0, timescale: timescale) }
        return MediaTime(value: Self.rescale(value, from: Int64(self.timescale), to: Int64(timescale)), timescale: timescale)
    }

    /// Result in `lhs.timescale`.
    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        MediaTime(value: lhs.value &- rhs.converted(to: lhs.timescale).value, timescale: lhs.timescale)
    }

    /// Result in `lhs.timescale`.
    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        MediaTime(value: lhs.value &+ rhs.converted(to: lhs.timescale).value, timescale: lhs.timescale)
    }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool { compare(lhs, rhs) < 0 }

    public static func == (lhs: MediaTime, rhs: MediaTime) -> Bool { compare(lhs, rhs) == 0 }

    /// Hashes the reduced fraction (sign, |numerator|, denominator), which is identical for every pair of values
    /// that `==` considers equal, including zero times with any timescale.
    public func hash(into hasher: inout Hasher) {
        let reduced = reducedFraction
        hasher.combine(reduced.negative)
        hasher.combine(reduced.numerator)
        hasher.combine(reduced.denominator)
    }

    /// The represented time as a reduced fraction with a positive denominator. Zero (including a zero timescale)
    /// is `(false, 0, 1)`. Uses magnitudes, so `Int64.min` and negative timescales never overflow.
    private var reducedFraction: (negative: Bool, numerator: UInt64, denominator: UInt64) {
        guard timescale != 0, value != 0 else { return (false, 0, 1) }
        let numerator = value.magnitude
        let denominator = UInt64(timescale.magnitude)
        let divisor = Self.gcd(numerator, denominator)
        return ((value < 0) != (timescale < 0), numerator / divisor, denominator / divisor)
    }

    /// Exact comparison of the represented times: sign(l.v/l.t − r.v/r.t) = sign(l.v·r.t − r.v·l.t) · sign(l.t·r.t),
    /// with 128-bit products. A zero timescale is treated as 0/1.
    private static func compare(_ lhs: MediaTime, _ rhs: MediaTime) -> Int {
        let l = lhs.timescale == 0 ? (Int64(0), Int64(1)) : (lhs.value, Int64(lhs.timescale))
        let r = rhs.timescale == 0 ? (Int64(0), Int64(1)) : (rhs.value, Int64(rhs.timescale))
        let a = l.0.multipliedFullWidth(by: r.1)
        let b = r.0.multipliedFullWidth(by: l.1)
        let difference: Int
        if a.high != b.high {
            difference = a.high < b.high ? -1 : 1
        } else if a.low != b.low {
            difference = a.low < b.low ? -1 : 1
        } else {
            return 0
        }
        return (l.1 < 0) == (r.1 < 0) ? difference : -difference
    }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    /// value × to / from, rounded to nearest, without intermediate overflow.
    private static func rescale(_ value: Int64, from: Int64, to: Int64) -> Int64 {
        let negative = ((value < 0) != (to < 0)) != (from < 0)
        let magnitude = value.magnitude.multipliedFullWidth(by: to.magnitude)
        let divisor = from.magnitude
        guard magnitude.high < divisor else { return negative ? .min : .max }
        let (quotient, remainder) = divisor.dividingFullWidth(magnitude)
        var result = quotient
        if remainder >= divisor - remainder { result &+= 1 }   // remainder ≥ divisor/2
        guard result <= UInt64(Int64.max) else { return negative ? .min : .max }
        return negative ? -Int64(result) : Int64(result)
    }
}

public struct VideoFormat: Sendable, Hashable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    /// H.264: [SPS, PPS]; HEVC: [VPS, SPS, PPS]; raw NAL units without start codes.
    public var parameterSets: [Data]
    /// H.264: avcC profile_idc / constraint flags / level_idc. HEVC: general_profile_idc, 0, general_level_idc.
    public var profile: UInt8
    public var profileCompatibility: UInt8
    public var level: UInt8

    public init(codec: VideoCodec, width: Int, height: Int, parameterSets: [Data], profile: UInt8 = 0, profileCompatibility: UInt8 = 0, level: UInt8 = 0) {
        self.codec = codec
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.profile = profile
        self.profileCompatibility = profileCompatibility
        self.level = level
    }

    /// Parses the SPS for size, profile and level. `sps` includes its NAL header byte.
    public static func h264(sps: Data, pps: Data) -> VideoFormat? {
        guard sps.count >= 4, let parsed = H264SPS.parse(sps) else { return nil }
        return VideoFormat(codec: .h264, width: parsed.width, height: parsed.height, parameterSets: [Data(sps), Data(pps)],
                           profile: parsed.profileIDC, profileCompatibility: parsed.constraintFlags, level: parsed.levelIDC)
    }

    /// Parses the SPS for size, profile and level. NAL units include their 2-byte headers.
    public static func hevc(vps: Data, sps: Data, pps: Data) -> VideoFormat? {
        guard let parsed = HEVCSPS.parse(sps) else { return nil }
        return VideoFormat(codec: .hevc, width: parsed.width, height: parsed.height, parameterSets: [Data(vps), Data(sps), Data(pps)],
                           profile: parsed.generalProfileIDC, profileCompatibility: 0, level: parsed.generalLevelIDC)
    }
}

public struct AudioFormat: Sendable, Hashable {
    public var codec: AudioCodec
    public var sampleRate: Int
    public var channels: Int
    /// AAC / AAC-ELD AudioSpecificConfig.
    public var audioSpecificConfig: Data?

    public init(codec: AudioCodec, sampleRate: Int, channels: Int, audioSpecificConfig: Data? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.audioSpecificConfig = audioSpecificConfig
    }

    /// AAC 1024, AAC-ELD 480 (HomeKit's 30 ms @ 16 kHz framing), Opus 960 (20 ms @ 48 kHz equivalent),
    /// G.711 / LPCM 0 (variable).
    public var samplesPerFrame: Int {
        switch codec {
        case .aac: 1024
        case .aacELD: 480
        case .opus: 960
        case .pcmu, .pcma, .linearPCM: 0
        }
    }

    /// AAC-LC with its AudioSpecificConfig (ISO/IEC 14496-3 §1.6.2.1, written by `AudioSpecificConfig.encoded`): object
    /// type 2, sampling frequency index (explicit 24-bit frequency for rates outside the table, making the config 5
    /// bytes instead of 2), channel configuration (8 channels → 7), GASpecificConfig all zero (1024-sample frames).
    /// No config for a rate 24 bits cannot carry (negative, 2²⁴ Hz and above).
    public static func aacLC(sampleRate: Int, channels: Int) -> AudioFormat {
        let channelConfiguration = channels == 8 ? 7 : min(max(channels, 0), 7)
        let config = AudioSpecificConfig(objectType: AudioSpecificConfig.aacLC, sampleRate: sampleRate, channelConfiguration: channelConfiguration)
        return AudioFormat(codec: .aac, sampleRate: sampleRate, channels: channels, audioSpecificConfig: config.encoded)
    }
}

public struct EncodedVideoFrame: Sendable {
    public var format: VideoFormat
    /// Access-unit NAL units without start codes/length prefixes; parameter sets and AUDs removed.
    public var nalUnits: [Data]
    public var isKeyframe: Bool
    /// 90 kHz presentation time. Monotonic per source session unless the source reorders (B-frames): it then steps back
    /// in decode order and `dts` is set.
    public var pts: MediaTime
    /// Decode time, nil when equal to pts. `dts ?? pts` increases strictly per source session.
    public var dts: MediaTime?
    public var wallClock: Date

    public init(format: VideoFormat, nalUnits: [Data], isKeyframe: Bool, pts: MediaTime, dts: MediaTime? = nil, wallClock: Date) {
        self.format = format
        self.nalUnits = nalUnits
        self.isKeyframe = isKeyframe
        self.pts = pts
        self.dts = dts
        self.wallClock = wallClock
    }

    /// AVCC/HVCC: each NAL prefixed by its 4-byte big-endian length.
    public var lengthPrefixedData: Data {
        var out = Data(capacity: nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            let length = UInt32(truncatingIfNeeded: nal.count)
            out.append(contentsOf: [UInt8(length >> 24), UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
            out.append(nal)
        }
        return out
    }

    /// Annex B: each NAL prefixed by `00 00 00 01`.
    public var annexBData: Data {
        var out = Data(capacity: nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(nal)
        }
        return out
    }
}

public struct EncodedAudioFrame: Sendable {
    public var format: AudioFormat
    /// One codec access unit: raw AAC AU (no ADTS), one Opus packet, or G.711 bytes.
    public var data: Data
    /// Timescale = sample rate.
    public var pts: MediaTime
    public var sampleCount: Int
    public var wallClock: Date

    public init(format: AudioFormat, data: Data, pts: MediaTime, sampleCount: Int, wallClock: Date) {
        self.format = format
        self.data = data
        self.pts = pts
        self.sampleCount = sampleCount
        self.wallClock = wallClock
    }
}

public enum MediaSample: Sendable {
    case video(EncodedVideoFrame), audio(EncodedAudioFrame)

    public var wallClock: Date {
        switch self {
        case .video(let frame): frame.wallClock
        case .audio(let frame): frame.wallClock
        }
    }
}

public protocol MediaSource: AnyObject, Sendable {
    var displayName: String { get }
    /// Connects and starts delivering samples. The stream finishes (throwing) on disconnect; call again to reconnect.
    func samples() async throws -> AsyncThrowingStream<MediaSample, any Error>
    func stop() async
}

public struct StreamInfo: Sendable, Codable, Hashable {
    /// Never contains credentials.
    public var url: URL
    public var videoCodec: VideoCodec?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var audioCodec: AudioCodec?
    public var audioSampleRate: Int?
    public var audioChannels: Int?

    public init(url: URL, videoCodec: VideoCodec? = nil, width: Int? = nil, height: Int? = nil, fps: Double? = nil,
                audioCodec: AudioCodec? = nil, audioSampleRate: Int? = nil, audioChannels: Int? = nil) {
        self.url = url
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.fps = fps
        self.audioCodec = audioCodec
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
    }
}
