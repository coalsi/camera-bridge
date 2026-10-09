import Foundation

// The package's only H.264 / HEVC sequence parameter set parsers: FMP4 reads the avcC/hvcC fields and the sample aspect
// ratio from these too (package-visible fields), so a parser fix is made once.

/// Fields of an H.264 sequence parameter set (ITU-T H.264 §7.3.2.1.1).
public struct H264SPS: Sendable, Equatable {
    public var profileIDC: UInt8
    public var constraintFlags: UInt8
    public var levelIDC: UInt8
    /// Display size after frame cropping.
    public var width: Int
    public var height: Int
    /// From VUI timing info (time_scale / (2 · num_units_in_tick)) when present.
    public var frameRate: Double?
    /// chroma_format_idc (1, 4:2:0, when the profile does not code it).
    package var chromaFormatIDC: UInt8 = 1
    package var bitDepthLumaMinus8: UInt8 = 0
    package var bitDepthChromaMinus8: UInt8 = 0
    /// The VUI sample aspect ratio; nil when the SPS states none (or "unspecified").
    package var sampleAspectRatio: SampleAspectRatio?

    public init(profileIDC: UInt8, constraintFlags: UInt8, levelIDC: UInt8, width: Int, height: Int, frameRate: Double? = nil) {
        self.profileIDC = profileIDC
        self.constraintFlags = constraintFlags
        self.levelIDC = levelIDC
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// Parses an SPS NAL unit (with its header byte, type 7) or a bare SPS RBSP. Returns nil when malformed. A VUI that
    /// does not parse leaves `frameRate` (and, when it fails before it, `sampleAspectRatio`) nil.
    public static func parse(_ sps: Data) -> H264SPS? {
        guard let first = sps.first else { return nil }
        let payload = first & 0x1F == 7 ? sps.dropFirst() : sps[...]
        var r = BitReader(NALUnits.removeEmulationPrevention(Data(payload)))
        do {
            let profile = UInt8(try r.bits(8))
            let constraints = UInt8(try r.bits(8))
            let level = UInt8(try r.bits(8))
            guard knownProfiles.contains(profile), level > 0 else { return nil }
            guard try r.ue() <= 31 else { return nil }   // seq_parameter_set_id
            var chromaFormat: UInt32 = 1
            var separateColourPlane = false
            var bitDepths: (luma: UInt32, chroma: UInt32) = (0, 0)
            if chromaFormatProfiles.contains(profile) {
                chromaFormat = try r.ue()
                guard chromaFormat <= 3 else { return nil }
                if chromaFormat == 3 { separateColourPlane = try r.flag() }
                bitDepths = (try r.ue(), try r.ue())
                guard bitDepths.luma <= 6, bitDepths.chroma <= 6 else { return nil }
                try r.skip(1)                                                // qpprime_y_zero_transform_bypass_flag
                if try r.flag() {                                            // seq_scaling_matrix_present_flag
                    for i in 0..<(chromaFormat != 3 ? 8 : 12) {
                        if try r.flag() { try skipScalingList(&r, size: i < 6 ? 16 : 64) }
                    }
                }
            }
            guard try r.ue() <= 12 else { return nil }                       // log2_max_frame_num_minus4
            let pocType = try r.ue()
            switch pocType {
            case 0:
                guard try r.ue() <= 12 else { return nil }
            case 1:
                try r.skip(1)
                _ = try r.se(); _ = try r.se()
                let cycle = try r.ue()
                guard cycle <= 255 else { return nil }
                for _ in 0..<cycle { _ = try r.se() }
            case 2:
                break
            default:
                return nil
            }
            _ = try r.ue()                                                   // max_num_ref_frames
            try r.skip(1)                                                    // gaps_in_frame_num_value_allowed_flag
            let widthInMbs = Int(try r.ue()) + 1
            let heightInMapUnits = Int(try r.ue()) + 1
            let frameMbsOnly = try r.flag()
            if !frameMbsOnly { try r.skip(1) }                               // mb_adaptive_frame_field_flag
            try r.skip(1)                                                    // direct_8x8_inference_flag
            var crop = (left: 0, right: 0, top: 0, bottom: 0)
            if try r.flag() {
                crop = (Int(try r.ue()), Int(try r.ue()), Int(try r.ue()), Int(try r.ue()))
            }
            let chromaArrayType = separateColourPlane ? 0 : chromaFormat
            let cropUnitX = chromaArrayType == 0 ? 1 : (chromaFormat == 3 ? 1 : 2)
            let cropUnitY = (chromaArrayType == 0 ? 1 : (chromaFormat == 1 ? 2 : 1)) * (frameMbsOnly ? 1 : 2)
            let width = widthInMbs * 16 - cropUnitX * (crop.left + crop.right)
            let height = (frameMbsOnly ? 1 : 2) * heightInMapUnits * 16 - cropUnitY * (crop.top + crop.bottom)
            guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }

            var sps = H264SPS(profileIDC: profile, constraintFlags: constraints, levelIDC: level, width: width, height: height)
            sps.chromaFormatIDC = UInt8(chromaFormat)
            sps.bitDepthLumaMinus8 = UInt8(bitDepths.luma)
            sps.bitDepthChromaMinus8 = UInt8(bitDepths.chroma)
            if (try? r.flag()) == true {                                     // vui_parameters_present_flag
                (sps.sampleAspectRatio, sps.frameRate) = parseVUI(&r)
            }
            return sps
        } catch {
            return nil
        }
    }

    /// profile_idc values defined by H.264 (Annex A, G, H, I).
    static let knownProfiles: Set<UInt8> = [44, 66, 77, 83, 86, 88, 100, 110, 118, 122, 128, 134, 135, 138, 139, 144, 244]

    /// profile_idc values whose SPS codes chroma_format_idc, bit depths and scaling matrices (§7.3.2.1.1).
    static let chromaFormatProfiles: Set<UInt8> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    /// scaling_list() (§7.3.2.1.1.1). delta_scale must lie in −128…127 (§7.4.2.1.1.1); anything else is malformed.
    /// Arithmetic is done in `Int` so attacker-controlled se(v) values (up to ±2³¹) cannot overflow.
    private static func skipScalingList(_ r: inout BitReader, size: Int) throws(BitReader.Failure) {
        var last = 8
        var next = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = Int(try r.se())
                guard (-128...127).contains(delta) else { throw .invalid }
                next = (last + delta + 256) % 256
            }
            if next != 0 { last = next }
        }
    }

    /// vui_parameters() (§E.1.1) up to timing_info: the sample aspect ratio, then the frame rate. Whatever does not
    /// parse is nil; the aspect ratio is kept when only the later fields fail.
    private static func parseVUI(_ r: inout BitReader) -> (SampleAspectRatio?, Double?) {
        let aspectRatio: SampleAspectRatio?
        do {
            aspectRatio = try SampleAspectRatio.parseVUI(&r)
        } catch {
            return (nil, nil)
        }
        return (aspectRatio, try? parseVUITiming(&r))
    }

    /// The VUI fields after aspect_ratio_info up to timing_info; returns the frame rate or nil when absent.
    private static func parseVUITiming(_ r: inout BitReader) throws(BitReader.Failure) -> Double? {
        if try r.flag() { try r.skip(1) }                                    // overscan
        if try r.flag() {                                                    // video_signal_type_present_flag
            try r.skip(4)
            if try r.flag() { try r.skip(24) }                               // colour description
        }
        if try r.flag() { _ = try r.ue(); _ = try r.ue() }                   // chroma_loc_info
        guard try r.flag() else { return nil }                               // timing_info_present_flag
        let unitsInTick = try r.bits(32)
        let timeScale = try r.bits(32)
        guard unitsInTick > 0, timeScale > 0 else { return nil }
        return Double(timeScale) / (2 * Double(unitsInTick))
    }
}

/// Fields of an HEVC sequence parameter set (ITU-T H.265 §7.3.2.2).
public struct HEVCSPS: Sendable, Equatable {
    /// Display size after the conformance window.
    public var width: Int
    public var height: Int
    public var generalProfileIDC: UInt8
    public var generalLevelIDC: UInt8
    /// sps_max_sub_layers_minus1 and sps_temporal_id_nesting_flag.
    package var maxSubLayersMinus1: UInt8 = 0
    package var temporalIDNesting = false
    /// profile_tier_level(): general_profile_space, general_tier_flag, the 32 compatibility flags and the 48 bits of
    /// constraint indicator flags (progressive_source_flag … general_inbld_flag / reserved).
    package var generalProfileSpace: UInt8 = 0
    package var generalTierFlag = false
    package var generalProfileCompatibilityFlags: UInt32 = 0
    package var generalConstraintIndicatorFlags: UInt64 = 0
    package var chromaFormatIDC: UInt8 = 1
    /// nil when the SPS ends (or is malformed) right after the conformance window, or has the reserved
    /// sps_max_sub_layers_minus1 = 7.
    package var bitDepthLumaMinus8: UInt8?
    package var bitDepthChromaMinus8: UInt8?
    /// The VUI sample aspect ratio; nil when the SPS states none, or the SPS does not parse up to it.
    package var sampleAspectRatio: SampleAspectRatio?

    public init(width: Int, height: Int, generalProfileIDC: UInt8, generalLevelIDC: UInt8) {
        self.width = width
        self.height = height
        self.generalProfileIDC = generalProfileIDC
        self.generalLevelIDC = generalLevelIDC
    }

    /// Parses an SPS NAL unit (with its 2-byte header, type 33) or a bare SPS RBSP. Returns nil when malformed up to
    /// the conformance window; the fields after it (bit depths, the VUI aspect ratio) are nil when they do not parse.
    public static func parse(_ sps: Data) -> HEVCSPS? {
        guard let first = sps.first else { return nil }
        let payload = (first >> 1) & 0x3F == 33 ? sps.dropFirst(2) : sps[...]
        var r = BitReader(NALUnits.removeEmulationPrevention(Data(payload)))
        do {
            try r.skip(4)                                                    // sps_video_parameter_set_id
            let maxSubLayersMinus1 = Int(try r.bits(3))
            let nesting = try r.flag()                                       // sps_temporal_id_nesting_flag
            // profile_tier_level(1, maxSubLayersMinus1) (§7.3.3)
            let profileSpace = UInt8(try r.bits(2))
            let tier = try r.flag()
            let profile = UInt8(try r.bits(5))
            let compatibility = UInt32(try r.bits(32))
            let constraints = try r.bits(48)
            let level = UInt8(try r.bits(8))
            var subLayerProfilePresent: [Bool] = []
            var subLayerLevelPresent: [Bool] = []
            for _ in 0..<maxSubLayersMinus1 {
                subLayerProfilePresent.append(try r.flag())
                subLayerLevelPresent.append(try r.flag())
            }
            if maxSubLayersMinus1 > 0 {
                for _ in maxSubLayersMinus1..<8 { try r.skip(2) }            // reserved_zero_2bits
            }
            for i in 0..<maxSubLayersMinus1 {
                if subLayerProfilePresent[i] { try r.skip(88) }
                if subLayerLevelPresent[i] { try r.skip(8) }
            }
            guard try r.ue() <= 15 else { return nil }                       // sps_seq_parameter_set_id
            let chromaFormat = try r.ue()
            guard chromaFormat <= 3 else { return nil }
            var separateColourPlane = false
            if chromaFormat == 3 { separateColourPlane = try r.flag() }
            var width = Int(try r.ue())
            var height = Int(try r.ue())
            if try r.flag() {                                                // conformance_window_flag
                let left = Int(try r.ue()), right = Int(try r.ue()), top = Int(try r.ue()), bottom = Int(try r.ue())
                let chromaArrayType = separateColourPlane ? 0 : chromaFormat
                let subWidth = chromaArrayType == 1 || chromaArrayType == 2 ? 2 : 1
                let subHeight = chromaArrayType == 1 ? 2 : 1
                width -= subWidth * (left + right)
                height -= subHeight * (top + bottom)
            }
            guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
            var sps = HEVCSPS(width: width, height: height, generalProfileIDC: profile, generalLevelIDC: level)
            sps.maxSubLayersMinus1 = UInt8(maxSubLayersMinus1)
            sps.temporalIDNesting = nesting
            sps.generalProfileSpace = profileSpace
            sps.generalTierFlag = tier
            sps.generalProfileCompatibilityFlags = compatibility
            sps.generalConstraintIndicatorFlags = constraints
            sps.chromaFormatIDC = UInt8(chromaFormat)
            // sps_max_sub_layers_minus1 shall be 0…6 (§7.4.3.2.1); 7 keeps the fields above but nothing after them.
            if maxSubLayersMinus1 <= 6 { sps.parseTail(&r, maxSubLayersMinus1: maxSubLayersMinus1) }
            return sps
        } catch {
            return nil
        }
    }

    /// seq_parameter_set_rbsp() (§7.3.2.2.1) from bit_depth_luma_minus8 to the VUI aspect ratio. Stops (leaving the
    /// rest nil) at the first field that is missing or out of range.
    private mutating func parseTail(_ r: inout BitReader, maxSubLayersMinus1: Int) {
        do {
            let luma = try r.ue(), chroma = try r.ue()
            guard luma <= 8, chroma <= 8 else { return }                     // bit_depth_luma/chroma_minus8
            (bitDepthLumaMinus8, bitDepthChromaMinus8) = (UInt8(luma), UInt8(chroma))
            let log2MaxPOCLsbMinus4 = try r.ue()
            guard log2MaxPOCLsbMinus4 <= 12 else { return }
            let orderingInfoForAllSubLayers = try r.flag()                   // sps_sub_layer_ordering_info_present_flag
            for _ in (orderingInfoForAllSubLayers ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
                for _ in 0..<3 { _ = try r.ue() }                            // max_dec_pic_buffering, max_num_reorder, max_latency
            }
            for _ in 0..<6 { _ = try r.ue() }                                // coding/transform block sizes, hierarchy depths
            if try r.flag(), try r.flag() {                                  // scaling_list_enabled_flag, sps_scaling_list_data_present_flag
                try Self.skipScalingListData(&r)
            }
            try r.skip(2)                                                    // amp_enabled_flag, sample_adaptive_offset_enabled_flag
            if try r.flag() {                                                // pcm_enabled_flag
                try r.skip(8)                                                // pcm sample bit depths
                _ = try r.ue()
                _ = try r.ue()
                try r.skip(1)                                                // pcm_loop_filter_disabled_flag
            }
            let setCount = try r.ue()                                        // num_short_term_ref_pic_sets
            guard setCount <= 64 else { return }
            var sets: [ShortTermReferencePictureSet] = []
            for index in 0..<Int(setCount) {
                sets.append(try ShortTermReferencePictureSet(&r, index: index, previous: sets))
            }
            if try r.flag() {                                                // long_term_ref_pics_present_flag
                let count = try r.ue()
                guard count <= 32 else { return }
                for _ in 0..<count { try r.skip(Int(log2MaxPOCLsbMinus4) + 4 + 1) }   // lt_ref_pic_poc_lsb_sps, used flag
            }
            try r.skip(2)                                                    // sps_temporal_mvp_enabled_flag, strong_intra_smoothing
            guard try r.flag() else { return }                               // vui_parameters_present_flag
            sampleAspectRatio = try SampleAspectRatio.parseVUI(&r)
        } catch {
            return
        }
    }

    /// scaling_list_data() (§7.3.4).
    private static func skipScalingListData(_ r: inout BitReader) throws(BitReader.Failure) {
        for sizeID in 0..<4 {
            let step = sizeID == 3 ? 3 : 1
            for matrixID in stride(from: 0, to: 6, by: step) {
                if try r.flag() {                                            // scaling_list_pred_mode_flag
                    if sizeID > 1 {
                        let dc = try r.se()                                  // scaling_list_dc_coef_minus8
                        guard (-7...247).contains(dc) else { throw .invalid }
                    }
                    for _ in 0..<min(64, 1 << (4 + (sizeID << 1))) {
                        let delta = try r.se()                               // scaling_list_delta_coef
                        guard (-128...127).contains(delta) else { throw .invalid }
                    }
                } else {
                    guard try r.ue() <= UInt32(matrixID / step) else { throw .invalid }   // pred_matrix_id_delta
                }
            }
        }
    }
}

/// Sample (pixel) aspect ratio from a sequence parameter set's VUI: `aspect_ratio_idc` of ITU-T H.264 Table E-1 (the
/// same table in H.265), or `sar_width`/`sar_height` for Extended_SAR (255).
package struct SampleAspectRatio: Equatable, Sendable {
    package var horizontal: UInt32
    package var vertical: UInt32

    /// Reduced to lowest terms; nil when either term is 0 ("unspecified", §E.2.1).
    package init?(horizontal: UInt32, vertical: UInt32) {
        guard horizontal > 0, vertical > 0 else { return nil }
        var (a, b) = (horizontal, vertical)
        while b != 0 { (a, b) = (b, a % b) }
        self.horizontal = horizontal / a
        self.vertical = vertical / a
    }

    /// Table E-1, aspect_ratio_idc 1…16; nil for 0 (unspecified) and the reserved values.
    package static func predefined(_ idc: UInt64) -> SampleAspectRatio? {
        let table: [(UInt32, UInt32)] = [(1, 1), (12, 11), (10, 11), (16, 11), (40, 33), (24, 11), (20, 11), (32, 11),
                                         (80, 33), (18, 11), (15, 11), (64, 33), (160, 99), (4, 3), (3, 2), (2, 1)]
        guard (1...UInt64(table.count)).contains(idc) else { return nil }
        let (horizontal, vertical) = table[Int(idc) - 1]
        return SampleAspectRatio(horizontal: horizontal, vertical: vertical)
    }

    /// `vui_parameters()` up to and including aspect_ratio_info (identical in H.264 §E.1.1 and H.265 §E.2.1).
    static func parseVUI(_ r: inout BitReader) throws(BitReader.Failure) -> SampleAspectRatio? {
        guard try r.flag() else { return nil }                               // aspect_ratio_info_present_flag
        let idc = try r.bits(8)
        guard idc == 255 else { return predefined(idc) }
        let width = UInt32(try r.bits(16))
        let height = UInt32(try r.bits(16))
        return SampleAspectRatio(horizontal: width, vertical: height)
    }
}

extension VideoFormat {
    /// The sample aspect ratio stated by the format's SPS, if any.
    package var sampleAspectRatio: SampleAspectRatio? {
        switch codec {
        case .h264: parameterSets.first { NALUnits.h264Type($0) == 7 }.flatMap(H264SPS.parse)?.sampleAspectRatio
        case .hevc: parameterSets.first { $0.count >= 2 && NALUnits.hevcType($0) == 33 }.flatMap(HEVCSPS.parse)?.sampleAspectRatio
        }
    }
}

/// st_ref_pic_set() (H.265 §7.3.7) with the delta POCs derived per §7.4.8, which a later inter-predicted set needs.
private struct ShortTermReferencePictureSet {
    /// DeltaPocS0 (negative, closest first) and DeltaPocS1 (positive, closest first).
    var negative: [Int]
    var positive: [Int]

    /// At most 16 pictures per direction (sps_max_dec_pic_buffering_minus1 ≤ 15).
    private static let maximumPictures = 16

    init(_ r: inout BitReader, index: Int, previous: [ShortTermReferencePictureSet]) throws(BitReader.Failure) {
        if index > 0, try r.flag() {                                         // inter_ref_pic_set_prediction_flag
            // In an SPS delta_idx_minus1 is absent: the set is predicted from the one before it.
            let reference = previous[index - 1]
            let negativeSign = try r.flag()                                  // delta_rps_sign
            let magnitude = try r.ue()                                       // abs_delta_rps_minus1
            guard magnitude < 1 << 15 else { throw .invalid }
            let deltaRPS = (negativeSign ? -1 : 1) * (Int(magnitude) + 1)
            let count = reference.negative.count + reference.positive.count
            var use: [Bool] = []
            for _ in 0...count {
                // used_by_curr_pic_flag, then use_delta_flag (inferred 1 when the picture is used).
                if try r.flag() {
                    use.append(true)
                } else {
                    use.append(try r.flag())
                }
            }
            // (7-61) and (7-62).
            var negative: [Int] = []
            var positive: [Int] = []
            let negativeCount = reference.negative.count
            for j in reference.positive.indices.reversed() where reference.positive[j] + deltaRPS < 0 && use[negativeCount + j] {
                negative.append(reference.positive[j] + deltaRPS)
            }
            if deltaRPS < 0 && use[count] { negative.append(deltaRPS) }
            for j in reference.negative.indices where reference.negative[j] + deltaRPS < 0 && use[j] {
                negative.append(reference.negative[j] + deltaRPS)
            }
            for j in reference.negative.indices.reversed() where reference.negative[j] + deltaRPS > 0 && use[j] {
                positive.append(reference.negative[j] + deltaRPS)
            }
            if deltaRPS > 0 && use[count] { positive.append(deltaRPS) }
            for j in reference.positive.indices where reference.positive[j] + deltaRPS > 0 && use[negativeCount + j] {
                positive.append(reference.positive[j] + deltaRPS)
            }
            guard negative.count <= Self.maximumPictures, positive.count <= Self.maximumPictures else { throw .invalid }
            self.negative = negative
            self.positive = positive
        } else {
            let negativeCount = try r.ue()                                   // num_negative_pics
            let positiveCount = try r.ue()                                   // num_positive_pics
            guard negativeCount <= Self.maximumPictures, positiveCount <= Self.maximumPictures else { throw .invalid }
            var poc = 0
            negative = []
            for _ in 0..<negativeCount {
                let delta = try r.ue()                                       // delta_poc_s0_minus1
                guard delta < 1 << 15 else { throw .invalid }
                poc -= Int(delta) + 1
                negative.append(poc)
                try r.skip(1)                                                // used_by_curr_pic_s0_flag
            }
            poc = 0
            positive = []
            for _ in 0..<positiveCount {
                let delta = try r.ue()                                       // delta_poc_s1_minus1
                guard delta < 1 << 15 else { throw .invalid }
                poc += Int(delta) + 1
                positive.append(poc)
                try r.skip(1)                                                // used_by_curr_pic_s1_flag
            }
        }
    }
}
