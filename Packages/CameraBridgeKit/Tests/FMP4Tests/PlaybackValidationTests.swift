#if canImport(VideoToolbox) && canImport(AVFoundation)
import AVFoundation
import Foundation
import MediaCore
import Synchronization
import Testing
import VideoToolbox
@testable import FMP4

private let ffprobePath = "/opt/homebrew/bin/ffprobe"
private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"

private func hevcEncoderAvailable() -> Bool {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: nil, width: 320, height: 240, codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                            compressionSessionOut: &session)
    if let session { VTCompressionSessionInvalidate(session) }
    return status == noErr
}

/// A recording written the way the HKSV pipeline will: init segment, then GOPFragmenter output muxed one fragment at a time.
private struct Recording {
    var url: URL
    var data: Data
    var fragmentCount: Int
    var videoFrames: Int
    var keyframes: [Bool]
    var audioFrames: Int
    var videoFormat: VideoFormat
    var decoderConfigurationAtom: Data?

    static func make(codec: VideoCodec, withAudio: Bool, producerReferenceTime: Bool = false,
                     seconds: Int = 3, fps: Int = 30, gopSeconds: Int = 1) throws -> Recording {
        let clip = try encodeVideo(codec: codec, fps: fps, gop: gopSeconds * fps, frameCount: seconds * fps)
        let audio = withAudio ? try encodeAAC(seconds: Double(seconds)) : []
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: clip.format, audio: withAudio ? aac : nil,
                                                                   writeProducerReferenceTime: producerReferenceTime))
        var fragmenter = GOPFragmenter(targetDuration: .seconds(gopSeconds))
        var samples: [(time: Double, sample: MediaSample)] = clip.frames.map { ($0.pts.seconds, .video($0)) }
        samples += audio.map { ($0.pts.seconds, .audio($0)) }
        samples = samples.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)

        var file = muxer.initializationSegment()
        var fragments = 0
        var audioFrames = 0
        var groups: [FragmentGroup] = []
        for entry in samples { groups += fragmenter.pushGroups(entry.sample) }
        if let tail = fragmenter.flushGroup() { groups.append(tail) }
        for group in groups {
            file.append(try muxer.fragment(group))
            fragments += 1
            audioFrames += group.audio.count
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "fmp4-\(UUID().uuidString).mp4")
        try file.write(to: url)
        return Recording(url: url, data: file, fragmentCount: fragments, videoFrames: clip.frames.count, keyframes: clip.frames.map(\.isKeyframe),
                         audioFrames: audioFrames,
                         videoFormat: clip.format, decoderConfigurationAtom: clip.decoderConfigurationAtom)
    }
}

private struct ProcessResult { var status: Int32; var output: String; var errors: String; var timedOut: Bool }

/// Runs a tool to completion, terminating it after `timeout` so a hung tool cannot outlive the test (the suite's time limit
/// only fails the test; it would leave the process and this blocked thread behind).
private func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let timedOut = Mutex(false)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        if finished.wait(timeout: .now() + timeout) == .timedOut, process.isRunning {
            timedOut.withLock { $0 = true }
            process.terminate()
        }
    }
    defer { finished.signal() }
    // Drain stderr concurrently so a chatty tool cannot block on a full pipe.
    let errorData = Mutex(Data())
    let drained = DispatchSemaphore(value: 0)
    let errorHandle = errors.fileHandleForReading
    DispatchQueue.global().async {
        let data = errorHandle.readDataToEndOfFile()
        errorData.withLock { $0 = data }
        drained.signal()
    }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    drained.wait()
    process.waitUntilExit()
    return ProcessResult(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                         errors: String(decoding: errorData.withLock { $0 }, as: UTF8.self), timedOut: timedOut.withLock { $0 })
}

@Suite(.timeLimit(.minutes(1))) struct PlaybackValidationTests {
    @Test func hungToolIsTerminated() throws {
        let start = Date()
        let result = try runTool("/bin/sleep", ["30"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func boxStructureOfARecording() throws {
        let recording = try Recording.make(codec: .h264, withAudio: true)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        // IDRs forced every second → three 1 s fragments.
        #expect(recording.keyframes.enumerated().allSatisfy { $0.element == ($0.offset % 30 == 0) }, "encoder keyframes at \(recording.keyframes.indices.filter { recording.keyframes[$0] })")
        #expect(recording.fragmentCount == 3)
        let boxes = try MP4BoxReader.parse(recording.data)
        #expect(boxes.map(\.type) == ["ftyp", "moov"] + Array(repeating: ["moof", "mdat"], count: recording.fragmentCount).flatMap { $0 })
        var expectedDecodeTime: UInt64 = 0
        var sampleIndex = 0
        for (sequence, moof) in boxes.filter({ $0.type == "moof" }).enumerated() {
            #expect(Bytes(try #require(moof.child("mfhd")).payload(in: recording.data)).u32(4) == UInt32(sequence + 1))
            let trafs = moof.children(ofType: "traf")
            #expect(trafs.count == 2)
            for traf in trafs { #expect(traf.children(ofType: "trun").count == 1) }
            let videoTraf = trafs[0]
            #expect(Bytes(try #require(videoTraf.child("tfdt")).payload(in: recording.data)).u64(4) == expectedDecodeTime)
            let run = try TrackRun(try #require(videoTraf.child("trun")), in: recording.data)
            #expect(run.samples.first?.flags == 0x0200_0000)
            let expectedFlags = recording.keyframes[sampleIndex..<sampleIndex + run.samples.count].map { $0 ? UInt32(0x0200_0000) : 0x0101_0000 }
            #expect(run.samples.map(\.flags) == expectedFlags, "fragment \(sequence)")
            sampleIndex += run.samples.count
            expectedDecodeTime += run.samples.reduce(0) { $0 + UInt64($1.duration) }
        }
        #expect(sampleIndex == recording.videoFrames)
        #expect(expectedDecodeTime == 270_000)
    }

    @Test func h264AndAACDecodeWithAVAssetReader() async throws {
        let recording = try Recording.make(codec: .h264, withAudio: true)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let report = try await readBack(recording.url)
        #expect(report.videoTrackCount == 1 && report.audioTrackCount == 1)
        #expect(report.decodedVideoFrames == recording.videoFrames)
        #expect(report.videoReaderCompleted)
        #expect(abs(report.duration - 3.0) < 0.1, "duration \(report.duration)")
        #expect(report.audioReaderCompleted)
        #expect(report.decodedAudioSamples > 32_000 * 5 / 2, "decoded \(report.decodedAudioSamples) audio samples")
    }

    @Test func videoOnlyRecordingDecodes() async throws {
        let recording = try Recording.make(codec: .h264, withAudio: false, seconds: 4, gopSeconds: 2)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let report = try await readBack(recording.url)
        #expect(report.audioTrackCount == 0)
        #expect(report.decodedVideoFrames == 120)
        #expect(abs(report.duration - 4.0) < 0.1, "duration \(report.duration)")
    }

    @Test(.enabled(if: hevcEncoderAvailable())) func hevcWithProducerReferenceTimeDecodes() async throws {
        let recording = try Recording.make(codec: .hevc, withAudio: true, producerReferenceTime: true)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let boxes = try MP4BoxReader.parse(recording.data)
        #expect(boxes.map(\.type) == ["ftyp", "moov"] + Array(repeating: ["prft", "moof", "mdat"], count: recording.fragmentCount).flatMap { $0 })
        // ≥: without a software HEVC encoder, a contended hardware encoder may add IDRs (and so fragments) of its own.
        #expect(recording.fragmentCount >= 3)
        #expect(MP4BoxReader.box(atPath: "moov/trak/mdia/minf/stbl/stsd/hvc1/hvcC", in: boxes) != nil)
        for prft in boxes.filter({ $0.type == "prft" }) { #expect(prft.fullBoxHeader(in: recording.data) == (1, 0)) }
        let report = try await readBack(recording.url)
        #expect(report.decodedVideoFrames == recording.videoFrames)
        #expect(report.videoReaderCompleted && report.audioReaderCompleted)
        #expect(abs(report.duration - 3.0) < 0.1, "duration \(report.duration)")
    }

    /// 352×288 at 12:11 (a CIF camera sub-stream): our `pasp` reaches AVFoundation's format description and ffprobe's
    /// display aspect ratio (4:3), for SPSs written by Apple's encoders.
    @Test func nonSquarePixelsSurviveTheRoundTrip() async throws {
        for codec in hevcEncoderAvailable() ? [VideoCodec.h264, .hevc] : [.h264] {
            let clip = try encodeVideo(codec: codec, width: 352, height: 288, gop: 30, frameCount: 30, pixelAspectRatio: (12, 11))
            #expect(clip.format.sampleAspectRatio == SampleAspectRatio(horizontal: 12, vertical: 11), "\(codec) SPS")
            var muxer = try FMP4Muxer(configuration: FMP4Configuration(video: clip.format, audio: nil))
            var file = muxer.initializationSegment()
            file.append(try muxer.fragment(video: clip.frames, audio: []))
            let url = FileManager.default.temporaryDirectory.appending(path: "fmp4-sar-\(UUID().uuidString).mp4")
            try file.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            let description = try #require(try await track.load(.formatDescriptions).first)
            let ratio = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any]
            #expect(ratio?[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? Int == 12, "\(codec): \(String(describing: ratio))")
            #expect(ratio?[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? Int == 11, "\(codec)")
            if FileManager.default.isExecutableFile(atPath: ffprobePath) {
                let result = try runTool(ffprobePath, ["-v", "error", "-select_streams", "v", "-show_entries",
                                                       "stream=sample_aspect_ratio,display_aspect_ratio", "-of", "csv=p=0", url.path])
                #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "12:11,4:3", "\(codec): \(result.output) \(result.errors)")
            }
        }
    }

    @Test func avcCMatchesVideoToolbox() throws {
        let clip = try encodeVideo(codec: .h264, gop: 30, frameCount: 1)
        let atom = try #require(clip.decoderConfigurationAtom)
        let ours = try AVCDecoderConfigurationRecord.make(parameterSets: clip.format.parameterSets)
        // High profile: we (like ffmpeg and the hardware encoder) append chroma_format / bit depths / numOfSPSExt
        // (4:2:0 8-bit → fd f8 f8 00); VideoToolbox's software encoder leaves that tail out. Everything before it is identical.
        let highProfileTail = Data([0xFD, 0xF8, 0xF8, 0x00])
        #expect(ours == atom || ours == atom + highProfileTail,
                "ours \(ours.map { String(format: "%02x", $0) }.joined()) VT \(atom.map { String(format: "%02x", $0) }.joined())")
    }

    @Test(.enabled(if: hevcEncoderAvailable())) func hvcCMatchesVideoToolbox() throws {
        let clip = try encodeVideo(codec: .hevc, gop: 30, frameCount: 1)
        let atom = try #require(clip.decoderConfigurationAtom)
        let ours = try HEVCDecoderConfigurationRecord.make(parameterSets: clip.format.parameterSets)
        // Byte 21 = constantFrameRate(2) numTemporalLayers(3) temporalIdNested(1) lengthSizeMinusOne(2). We copy
        // temporalIdNested from sps_temporal_id_nesting_flag (as ffmpeg does, see the golden); VideoToolbox writes the
        // conservative 0 ("not known") that ISO/IEC 14496-15 also allows. Every other byte must match.
        #expect(ours.count == atom.count && ours.count > 22)
        let nestingBit: UInt8 = 0x04
        #expect(Data(ours.enumerated().map { $0.offset == 21 ? $0.element & ~nestingBit : $0.element })
                    == Data(atom.enumerated().map { $0.offset == 21 ? $0.element & ~nestingBit : $0.element }))
        let sps = try #require(clip.format.parameterSets.first { ($0[$0.startIndex] >> 1) & 0x3F == 33 })
        #expect((ours[ours.startIndex + 21] & nestingBit != 0) == (try #require(HEVCSPS.parse(sps)).temporalIDNesting))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffprobePath)))
    func ffprobeReadsEveryPacket() throws {
        let recording = try Recording.make(codec: .h264, withAudio: true)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let result = try runTool(ffprobePath, ["-v", "error", "-show_packets", "-show_entries", "packet=codec_type", "-of", "csv=p=0",
                                               recording.url.path])
        #expect(!result.timedOut && result.status == 0)
        #expect(result.errors.isEmpty, "ffprobe: \(result.errors)")
        let types = result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(types.filter { $0 == "video" }.count == recording.videoFrames)
        #expect(types.filter { $0 == "audio" }.count == recording.audioFrames)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpegPath)))
    func ffmpegDecodesWithoutErrors() throws {
        for codec in hevcEncoderAvailable() ? [VideoCodec.h264, .hevc] : [.h264] {
            let recording = try Recording.make(codec: codec, withAudio: true, producerReferenceTime: codec == .hevc)
            defer { try? FileManager.default.removeItem(at: recording.url) }
            let result = try runTool(ffmpegPath, ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-i", recording.url.path, "-f", "null", "-"])
            #expect(!result.timedOut && result.status == 0, "\(codec): exit \(result.status)")
            #expect(result.errors.isEmpty, "\(codec): \(result.errors)")
        }
    }
}
#endif
