import Foundation

/// The leading fields of an MPEG-4 AudioSpecificConfig (ISO/IEC 14496-3 §1.6.2.1): audioObjectType (31 escapes to
/// 32 + 6 bits), samplingFrequencyIndex or the explicit 24-bit samplingFrequency, and channelConfiguration.
///
/// The package's only AudioSpecificConfig parser and writer: RTSP (SDP `config=`, FLV sequence headers), FMP4 (the
/// `esds` of a recording) and BridgeEngine (recording audio plan) all read it here, so they agree on what is valid;
/// `encoded` writes the AAC-LC configs of `AudioFormat.aacLC` and RTP's AAC-ELD ones.
package struct AudioSpecificConfig: Equatable, Sendable {
    /// AAC-LC, the only object type HKSV records.
    package static let aacLC = 2
    /// AAC-ELD (HomeKit live audio).
    package static let aacELD = 39
    /// samplingFrequencyIndex 0…12; 13 and 14 are reserved, 15 means an explicit 24-bit frequency follows.
    package static let frequencies = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
    /// Explicit frequencies outside this range are rejected: 0 Hz is meaningless and no camera or HomeKit codec runs
    /// above 1 MHz (it also bounds the clock rates derived from the config).
    package static let explicitSampleRates = 1...1_000_000

    package var objectType: Int
    package var sampleRate: Int
    package var channelConfiguration: Int

    package init(objectType: Int, sampleRate: Int, channelConfiguration: Int) {
        self.objectType = objectType
        self.sampleRate = sampleRate
        self.channelConfiguration = channelConfiguration
    }

    /// nil when `data` is too short, uses a reserved frequency index (13, 14) or an explicit frequency outside
    /// `explicitSampleRates`.
    package init?(_ data: Data) {
        var reader = BitReader(data)
        do {
            var type = Int(try reader.bits(5))
            if type == 31 { type = 32 + Int(try reader.bits(6)) }
            let index = Int(try reader.bits(4))
            let rate: Int
            if index == 15 {
                rate = Int(try reader.bits(24))
                guard Self.explicitSampleRates.contains(rate) else { return nil }
            } else {
                guard index < Self.frequencies.count else { return nil }
                rate = Self.frequencies[index]
            }
            self.init(objectType: type, sampleRate: rate, channelConfiguration: Int(try reader.bits(4)))
        } catch {
            return nil
        }
    }

    /// Channels of `channelConfiguration` (Table 1.19: 1…6 as numbered, 7 is 7.1, i.e. 8); 0 means the layout is
    /// given elsewhere (a program_config_element) and is returned as 0.
    package var channels: Int { channelConfiguration == 7 ? 8 : channelConfiguration }

    /// The config's bytes: audioObjectType (from 32 on, the 31 escape and 6 bits), the samplingFrequencyIndex for a
    /// rate in `frequencies` or else 15 and the explicit 24-bit frequency, channelConfiguration, then the object
    /// type's own config, zero-padded to whole bytes:
    /// - AAC-LC: GASpecificConfig all zero (frameLengthFlag 0 = 1024-sample frames, no core coder, no extension).
    /// - AAC-ELD: ELDSpecificConfig with frameLengthFlag 1 (480-sample frames), no resilience flags, no LD-SBR and
    ///   ELDEXT_TERM, then epConfig 0.
    ///
    /// nil for other object types, a channelConfiguration outside 0…15 or a rate outside the table that 24 bits
    /// cannot carry (negative, 2²⁴ Hz and above). Explicit rates outside `explicitSampleRates` are written (the parser
    /// rejects them).
    package var encoded: Data? {
        var fields: [(value: UInt32, bits: Int)]
        switch objectType {
        case Self.aacLC: fields = [(UInt32(Self.aacLC), 5)]
        case Self.aacELD: fields = [(31, 5), (UInt32(Self.aacELD - 32), 6)]
        default: return nil
        }
        if let index = Self.frequencies.firstIndex(of: sampleRate) {
            fields.append((UInt32(index), 4))
        } else {
            guard (0..<(1 << 24)).contains(sampleRate) else { return nil }
            fields += [(15, 4), (UInt32(sampleRate), 24)]
        }
        guard (0...15).contains(channelConfiguration) else { return nil }
        fields.append((UInt32(channelConfiguration), 4))
        if objectType == Self.aacELD {
            // frameLengthFlag; aacSection-, aacScalefactor-, aacSpectralDataResilienceFlag; ldSbrPresentFlag;
            // eldExtType ELDEXT_TERM; epConfig.
            fields += [(1, 1), (0, 3), (0, 1), (0, 4), (0, 2)]
        } else {
            fields.append((0, 3))                       // frameLengthFlag, dependsOnCoreCoder, extensionFlag
        }

        var data = Data()
        var accumulator: UInt64 = 0
        var pending = 0
        for field in fields {
            accumulator = accumulator << UInt64(field.bits) | UInt64(field.value)
            pending += field.bits
            while pending >= 8 {
                pending -= 8
                data.append(UInt8(truncatingIfNeeded: accumulator >> UInt64(pending)))
            }
        }
        if pending > 0 { data.append(UInt8(truncatingIfNeeded: accumulator << UInt64(8 - pending))) }
        return data
    }
}
