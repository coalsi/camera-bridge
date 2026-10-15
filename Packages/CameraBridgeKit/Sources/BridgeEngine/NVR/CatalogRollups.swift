import Foundation

/// The catalog's name for the file-end and per-minute-rollup arithmetic (T00 B.8), which is T01's `FragmentIndexer`: the recorder writes the
/// sidecar with it, the scanner rebuilds one with it, and the catalog derives the rollups of a file that is still open with it, so that all
/// three agree to the byte. Nothing is computed here.
enum CBIndexRollups {
    static let minuteMs: Int64 = 60_000

    /// The end of the file whose last record is `last`, in epoch milliseconds.
    static func endWallMs(startWallMs: Int64, last: CBIndexFragmentRecord) -> Int64 {
        FragmentIndexer.endWallMs(startWallMs: startWallMs, records: [last])
    }

    /// Empty without records; at most `CBIndexFormat.maximumRollups`.
    static func make(fragments: [CBIndexFragmentRecord]) -> [CBIndexRollup] {
        FragmentIndexer.rollups(startWallMs: 0, records: fragments)
    }
}
