import Foundation
import MediaCore

/// Joins consecutive single-frame Opus packets into one packet of the requested packet time (RFC 6716 §3.2.5, code 3,
/// VBR, no padding). The encoder emits 20 ms packets; HomeKit asks for 20 ms on the LAN and 60 ms remotely (integration
/// brief §5.4). Packet times that are not a multiple of 20 ms round down (30 ms → 20 ms). Packets that cannot share a
/// code-3 packet — another TOC configuration or channel count, several frames already, a gap in the timeline, a frame
/// over 1275 bytes — end the pending group and go out as they are.
struct OpusRepacketizer: Sendable {
    /// 20 ms frames per output packet (1…6, at most 120 ms).
    let framesPerPacket: Int
    private var pending: [EncodedAudioFrame] = []

    static let frameDuration: Duration = .milliseconds(20)
    static let maximumFrameLength = 1_275

    init(packetTime: Duration) {
        let ratio = packetTime / Self.frameDuration
        framesPerPacket = ratio.isFinite ? max(1, min(6, Int((ratio + 1e-9).rounded(.down)))) : 1
    }

    /// Output packets completed by `frame` (in order).
    mutating func push(_ frame: EncodedAudioFrame) -> [EncodedAudioFrame] {
        guard let toc = frame.data.first else { return [] }
        guard framesPerPacket > 1 else { return [frame] }
        guard toc & 0x03 == 0, frame.data.count - 1 <= Self.maximumFrameLength else {
            return flushed() + [frame]
        }
        var output: [EncodedAudioFrame] = []
        if let last = pending.last, !Self.canFollow(last, with: frame) {
            output = flushed()
        }
        pending.append(frame)
        if pending.count >= framesPerPacket { output += flushed() }
        return output
    }

    /// The pending group as one packet (nil when nothing is pending).
    mutating func flush() -> EncodedAudioFrame? {
        flushed().first
    }

    private mutating func flushed() -> [EncodedAudioFrame] {
        defer { pending.removeAll() }
        guard let first = pending.first else { return [] }
        guard pending.count > 1 else { return [first] }
        var data = Data([(first.data[first.data.startIndex] & 0xFC) | 0x03, 0x80 | UInt8(pending.count)])
        for frame in pending.dropLast() {
            let length = frame.data.count - 1
            if length < 252 {
                data.append(UInt8(length))
            } else {
                let firstByte = 252 + (length - 252) % 4
                data.append(UInt8(firstByte))
                data.append(UInt8((length - firstByte) / 4))
            }
        }
        for frame in pending { data.append(frame.data.dropFirst()) }
        return [EncodedAudioFrame(format: first.format, data: data, pts: first.pts, sampleCount: pending.reduce(0) { $0 + $1.sampleCount },
                                  wallClock: first.wallClock)]
    }

    /// Same configuration and channel count (TOC bits 7–2) and contiguous in time.
    private static func canFollow(_ previous: EncodedAudioFrame, with next: EncodedAudioFrame) -> Bool {
        guard let a = previous.data.first, let b = next.data.first, a & 0xFC == b & 0xFC else { return false }
        let expected = previous.pts + MediaTime(value: Int64(previous.sampleCount), timescale: previous.pts.timescale)
        return next.pts == expected
    }
}
