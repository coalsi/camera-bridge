import Foundation
import Testing

/// The camera page's navigation state: what a tap on the dashboard (a stat tile, the Apple Home card) does to the selected
/// tab, the open checklist and the scroll. The bug (2026-10-02): "View Checklist" on the wide dashboard set the tab to
/// Overview, which was already selected, and nothing else, so with the checklist closed (or off screen below the hero) the
/// button seemed to do nothing.
@Suite(.timeLimit(.minutes(1))) struct CameraPageNavigationTests {
    @Test func viewChecklistSelectsOverviewOpensTheChecklistAndScrollsToItFromEveryTab() {
        for tab in CameraTab.allCases {
            var page = CameraPageState(tab: tab, isChecklistExpanded: false)
            page.show(.readinessChecklist)
            #expect(page.tab == .overview, "from \(tab)")
            #expect(page.isChecklistExpanded, "the checklist is open from \(tab)")
            #expect(page.scrollRequest?.anchor == .tabContent, "and the page scrolls to the tab's content from \(tab)")
        }
    }

    @Test func viewChecklistWhileAlreadyOnOverviewStillChangesSomething() {
        // The original failure: tab was already .overview, the checklist closed, nothing observable happened.
        let before = CameraPageState(tab: .overview, isChecklistExpanded: false)
        var after = before
        after.show(.readinessChecklist)
        #expect(after != before)
        #expect(after.isChecklistExpanded && after.scrollRequest != nil)
    }

    @Test func theSameDestinationTwiceScrollsTwice() throws {
        var page = CameraPageState()
        page.show(.readinessChecklist)
        let first = try #require(page.scrollRequest)
        page.show(.readinessChecklist)
        let second = try #require(page.scrollRequest)
        #expect(first.anchor == second.anchor && first.serial != second.serial, "the view scrolls when the serial changes")
    }

    @Test func eachDestinationSelectsItsTabAndScrollsToItsContent() {
        let expected: [(CameraPageDestination, CameraTab)] = [
            (.pairing, .overview),               // Apple Home tile, "Show QR Code"
            (.readinessChecklist, .overview),    // HomeKit Readiness tile, "View Checklist"
            (.streams, .streams),                // Streams tile
            (.liveView, .streams),               // Live View tile
            (.recording, .recording),            // Recording tile
            (.motion, .motion),                  // Motion tile
        ]
        #expect(expected.count == CameraPageDestination.allCases.count, "every destination is covered")
        for (destination, tab) in expected {
            var page = CameraPageState(tab: .advanced)
            page.show(destination)
            #expect(page.tab == tab, "\(destination)")
            #expect(page.scrollRequest?.anchor == .tabContent, "\(destination)")
            #expect(destination.tab == tab)
        }
    }

    @Test func onlyTheChecklistDestinationOpensTheChecklistAndNothingCollapsesIt() {
        for destination in CameraPageDestination.allCases where destination != .readinessChecklist {
            var page = CameraPageState(tab: .motion, isChecklistExpanded: false)
            page.show(destination)
            #expect(!page.isChecklistExpanded, "\(destination) leaves a closed checklist closed")
        }
        var open = CameraPageState(tab: .overview, isChecklistExpanded: true)
        open.show(.streams)
        #expect(open.isChecklistExpanded, "going to another tab and back finds the checklist as it was")
    }

    @Test func theDestinationsBehindTheDashboardCoverEveryTabTheTilesShow() {
        // The six stat tiles / two Apple Home buttons reach these destinations (CameraDashboard): Overview, Streams, Recording and
        // Motion & Events. Advanced is the tab strip's alone.
        let reached = Set(CameraPageDestination.allCases.map(\.tab))
        #expect(reached == [.overview, .streams, .recording, .motion])
    }
}
