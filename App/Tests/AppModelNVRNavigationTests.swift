import BridgeEngine
import Foundation
import Testing

/// The sidebar's arrow keys: the Overview holds the timeline and the recordings, so there is no separate NVR page to go on from.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AppModelNVRNavigationTests {
    @Test func arrowKeysWalkTheSidebarFromTheOverview() {
        let cameras = (0..<2).map { _ in UUID() }
        let order: [ManagerSelection] = [.overview, .camera(cameras[0]), .camera(cameras[1]), .sensorsBridge]
        #expect(SidebarNavigation.next(from: .overview, offset: 1, order: order) == .camera(cameras[0]))
        #expect(SidebarNavigation.next(from: .camera(cameras[0]), offset: -1, order: order) == .overview)
        #expect(SidebarNavigation.next(from: nil, offset: 1, order: order) == .overview)
    }
}
