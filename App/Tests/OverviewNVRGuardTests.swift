import Foundation
import Testing

/// The Overview's tile arithmetic that the NVR change must not disturb (the corner buttons live inside the picture; the info area keeps its height).
@Suite struct OverviewNVRGuardTests {
    @Test func theInfoAreaKeepsTheHeightsTheLayoutTestsAssume() {
        #expect(OverviewGridMetrics.fullInfoHeight == 108, "raising it to 132 pushes a 3x3 grid at 1100x900 from full to compact (OverviewLayoutTests)")
        #expect(OverviewGridMetrics.compactInfoHeight == 34)
        #expect(OverviewGridMetrics.fullMinimumWidth == 300 && OverviewGridMetrics.compactMinimumWidth == 190)
    }

    @Test func aThreeByThreeStaysFullAtTheSizesTheOverviewReviewUses() {
        func density(_ columns: Int, _ rows: Int, _ width: CGFloat, _ height: CGFloat) -> OverviewGridMetrics.Density {
            OverviewGridMetrics.fit(available: CGSize(width: width, height: height), columns: columns, rows: rows).density
        }
        #expect(density(3, 3, 1_100, 900) == .full)
        #expect(density(3, 3, 1_700, 1_000) == .full)
    }
}
