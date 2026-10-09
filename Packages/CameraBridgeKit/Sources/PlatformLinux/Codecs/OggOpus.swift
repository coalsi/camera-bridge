import Foundation

// Opus packets reach ffmpeg and leave it inside Ogg (RFC 3533 / RFC 7845): ffmpeg has no raw-packet Opus format, and Ogg is
// the one container every build has. One packet per page, so a packet is complete the moment ffmpeg writes it.

enum OggOpus {
    /// Samples at 48 kHz in one Opus packet (RFC 6716 §3.1: TOC byte, frame count code), nil for a malformed packet.
    static func samples48k(_ packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        // Frame duration in units of 2.5 ms (SILK 10/20/40/60, hybrid 10/20, CELT 2.5/5/10/20).
        let units: Int = switch config {
        case 0...11: [4, 8, 16, 24][config % 4]
        case 12...15: [4, 8][config % 2]
        default: [1, 2, 4, 8][config % 4]
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        guard frames > 0, frames * units <= 48 else { return nil }
        return frames * units * 120   // 2.5 ms = 120 samples at 48 kHz
    }

    // MARK: Writer (stream into ffmpeg)

    /// Writes an Ogg Opus stream: the two header pages, then one page per packet.
    struct Writer {
        private let serial: UInt32 = 0x4342_4F50
        private var sequence: UInt32 = 0
        private var granule: Int64 = 0
        private let preSkip = 312
        private var wroteHeaders = false
        let channels: Int
        let inputRate: Int

        init(channels: Int, inputRate: Int) {
            self.channels = channels
            self.inputRate = inputRate
        }

        mutating func headers() -> Data {
            guard !wroteHeaders else { return Data() }
            wroteHeaders = true
            var head = Data("OpusHead".utf8)
            head.append(1)
            head.append(UInt8(channels))
            head.append(contentsOf: [UInt8(preSkip & 0xFF), UInt8(preSkip >> 8)])
            head.append(contentsOf: littleEndian32(UInt32(inputRate)))
            head.append(contentsOf: [0, 0])   // output gain
            head.append(0)                    // channel mapping family 0
            var tags = Data("OpusTags".utf8)
            let vendor = Data("CameraBridge".utf8)
            tags.append(contentsOf: littleEndian32(UInt32(vendor.count)))
            tags.append(vendor)
            tags.append(contentsOf: littleEndian32(0))
            return page(head, granule: 0, flags: 0x02) + page(tags, granule: 0, flags: 0x00)
        }

        mutating func packet(_ packet: Data) -> Data {
            granule += Int64(samples48k(packet) ?? 960)
            return headers() + page(packet, granule: granule + Int64(preSkip), flags: 0x00)
        }

        /// The last page of the stream (empty packet, end-of-stream flag).
        mutating func end() -> Data {
            page(Data(), granule: granule + Int64(preSkip), flags: 0x04)
        }

        private mutating func page(_ payload: Data, granule: Int64, flags: UInt8) -> Data {
            var lacing: [UInt8] = []
            var remaining = payload.count
            while remaining >= 255 {
                lacing.append(255)
                remaining -= 255
            }
            lacing.append(UInt8(remaining))
            var header = Data("OggS".utf8)
            header.append(0)
            header.append(flags)
            header.append(contentsOf: littleEndian64(UInt64(bitPattern: granule)))
            header.append(contentsOf: littleEndian32(serial))
            header.append(contentsOf: littleEndian32(sequence))
            sequence += 1
            header.append(contentsOf: [0, 0, 0, 0])   // checksum, filled below
            header.append(UInt8(lacing.count))
            header.append(contentsOf: lacing)
            var page = header + payload
            let checksum = OggCRC.checksum(page)
            page.replaceSubrange(22..<26, with: littleEndian32(checksum))
            return page
        }

        private func littleEndian32(_ value: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
        }

        private func littleEndian64(_ value: UInt64) -> [UInt8] {
            (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
        }
    }

    // MARK: Reader (stream out of ffmpeg)

    /// Reads Ogg pages incrementally and returns the audio packets (the OpusHead and OpusTags packets are skipped).
    struct Reader {
        private var buffer = Data()
        private var partial = Data()
        private var skippedHeaders = 0
        private(set) var failed = false
        /// Pre-skip from OpusHead (samples at 48 kHz the decoder drops at the start).
        private(set) var preSkip: Int?

        mutating func push(_ data: Data) -> [Data] {
            guard !failed else { return [] }
            buffer.append(data)
            var packets: [Data] = []
            var offset = 0
            while true {
                guard buffer.count - offset >= 27 else { break }
                guard buffer[offset..<(offset + 4)].elementsEqual("OggS".utf8) else {
                    failed = true
                    buffer = Data()
                    return packets
                }
                let segments = Int(buffer[offset + 26])
                guard buffer.count - offset >= 27 + segments else { break }
                let lacing = Array(buffer[(offset + 27)..<(offset + 27 + segments)])
                let bodySize = lacing.reduce(0) { $0 + Int($1) }
                guard buffer.count - offset >= 27 + segments + bodySize else { break }
                var cursor = offset + 27 + segments
                for value in lacing {
                    partial.append(buffer[cursor..<(cursor + Int(value))])
                    cursor += Int(value)
                    if value < 255 {
                        let packet = partial
                        partial = Data()
                        if skippedHeaders < 2 {
                            if skippedHeaders == 0, packet.count >= 12, packet.prefix(8) == Data("OpusHead".utf8) {
                                preSkip = Int(packet[10]) | Int(packet[11]) << 8
                            }
                            skippedHeaders += 1
                        } else if !packet.isEmpty {
                            packets.append(packet)
                        }
                    }
                }
                offset += 27 + segments + bodySize
            }
            buffer = Data(buffer[offset...])
            return packets
        }
    }
}

/// Ogg's CRC-32 (polynomial 0x04C11DB7, no reflection, zero start and end value).
enum OggCRC {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data { crc = (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(byte))] }
        return crc
    }
}
