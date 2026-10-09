#if os(macOS)
import AudioToolbox
import Foundation
import MediaCore
import Synchronization

/// Silent AAC-LC access units (recording audio for cameras without a microphone).
///
/// Encodes digital silence once per (rate, channels) with AudioToolbox and repeats a steady-state access unit (after
/// the encoder's priming packets); every copy decodes on its own to silence.
enum SilentAudio {
    private struct Key: Hashable {
        var sampleRate: Int
        var channels: Int
    }

    private static let cache = Mutex<[Key: Data]>([:])

    /// ⌈duration × sampleRate / 1024⌉ frames, PTS = `startPTS` (converted to the sample rate) + n × 1024, wall clock
    /// advancing by 1024 / sampleRate s. Throws `MediaCodecError.unsupported` for a non-positive rate or channel count.
    static func aacLCFrames(duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        guard sampleRate > 0, (1...8).contains(channels) else {
            throw MediaCodecError.unsupported("silent AAC at \(sampleRate) Hz × \(channels)")
        }
        let seconds = max(0, duration / .seconds(1))
        let count = Int((seconds * Double(sampleRate) / 1024).rounded(.up))
        guard count > 0 else { return [] }
        let accessUnit = try silentAccessUnit(Key(sampleRate: sampleRate, channels: channels))
        let format = AudioFormat.aacLC(sampleRate: sampleRate, channels: channels)
        let start = startPTS.converted(to: Int32(sampleRate)).value
        return (0..<count).map { index in
            EncodedAudioFrame(format: format, data: accessUnit, pts: MediaTime(value: start + Int64(index) * 1024, timescale: Int32(sampleRate)),
                              sampleCount: 1024, wallClock: wallClock.addingTimeInterval(Double(index) * 1024 / Double(sampleRate)))
        }
    }

    private static func silentAccessUnit(_ key: Key) throws -> Data {
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let encoder = try AudioConverterStream(from: .pcm16(sampleRate: key.sampleRate, channels: key.channels),
                                               to: .compressed(kAudioFormatMPEG4AAC, sampleRate: key.sampleRate, channels: key.channels, framesPerPacket: 1024))
        encoder.push(pcm: Data(count: 8 * 1024 * 2 * key.channels))
        let packets = try encoder.finish()
        // Past the priming packets (2112 samples) the encoder's output for silence is steady.
        guard packets.count >= 4 else { throw MediaCodecError.noFrame }
        let accessUnit = packets[packets.count / 2].data
        cache.withLock { $0[key] = accessUnit }
        return accessUnit
    }
}
#endif
