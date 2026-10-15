import BridgeEngine
import FMP4
import Foundation
import MediaCore

/// The frames of one fragment as the live path carries them: video in decode order, and the sound when it was asked for.
nonisolated struct DecodedFragment: Sendable {
    var video: [EncodedVideoFrame]
    var audio: [EncodedAudioFrame]
}

/// Where `CellPlayback` gets recorded frames from. `ArchiveFrameSource` reads fragments through `ArchiveReading` and the FMP4 parsers;
/// the cell's tests give it frames directly, so the playback logic is tested apart from the file format.
///
/// Frame times are the wall-clock times of Mac spec 4.3: `pts` is `MediaTime(value: wall ticks since 2001-01-01 at 90 kHz, timescale: 90_000)`
/// of the instant the frame belongs to (the fragment's start plus the durations of the samples before it, plus the composition offset).
/// Errors are `ArchiveError` (`.fileGone` and `.timedOut` mean the drive is not answering) or `FMP4Error` (a damaged fragment).
nonisolated protocol RecordedFrameSource: Sendable {
    /// `ftyp` + `moov` of the fragment's file, parsed. Called once per file by a cell.
    func initInfo(for fragment: ArchiveFragment) async throws -> FMP4InitInfo
    /// The first video frame of a keyframe fragment alone (one positioned read of its keyframe).
    func keyframe(of fragment: ArchiveFragment, info: FMP4InitInfo) async throws -> EncodedVideoFrame
    /// Every video frame of the fragment (and its audio frames when `withAudio`).
    func frames(of fragment: ArchiveFragment, info: FMP4InitInfo, withAudio: Bool) async throws -> DecodedFragment
}

/// The real source: bytes from the archive, frames from the FMP4 readers (`MovieFragmentReader`, `FMP4InitReader`, `FMP4FrameSlicer`).
nonisolated struct ArchiveFrameSource: RecordedFrameSource {
    let archive: any ArchiveReading

    func initInfo(for fragment: ArchiveFragment) async throws -> FMP4InitInfo {
        try FMP4InitReader.parse(try await archive.read(fragment, .initialization))
    }

    func keyframe(of fragment: ArchiveFragment, info: FMP4InitInfo) async throws -> EncodedVideoFrame {
        try FMP4FrameSlicer.frame(fromKeyframeBytes: try await archive.read(fragment, .keyframe), info: info, start: fragment.start)
    }

    func frames(of fragment: ArchiveFragment, info: FMP4InitInfo, withAudio: Bool) async throws -> DecodedFragment {
        let data = try await archive.read(fragment, .fragment)
        // prft + moof + mdat: the slicer counts sample offsets from the moof, so it is given where the moof starts.
        let boxes = try MP4BoxReader.parse(data)
        guard let moof = boxes.first(where: { $0.type == "moof" }), let mdat = boxes.first(where: { $0.type == "mdat" }) else {
            throw ArchiveError.unreadable("The fragment has no movie fragment box.")
        }
        let header = try MovieFragmentReader.parse(moof: data.subdata(in: moof.offset..<(moof.offset + moof.size)), mdatPayloadSize: mdat.payloadSize)
        guard let videoTrack = header.tracks.first(where: { $0.trackID == info.videoTrackID }) else {
            throw ArchiveError.unreadable("The fragment has no video track.")
        }
        let video = try FMP4FrameSlicer.videoFrames(header: header, bytes: data, bytesStart: moof.offset, info: info, fragmentStart: fragment.start,
                                                    samples: 0..<videoTrack.samples.count)
        var audio: [EncodedAudioFrame] = []
        if withAudio, info.audio != nil, let audioTrack = header.tracks.first(where: { $0.trackID == info.audioTrackID }) {
            audio = try FMP4FrameSlicer.audioFrames(header: header, bytes: data, bytesStart: moof.offset, info: info, fragmentStart: fragment.start,
                                                    samples: 0..<audioTrack.samples.count)
        }
        return DecodedFragment(video: video, audio: audio)
    }
}
