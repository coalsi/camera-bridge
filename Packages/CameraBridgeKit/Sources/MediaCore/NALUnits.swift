import Foundation

/// H.264 / HEVC NAL unit helpers.
public enum NALUnits {
    /// Splits an Annex B byte stream at 3- and 4-byte start codes. Bytes before the first start code are ignored,
    /// trailing zero bytes of each unit are trimmed and empty units are dropped. No start code → `[]`.
    public static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []   // index of the first byte after each 00 00 01
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Data] = []
        for (n, start) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            if end > start { units.append(Data(bytes[start..<end])) }
        }
        return units
    }

    /// Splits AVCC/HVCC data with big-endian length prefixes of `lengthSize` (1…4) bytes. Stops at a truncated unit.
    public static func splitLengthPrefixed(_ data: Data, lengthSize: Int = 4) -> [Data] {
        guard (1...4).contains(lengthSize) else { return [] }
        var units: [Data] = []
        var index = data.startIndex
        while data.endIndex - index >= lengthSize {
            var length = 0
            for k in 0..<lengthSize { length = length << 8 | Int(data[index + k]) }
            index += lengthSize
            guard data.endIndex - index >= length else { break }
            if length > 0 { units.append(Data(data[index..<(index + length)])) }
            index += length
        }
        return units
    }

    /// `nal[0] & 0x1F` (0 for empty input).
    public static func h264Type(_ nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return first & 0x1F
    }

    /// `(nal[0] >> 1) & 0x3F` (0 for empty input).
    public static func hevcType(_ nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return (first >> 1) & 0x3F
    }

    /// slice_type of an H.264 coded slice (NAL type 1 or 5): the second ue(v) of the slice header, after
    /// first_mb_in_slice (ITU-T H.264 §7.3.3; Table 7-6: 0…9, `% 5` gives P, B, I, SP, SI). Read with `BitReader` from
    /// the RBSP of the first 16 payload bytes, which hold both codes at every level (first_mb_in_slice < 2¹⁷). nil for
    /// other NAL types, a header that ends early or a code longer than 32 bits.
    package static func h264SliceType(_ nal: Data) -> UInt32? {
        let type = h264Type(nal)
        guard type == 1 || type == 5 else { return nil }
        var reader = BitReader(removeEmulationPrevention(Data(nal.dropFirst().prefix(16))))
        do {
            _ = try reader.ue()                           // first_mb_in_slice
            return try reader.ue()
        } catch {
            return nil
        }
    }

    /// first_mb_in_slice of an H.264 coded slice (NAL type 1 or 5): the first ue(v) of the slice header (§7.3.3). 0 starts
    /// a new picture unless slices arrive in arbitrary order. nil for other NAL types or a header that ends early.
    package static func h264FirstMBInSlice(_ nal: Data) -> UInt32? {
        let type = h264Type(nal)
        guard type == 1 || type == 5 else { return nil }
        var reader = BitReader(removeEmulationPrevention(Data(nal.dropFirst().prefix(8))))
        return try? reader.ue()
    }

    /// first_slice_segment_in_pic_flag of an HEVC VCL NAL unit (types 0…31): the first bit after the 2-byte header
    /// (§7.3.6.1). nil for other NAL types or a unit without a third byte.
    package static func hevcFirstSliceSegmentInPicture(_ nal: Data) -> Bool? {
        guard nal.count >= 3, hevcType(nal) <= 31 else { return nil }
        return nal[nal.startIndex + 2] & 0x80 != 0
    }

    /// Removes emulation-prevention bytes (the `03` in `00 00 03`), turning a NAL payload into its RBSP.
    public static func removeEmulationPrevention(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var zeros = 0
        for byte in data {
            if zeros >= 2 && byte == 0x03 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}
