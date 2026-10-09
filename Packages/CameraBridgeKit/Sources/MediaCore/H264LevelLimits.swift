import Foundation

/// The picture-size limits of ITU-T H.264 Table A-1 per `level_idc`: MaxFS (macroblocks per frame), MaxMBPS
/// (macroblocks per second) and, from MaxFS, the per-dimension limit of §A.3.1 (PicWidthInMbs and FrameHeightInMbs
/// ≤ √(8 × MaxFS)).
///
/// The package's only copy of the table: BridgeEngine's passthrough decisions and PlatformApple's encoder level both use
/// it, so a camera picture "fits a level" by the same rule the encoder applies.
package enum H264LevelLimits {
    package struct Limits: Equatable, Sendable {
        /// MaxFS.
        package var maxFrameSize: Int
        /// MaxMBPS.
        package var maxMacroblockRate: Int
        /// √(8 × MaxFS), rounded down: the most macroblocks a picture may have across or down.
        package var maxDimension: Int { Int((8 * Double(maxFrameSize)).squareRoot()) }
    }

    /// Table A-1's `level_idc` values in ascending order (9 is level 1b for the High profiles, 11 with
    /// constraint_set3_flag is 1b for the others).
    package static let levelIDCs = [9, 10, 11, 12, 13, 20, 21, 22, 30, 31, 32, 40, 41, 42, 50, 51, 52]

    /// nil for values outside Table A-1.
    package static func limits(levelIDC: Int) -> Limits? {
        switch levelIDC {
        case 9, 10: Limits(maxFrameSize: 99, maxMacroblockRate: 1_485)
        case 11: Limits(maxFrameSize: 396, maxMacroblockRate: 3_000)
        case 12: Limits(maxFrameSize: 396, maxMacroblockRate: 6_000)
        case 13, 20: Limits(maxFrameSize: 396, maxMacroblockRate: 11_880)
        case 21: Limits(maxFrameSize: 792, maxMacroblockRate: 19_800)
        case 22: Limits(maxFrameSize: 1_620, maxMacroblockRate: 20_250)
        case 30: Limits(maxFrameSize: 1_620, maxMacroblockRate: 40_500)
        case 31: Limits(maxFrameSize: 3_600, maxMacroblockRate: 108_000)
        case 32: Limits(maxFrameSize: 5_120, maxMacroblockRate: 216_000)
        case 40, 41: Limits(maxFrameSize: 8_192, maxMacroblockRate: 245_760)
        case 42: Limits(maxFrameSize: 8_704, maxMacroblockRate: 522_240)
        case 50: Limits(maxFrameSize: 22_080, maxMacroblockRate: 589_824)
        case 51: Limits(maxFrameSize: 36_864, maxMacroblockRate: 983_040)
        case 52: Limits(maxFrameSize: 36_864, maxMacroblockRate: 2_073_600)
        default: nil
        }
    }

    /// Whether a `width`×`height` picture at `fps` stays within the level's frame size, macroblock rate and
    /// per-dimension limit. False for an unknown level or an empty picture (and, without overflowing, for sizes far
    /// beyond any level).
    package static func fits(width: Int, height: Int, fps: Double, levelIDC: Int) -> Bool {
        guard let limits = limits(levelIDC: levelIDC), (1...65_536).contains(width), (1...65_536).contains(height) else { return false }
        let columns = (width + 15) / 16
        let rows = (height + 15) / 16
        let macroblocks = columns * rows
        return macroblocks <= limits.maxFrameSize && Double(macroblocks) * max(0, fps) <= Double(limits.maxMacroblockRate)
            && columns <= limits.maxDimension && rows <= limits.maxDimension
    }

    /// The lowest `level_idc`, not below `minimum`, that `width`×`height` at `fps` fits; nil beyond level 5.2.
    package static func lowestLevel(width: Int, height: Int, fps: Double, atLeast minimum: Int) -> Int? {
        levelIDCs.first { $0 >= minimum && fits(width: width, height: height, fps: fps, levelIDC: $0) }
    }
}
