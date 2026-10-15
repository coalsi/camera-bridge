import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// The page's live video: frames in, an init segment and one fragment per frame out.
@Suite struct LiveMP4RemuxerTests {
    static func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    static let format = VideoFormat.h264(sps: hex("6764001eacb201405ff2e022000003000200000300781e2c5c90"), pps: hex("68ebc3cb22c0"))!
    static let otherFormat = VideoFormat.h264(sps: hex("674d401facb201405ff2e022000003000200000300781e2c5c90"), pps: hex("68ebc3cb22c0"))!

    static func frame(_ index: Int64, key: Bool, format: VideoFormat = format, base: Int64 = 0) -> EncodedVideoFrame {
        let slice = Data([key ? 0x65 : 0x41, 0x88, 0x84, 0x00, 0x33, UInt8(index & 0xFF)])
        return EncodedVideoFrame(format: format, nalUnits: [slice], isKeyframe: key,
                                 pts: MediaTime(value: base + index * 3000, timescale: 90_000), wallClock: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func startsAtAKeyframeWithAnInitThenOneFragmentPerFrame() throws {
        var remuxer = LiveMP4Remuxer()
        #expect(try remuxer.push(Self.frame(0, key: false)).isEmpty, "nothing before the first keyframe")
        let first = try remuxer.push(Self.frame(1, key: true))
        guard case .initialization(let data, let mime, let width, let height)? = first.first, first.count == 1 else {
            Issue.record("expected one init segment, got \(first)")
            return
        }
        #expect(mime.hasPrefix("video/mp4; codecs=\"avc1.64001e"))
        #expect(width > 0 && height > 0 && data.count > 100)
        let second = try remuxer.push(Self.frame(2, key: false))
        guard case .media(let keyframeData, keyframe: true)? = second.first, second.count == 1 else {
            Issue.record("the keyframe's fragment comes once the next frame arrived: \(second)")
            return
        }
        #expect(keyframeData.count > 8)
        let third = try remuxer.push(Self.frame(3, key: false))
        guard case .media(_, keyframe: false)? = third.first else { Issue.record("then deltas: \(third)"); return }
    }

    @Test func timingThatRestartsBeginsANewInitAtTheKeyframe() throws {
        var remuxer = LiveMP4Remuxer()
        _ = try remuxer.push(Self.frame(1, key: true, base: 900_000))
        _ = try remuxer.push(Self.frame(2, key: false, base: 900_000))
        // The ingest reconnected: timestamps start again near zero.
        let parts = try remuxer.push(Self.frame(0, key: true))
        #expect(parts.contains { if case .initialization = $0 { true } else { false } }, "a new init for the new timeline: \(parts)")
        // A delta after a reconnect with timing that went backwards is dropped until a keyframe.
        var other = LiveMP4Remuxer()
        _ = try other.push(Self.frame(1, key: true, base: 900_000))
        _ = try other.push(Self.frame(2, key: false, base: 900_000))
        #expect(try other.push(Self.frame(0, key: false)).isEmpty)
        #expect(try other.push(Self.frame(1, key: false)).isEmpty, "still waiting for a keyframe")
    }

    @Test func aNewFormatBeginsANewInit() throws {
        var remuxer = LiveMP4Remuxer()
        _ = try remuxer.push(Self.frame(1, key: true))
        _ = try remuxer.push(Self.frame(2, key: false))
        let parts = try remuxer.push(Self.frame(3, key: true, format: Self.otherFormat))
        guard case .initialization(_, let mime, _, _)? = parts.first else { Issue.record("expected an init: \(parts)"); return }
        #expect(mime.contains("avc1.4d401f"))
    }

    static func sound(_ index: Int64) -> EncodedAudioFrame {
        EncodedAudioFrame(format: .aacLC(sampleRate: 16_000, channels: 1), data: Data([0x21, 0x10, 0x04, UInt8(index & 0xFF)]),
                          pts: MediaTime(value: index * 1024, timescale: 16_000), sampleCount: 1024, wallClock: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func soundJoinsAtTheNextKeyframeWithItsOwnTrack() throws {
        var remuxer = LiveMP4Remuxer(audio: true)
        _ = try remuxer.push(Self.frame(1, key: true))
        _ = try remuxer.push(Self.frame(2, key: false))
        remuxer.push(audio: Self.sound(3))
        #expect(try remuxer.push(Self.frame(3, key: false)).allSatisfy { if case .media = $0 { true } else { false } }, "no new init on a delta")
        let parts = try remuxer.push(Self.frame(4, key: true))
        guard case .initialization(_, let mime, _, _)? = parts.first else { Issue.record("a new init at the keyframe: \(parts)"); return }
        #expect(mime.hasSuffix(",mp4a.40.2\""))
        for index in Int64(6)...Int64(9) { remuxer.push(audio: Self.sound(index)) }
        let next = try remuxer.push(Self.frame(5, key: false))
        guard case .media(let data, keyframe: true)? = next.first else { Issue.record("the keyframe's fragment: \(next)"); return }
        #expect(data.count > 40, "video and the sound before the next frame")
        // Without audio asked for, sound is ignored.
        var silent = LiveMP4Remuxer()
        _ = try silent.push(Self.frame(1, key: true))
        silent.push(audio: Self.sound(1))
        #expect(try silent.push(Self.frame(2, key: true)).allSatisfy { if case .media = $0 { true } else { false } })
    }

    @Test func onlyAACLCPassesTheConverterAsItIs() {
        #expect(LiveAudioConverter.isAACLC(.aacLC(sampleRate: 16_000, channels: 1)))
        #expect(!LiveAudioConverter.isAACLC(AudioFormat(codec: .pcmu, sampleRate: 8_000, channels: 1)))
        #expect(!LiveAudioConverter.isAACLC(AudioFormat(codec: .aac, sampleRate: 16_000, channels: 1, audioSpecificConfig: Data([0xF8, 0xE8]))))
    }
}
