import Foundation

extension NALUnits {
    /// seq_parameter_set_id of an H.264 SPS NAL unit (type 7): the first ue(v) after profile_idc, the constraint flags and
    /// level_idc (ITU-T H.264 §7.3.2.1.1). nil for another NAL type or an SPS that ends early.
    package static func h264SPSID(_ nal: Data) -> UInt32? {
        guard h264Type(nal) == 7 else { return nil }
        var reader = BitReader(removeEmulationPrevention(Data(nal.dropFirst().prefix(8))))
        do {
            try reader.skip(24)
            return try reader.ue()
        } catch {
            return nil
        }
    }

    /// pic_parameter_set_id and seq_parameter_set_id of an H.264 PPS NAL unit (type 8): its first two ue(v) fields
    /// (§7.3.2.2). nil for another NAL type or a PPS that ends early.
    package static func h264PPSIDs(_ nal: Data) -> (id: UInt32, spsID: UInt32)? {
        guard h264Type(nal) == 8 else { return nil }
        var reader = BitReader(removeEmulationPrevention(Data(nal.dropFirst().prefix(8))))
        do {
            let id = try reader.ue()
            return (id, try reader.ue())
        } catch {
            return nil
        }
    }
}

/// The H.264 parameter sets a stream has sent, by id, and the `VideoFormat` they make.
///
/// A slice names its PPS (pic_parameter_set_id) and that PPS its SPS, and a decoder resolves both from the format
/// description's avcC: a PPS the description does not carry makes the decoder reject the slice (VideoToolbox:
/// kVTVideoDecoderBadDataErr, -12909). Cameras do send more than one: an encoder that codes its IDR pictures with one PPS
/// and its P pictures with another (and puts both in front of the IDR, or the second only once), or SPS/PPS re-sent with
/// other ids after a reconfiguration. A single "the latest SPS and PPS" slot loses all but the last, so every picture that
/// refers to another one fails; this keeps every one until its id is sent again (the new content replaces the old) or the
/// picture size changes (a new sequence: the other SPS go, and the PPS that referred to them).
///
/// `format.parameterSets` is `[SPS, PPS, further SPS…, further PPS…]`: the most recently changed SPS, the most recently
/// changed PPS of that SPS (else of any), then the rest by id. A stream with one SPS and one PPS therefore has the same
/// two-element list as before.
package struct H264ParameterSetStore: Sendable, Equatable {
    /// Bounds against a camera (or a hostile one) that sends sets with ever new ids: the oldest ones go.
    package static let maximumSPS = 4
    package static let maximumPPS = 16

    private struct Entry: Sendable, Equatable {
        var nal: Data
        /// PPS only: the SPS it refers to.
        var spsID: UInt32
        /// Counts changes: the newest content has the highest.
        var revision: Int
    }

    private var sps: [UInt32: Entry] = [:]
    private var pps: [UInt32: Entry] = [:]
    private var revision = 0

    package init() {}

    /// A store holding `parameterSets` (SPS and PPS NAL units; anything else is ignored), e.g. a format's.
    package init(parameterSets: [Data]) {
        for nal in parameterSets { _ = add(nal) }
    }

    /// Number of SPS and PPS held.
    package var count: Int { sps.count + pps.count }

    /// Records an SPS (type 7) or PPS (type 8) NAL unit. Returns whether the stored sets changed: false for a repeat of what
    /// is held, for another NAL type and for empty data.
    @discardableResult
    package mutating func add(_ nal: Data) -> Bool {
        switch NALUnits.h264Type(nal) {
        case 7:
            let id = NALUnits.h264SPSID(nal) ?? 0
            guard sps[id]?.nal != nal else { return false }
            revision += 1
            let known = sps.values.max { $0.revision < $1.revision }.flatMap { H264SPS.parse($0.nal) }
            sps[id] = Entry(nal: nal, spsID: id, revision: revision)
            if let known, let parsed = H264SPS.parse(nal), (known.width, known.height) != (parsed.width, parsed.height) {
                startNewSequence(keeping: id)   // another picture size: the other SPS (and what refers to them) are stale
            }
            prune()
            return true
        case 8:
            let ids = NALUnits.h264PPSIDs(nal) ?? (0, 0)
            guard pps[ids.id]?.nal != nal else { return false }
            revision += 1
            pps[ids.id] = Entry(nal: nal, spsID: ids.spsID, revision: revision)
            prune()
            return true
        default:
            return false
        }
    }

    /// The format of the sets held (nil until there are an SPS and a PPS). Size, profile and level come from the primary SPS;
    /// an SPS that does not parse gives a format without dimensions (the sets are still what a decoder needs).
    package var format: VideoFormat? {
        guard let primarySPS = sps.max(by: { $0.value.revision < $1.value.revision }) else { return nil }
        let linked = pps.filter { $0.value.spsID == primarySPS.key }
        guard let primaryPPS = (linked.isEmpty ? pps : linked).max(by: { $0.value.revision < $1.value.revision }) else { return nil }
        let sets = [primarySPS.value.nal, primaryPPS.value.nal]
            + sps.filter { $0.key != primarySPS.key }.sorted { $0.key < $1.key }.map(\.value.nal)
            + pps.filter { $0.key != primaryPPS.key }.sorted { $0.key < $1.key }.map(\.value.nal)
        let first = VideoFormat.h264(sps: primarySPS.value.nal, pps: primaryPPS.value.nal)
        if var format = first {
            format.parameterSets = sets
            return format
        }
        let bytes = [UInt8](primarySPS.value.nal)
        return VideoFormat(codec: .h264, width: 0, height: 0, parameterSets: sets, profile: bytes.count > 1 ? bytes[1] : 0,
                           profileCompatibility: bytes.count > 2 ? bytes[2] : 0, level: bytes.count > 3 ? bytes[3] : 0)
    }

    /// Keeps only the SPS `id` and the PPS that refer to it.
    private mutating func startNewSequence(keeping id: UInt32) {
        sps = sps.filter { $0.key == id }
        pps = pps.filter { $0.value.spsID == id }
    }

    private mutating func prune() {
        while sps.count > Self.maximumSPS, let oldest = sps.min(by: { $0.value.revision < $1.value.revision }) { sps[oldest.key] = nil }
        while pps.count > Self.maximumPPS, let oldest = pps.min(by: { $0.value.revision < $1.value.revision }) { pps[oldest.key] = nil }
    }
}

extension VideoFormat {
    /// Whether every parameter set of `earlier` is also in this format, so a decoder holding `earlier` loses nothing by
    /// switching to it (the same stream with more PPS/SPS; a changed set or a different size is not an extension).
    package func extends(_ earlier: VideoFormat) -> Bool {
        codec == earlier.codec && !earlier.parameterSets.isEmpty && Set(earlier.parameterSets).isSubset(of: Set(parameterSets))
    }
}
