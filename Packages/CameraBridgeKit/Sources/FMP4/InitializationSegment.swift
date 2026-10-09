import Foundation
import MediaCore

/// Validated track parameters shared by the init segment and the fragments.
struct VideoTrack: Sendable {
    static let trackID: UInt32 = 1
    var codec: VideoCodec
    var width: Int
    var height: Int
    var timescale: Int32
    /// avcC / hvcC payload.
    var decoderConfiguration: Data
    /// From the SPS VUI; nil (square pixels assumed) when the SPS does not state it.
    var sampleAspectRatio: SampleAspectRatio?

    /// `tkhd` width (16.16): the coded width stretched by the sample aspect ratio, as ffmpeg writes it (704 at 12:11 → 768).
    var displayWidth: UInt32 {
        let coded = UInt64(width) << 16
        guard let sar = sampleAspectRatio else { return UInt32(clamping: coded) }
        return UInt32(clamping: coded * UInt64(sar.horizontal) / UInt64(sar.vertical))
    }
}

struct AudioTrack: Sendable {
    static let trackID: UInt32 = 2
    var sampleRate: Int
    var channels: Int
    /// The AAC-LC AudioSpecificConfig in the `esds`, and its parsed fields.
    var audioSpecificConfig: Data
    var config: AudioSpecificConfig
    /// ES_Descriptor (esds payload after version/flags).
    var esDescriptor: Data { ElementaryStreamDescriptor.make(audioSpecificConfig: audioSpecificConfig) }
    var timescale: Int32 { Int32(sampleRate) }
}

/// `ftyp` + empty `moov` laid out like ffmpeg's `-movflags frag_keyframe+empty_moov+default_base_moof` (ISO/IEC 14496-12).
enum InitializationSegment {
    static let movieTimescale: UInt32 = 1_000

    static func make(video: VideoTrack, audio: AudioTrack?) -> Data {
        var writer = BoxWriter(capacity: 1_024)
        writer.box("ftyp") { w in
            w.fourCC("isom")                               // major_brand
            w.u32(0x200)                                   // minor_version
            for brand in ["isom", "iso5", "iso6", "mp41"] { w.fourCC(brand) }
        }
        writer.box("moov") { w in
            movieHeader(nextTrackID: (audio == nil ? VideoTrack.trackID : AudioTrack.trackID) + 1, into: &w)
            videoTrak(video, into: &w)
            if let audio { audioTrak(audio, into: &w) }
            w.box("mvex") { w in
                trackExtends(VideoTrack.trackID, into: &w)
                if audio != nil { trackExtends(AudioTrack.trackID, into: &w) }
            }
        }
        return writer.data
    }

    private static func movieHeader(nextTrackID: UInt32, into w: inout BoxWriter) {
        w.fullBox("mvhd", version: 0, flags: 0) { w in
            w.u32(0)                                       // creation_time
            w.u32(0)                                       // modification_time
            w.u32(movieTimescale)
            w.u32(0)                                       // duration: unknown (fragmented)
            w.u32(0x0001_0000)                             // rate 1.0
            w.u16(0x0100)                                  // volume 1.0
            w.zeros(10)                                    // reserved
            w.identityMatrix()
            w.zeros(24)                                    // pre_defined
            w.u32(nextTrackID)
        }
    }

    /// `width` and `height` are 16.16 fixed point.
    private static func trackHeader(trackID: UInt32, alternateGroup: UInt16, volume: UInt16, width: UInt32, height: UInt32, into w: inout BoxWriter) {
        w.fullBox("tkhd", version: 0, flags: 0x3) { w in   // track_enabled | track_in_movie
            w.u32(0)                                       // creation_time
            w.u32(0)                                       // modification_time
            w.u32(trackID)
            w.u32(0)                                       // reserved
            w.u32(0)                                       // duration
            w.zeros(8)                                     // reserved
            w.u16(0)                                       // layer
            w.u16(alternateGroup)
            w.u16(volume)
            w.u16(0)                                       // reserved
            w.identityMatrix()
            w.u32(width)
            w.u32(height)
        }
    }

    private static func mediaHeader(timescale: Int32, into w: inout BoxWriter) {
        w.fullBox("mdhd", version: 0, flags: 0) { w in
            w.u32(0)                                       // creation_time
            w.u32(0)                                       // modification_time
            w.u32(UInt32(timescale))
            w.u32(0)                                       // duration
            w.u16(0x55C4)                                  // language "und" (ISO 639-2/T packed)
            w.u16(0)                                       // pre_defined
        }
    }

    private static func handler(_ type: String, name: String, into w: inout BoxWriter) {
        w.fullBox("hdlr", version: 0, flags: 0) { w in
            w.u32(0)                                       // pre_defined
            w.fourCC(type)
            w.zeros(12)                                    // reserved
            w.append(Array(name.utf8) + [0])
        }
    }

    private static func dataInformation(into w: inout BoxWriter) {
        w.box("dinf") { w in
            w.fullBox("dref", version: 0, flags: 0) { w in
                w.u32(1)                                   // entry_count
                w.fullBox("url ", version: 0, flags: 1) { _ in }   // media data in this file
            }
        }
    }

    /// Empty sample tables: every sample lives in a fragment.
    private static func sampleTable(entry: (inout BoxWriter) -> Void, into w: inout BoxWriter) {
        w.box("stbl") { w in
            w.fullBox("stsd", version: 0, flags: 0) { w in
                w.u32(1)                                   // entry_count
                entry(&w)
            }
            w.fullBox("stts", version: 0, flags: 0) { $0.u32(0) }
            w.fullBox("stsc", version: 0, flags: 0) { $0.u32(0) }
            w.fullBox("stsz", version: 0, flags: 0) { w in
                w.u32(0)                                   // sample_size
                w.u32(0)                                   // sample_count
            }
            w.fullBox("stco", version: 0, flags: 0) { $0.u32(0) }
        }
    }

    private static func videoTrak(_ video: VideoTrack, into w: inout BoxWriter) {
        w.box("trak") { w in
            trackHeader(trackID: VideoTrack.trackID, alternateGroup: 0, volume: 0, width: video.displayWidth, height: UInt32(video.height) << 16,
                        into: &w)
            w.box("mdia") { w in
                mediaHeader(timescale: video.timescale, into: &w)
                handler("vide", name: "VideoHandler", into: &w)
                w.box("minf") { w in
                    w.fullBox("vmhd", version: 0, flags: 1) { w in
                        w.u16(0)                           // graphicsmode copy
                        w.zeros(6)                         // opcolor
                    }
                    dataInformation(into: &w)
                    sampleTable(entry: { visualSampleEntry(video, into: &$0) }, into: &w)
                }
            }
        }
    }

    /// `avc1` / `hvc1` VisualSampleEntry (ISO/IEC 14496-12 §12.1.3, 14496-15 §5.4.2 / §8.4.1). HKSV requires `hvc1`
    /// (parameter sets only in the sample entry), never `hev1`.
    private static func visualSampleEntry(_ video: VideoTrack, into w: inout BoxWriter) {
        w.box(video.codec == .h264 ? "avc1" : "hvc1") { w in
            w.zeros(6)                                     // reserved
            w.u16(1)                                       // data_reference_index
            w.u16(0)                                       // pre_defined
            w.u16(0)                                       // reserved
            w.zeros(12)                                    // pre_defined
            w.u16(UInt16(video.width))
            w.u16(UInt16(video.height))
            w.u32(0x0048_0000)                             // horizresolution 72 dpi
            w.u32(0x0048_0000)                             // vertresolution 72 dpi
            w.u32(0)                                       // reserved
            w.u16(1)                                       // frame_count
            w.zeros(32)                                    // compressorname (empty Pascal string)
            w.u16(0x0018)                                  // depth
            w.u16(0xFFFF)                                  // pre_defined −1
            w.box(video.codec == .h264 ? "avcC" : "hvcC") { $0.append(video.decoderConfiguration) }
            w.box("pasp") { w in                           // hSpacing, vSpacing: the SAR (1:1 when unknown)
                w.u32(video.sampleAspectRatio?.horizontal ?? 1)
                w.u32(video.sampleAspectRatio?.vertical ?? 1)
            }
        }
    }

    private static func audioTrak(_ audio: AudioTrack, into w: inout BoxWriter) {
        w.box("trak") { w in
            trackHeader(trackID: AudioTrack.trackID, alternateGroup: 1, volume: 0x0100, width: 0, height: 0, into: &w)
            w.box("mdia") { w in
                mediaHeader(timescale: audio.timescale, into: &w)
                handler("soun", name: "SoundHandler", into: &w)
                w.box("minf") { w in
                    w.fullBox("smhd", version: 0, flags: 0) { w in
                        w.u16(0)                           // balance
                        w.u16(0)                           // reserved
                    }
                    dataInformation(into: &w)
                    sampleTable(entry: { audioSampleEntry(audio, into: &$0) }, into: &w)
                }
            }
        }
    }

    /// `mp4a` AudioSampleEntry (version 0) with an `esds` built from an ES_Descriptor — never a bare AudioSpecificConfig
    /// (research brief §3.9).
    private static func audioSampleEntry(_ audio: AudioTrack, into w: inout BoxWriter) {
        w.box("mp4a") { w in
            w.zeros(6)                                     // reserved
            w.u16(1)                                       // data_reference_index
            w.zeros(8)                                     // reserved (version 0, revision, vendor)
            w.u16(UInt16(audio.channels))
            w.u16(16)                                      // samplesize
            w.u16(0)                                       // pre_defined
            w.u16(0)                                       // reserved
            w.u32(UInt32(min(audio.sampleRate, 0xFFFF)) << 16)   // 16.16
            w.fullBox("esds", version: 0, flags: 0) { $0.append(audio.esDescriptor) }
        }
    }

    private static func trackExtends(_ trackID: UInt32, into w: inout BoxWriter) {
        w.fullBox("trex", version: 0, flags: 0) { w in
            w.u32(trackID)
            w.u32(1)                                       // default_sample_description_index
            w.u32(0)                                       // default_sample_duration
            w.u32(0)                                       // default_sample_size
            w.u32(0)                                       // default_sample_flags
        }
    }
}
