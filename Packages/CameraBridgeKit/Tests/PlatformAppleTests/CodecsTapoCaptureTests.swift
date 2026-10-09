// Decodes a local capture of a real TP-Link Tapo stream (H.264 Main@5.0 2688x1520, one SPS/PPS per IDR, a malformed vendor SEI
// before most pictures) through the decoder. The capture is private footage that is never committed: the test passes without
// doing anything when the file is absent. Set CAMERABRIDGE_TAPO_CAPTURE to a video.h264 (Annex B) elsewhere to run it there.
#if os(macOS)
import Foundation
import MediaCore
import Testing
@testable import PlatformApple

/// Annex B H.264 -> access units by the rules of ITU-T H.264 7.4.1.2.3: a new picture starts at the first VCL NAL with
/// first_mb_in_slice == 0, and AUD / SPS / PPS / SEI after a VCL NAL belong to the following picture.
enum AnnexBAccessUnits {
    struct Unit {
        var nalUnits: [Data]
        var isKeyframe: Bool
    }

    /// first_mb_in_slice (first ue(v) of the slice header).
    static func firstMB(_ nal: Data) -> UInt32? {
        var reader = BitReader(NALUnits.removeEmulationPrevention(Data(nal.dropFirst().prefix(8))))
        return try? reader.ue()
    }

    static func split(_ stream: Data) -> [Unit] {
        var units: [Unit] = []
        var current: [Data] = []
        var hasVCL = false
        var keyframe = false
        func finish() {
            if hasVCL { units.append(Unit(nalUnits: current, isKeyframe: keyframe)) }
            current = []
            hasVCL = false
            keyframe = false
        }
        for nal in NALUnits.splitAnnexB(stream) {
            switch NALUnits.h264Type(nal) {
            case 1, 5:
                if hasVCL, firstMB(nal) == 0 { finish() }
                hasVCL = true
                if NALUnits.h264Type(nal) == 5 { keyframe = true }
            case 6, 7, 8, 9:
                if hasVCL { finish() }
            default:
                break
            }
            current.append(nal)
        }
        finish()
        return units
    }
}

@Suite(.timeLimit(.minutes(3))) struct TapoCaptureTests {
    /// `Tools/captures/tapo.h264` in the repository (the captures folder is not committed), else `CAMERABRIDGE_TAPO_CAPTURE`.
    static let defaultPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Tools/captures/tapo.h264")
        .standardizedFileURL.path

    static func capture() -> Data? {
        let path = ProcessInfo.processInfo.environment["CAMERABRIDGE_TAPO_CAPTURE"] ?? defaultPath
        return FileManager.default.fileExists(atPath: path) ? try? Data(contentsOf: URL(fileURLWithPath: path)) : nil
    }

    /// Frames as the depacketizer is meant to deliver them: parameter sets and AUDs removed (they are in `format`),
    /// everything else (SEI included, unless `stripSEI`) kept. Timestamps at 20 fps.
    static func frames(from stream: Data, stripSEI: Bool) -> [EncodedVideoFrame] {
        var store = H264ParameterSetStore()
        let units = AnnexBAccessUnits.split(stream)
        for unit in units { for nal in unit.nalUnits { store.add(nal) } }
        guard let format = store.format else { return [] }
        let start = Date()
        return units.enumerated().map { index, unit in
            let nals = unit.nalUnits.filter { nal in
                switch NALUnits.h264Type(nal) {
                case 7, 8, 9: false
                case 6: !stripSEI
                default: true
                }
            }
            return EncodedVideoFrame(format: format, nalUnits: nals, isKeyframe: unit.isKeyframe,
                                     pts: MediaTime(value: Int64(index) * 4500, timescale: 90_000), wallClock: start.addingTimeInterval(Double(index) / 20))
        }
    }

    @Test(arguments: [false, true]) func everyPictureOfTheCaptureDecodes(stripSEI: Bool) throws {
        guard let stream = Self.capture() else { return }   // not on this machine
        let frames = Self.frames(from: stream, stripSEI: stripSEI)
        #expect(frames.count == 208)
        #expect(frames.filter(\.isKeyframe).count == 6)
        let decoder = try AppleVideoDecoder(format: try #require(frames.first).format)
        defer { decoder.invalidate() }
        var failures: [Int: any Error] = [:]
        var pictures = 0
        for (index, frame) in frames.enumerated() {
            do {
                pictures += try decoder.decodeAllNow(frame).count
            } catch {
                failures[index] = error
            }
        }
        let first = failures.sorted { $0.key < $1.key }.first.map { "#\($0.key) \($0.value)" } ?? ""
        #expect(failures.isEmpty, "\(failures.count) of \(frames.count) pictures failed, first: \(first)")
        #expect(pictures == frames.count)
    }

    @Test(arguments: [false, true]) func softwareDecoderDecodesEveryPictureOfTheCapture(stripSEI: Bool) throws {
        guard let stream = Self.capture() else { return }
        let frames = Self.frames(from: stream, stripSEI: stripSEI)
        let decoder = try AppleVideoDecoder(format: try #require(frames.first).format)
        defer { decoder.invalidate() }
        decoder.useSoftwareDecoding(reason: "test")
        var failed = 0
        for frame in frames {
            do { _ = try decoder.decodeAllNow(frame) } catch { failed += 1 }
        }
        #expect(failed == 0, "\(failed) pictures failed")
    }
}
#endif
