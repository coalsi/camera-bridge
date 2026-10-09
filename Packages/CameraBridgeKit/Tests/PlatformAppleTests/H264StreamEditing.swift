// Same helper as Tests/RTSPTests/H264StreamEditing.swift (test targets cannot share sources).
import Foundation
import MediaCore

/// Rewrites CAVLC (Baseline) H.264 NAL units at the bit level, to make a stream like a camera's that uses more than one PPS:
/// a slice's pic_parameter_set_id and a PPS's own id. CABAC slice data is byte aligned after the header, so only Baseline
/// streams (VideoToolbox: `.baseline`) can be edited this way.
enum H264StreamEditing {
    /// The RBSP bits of `nal` (header byte dropped, emulation prevention removed) without rbsp_trailing_bits.
    private static func payloadBits(_ nal: Data) -> [UInt8] {
        var bits: [UInt8] = []
        for byte in NALUnits.removeEmulationPrevention(Data(nal.dropFirst())) {
            for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> UInt8(shift)) & 1) }
        }
        while bits.last == 0 { bits.removeLast() }
        if !bits.isEmpty { bits.removeLast() }   // the stop bit
        return bits
    }

    /// A NAL unit of `header` with `bits` as payload: stop bit, zero padding to a byte, emulation prevention.
    private static func nal(header: UInt8, bits: [UInt8]) -> Data {
        var padded = bits + [1]
        while padded.count % 8 != 0 { padded.append(0) }
        var out: [UInt8] = [header]
        var zeros = 0
        for start in stride(from: 0, to: padded.count, by: 8) {
            let byte = padded[start..<(start + 8)].reduce(UInt8(0)) { $0 << 1 | $1 }
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data(out)
    }

    private static func ue(_ value: UInt32) -> [UInt8] {
        let code = UInt64(value) + 1
        let length = 64 - code.leadingZeroBitCount
        return [UInt8](repeating: 0, count: length - 1) + (0..<length).reversed().map { UInt8((code >> UInt64($0)) & 1) }
    }

    /// Reads the ue(v) at `position`; returns it and the position after it.
    private static func readUE(_ bits: [UInt8], _ position: Int) -> (value: UInt32, next: Int) {
        var index = position
        var zeros = 0
        while bits[index] == 0 {
            zeros += 1
            index += 1
        }
        index += 1
        var value: UInt64 = 1
        for _ in 0..<zeros {
            value = value << 1 | UInt64(bits[index])
            index += 1
        }
        return (UInt32(value - 1), index)
    }

    /// `slice` (a type 1 or 5 NAL unit) with pic_parameter_set_id `id`: the third ue(v) of the header.
    static func slice(_ slice: Data, ppsID id: UInt32) -> Data {
        let bits = payloadBits(slice)
        let afterFirstMB = readUE(bits, 0).next
        let afterType = readUE(bits, afterFirstMB).next
        let afterPPS = readUE(bits, afterType).next
        return nal(header: slice[slice.startIndex], bits: Array(bits[..<afterType]) + ue(id) + Array(bits[afterPPS...]))
    }

    /// `pps` with pic_parameter_set_id `id` (and seq_parameter_set_id `spsID` when given).
    static func pps(_ pps: Data, id: UInt32, spsID: UInt32? = nil) -> Data {
        let bits = payloadBits(pps)
        let afterID = readUE(bits, 0)
        let afterSPS = readUE(bits, afterID.next)
        return nal(header: pps[pps.startIndex], bits: ue(id) + ue(spsID ?? afterSPS.value) + Array(bits[afterSPS.next...]))
    }

    /// `sps` with seq_parameter_set_id `id` (the ue(v) after profile_idc, the constraint flags and level_idc).
    static func sps(_ sps: Data, id: UInt32) -> Data {
        let bits = payloadBits(sps)
        return nal(header: sps[sps.startIndex], bits: Array(bits[..<24]) + ue(id) + Array(bits[readUE(bits, 24).next...]))
    }

    /// pic_parameter_set_id a slice refers to.
    static func ppsID(ofSlice slice: Data) -> UInt32 {
        let bits = payloadBits(slice)
        let afterType = readUE(bits, readUE(bits, 0).next).next
        return readUE(bits, afterType).value
    }
}
