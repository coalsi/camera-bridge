import AppKit
import Foundation
import Testing

/// The app's picture refresh (hero every 10 s, sidebar thumbnails every 45 s) runs only while somebody can see the manager
/// window. The log of 2026-10-02 showed a 4K keyframe decoded for each of four cameras every 10 s for hours, with nobody
/// looking: the timers ran for as long as the views existed, window on screen or not.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SnapshotRefreshTests {
    /// A tiny valid PNG.
    private static func picture() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return image?.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test func policyTimesThePicturesByWhatTheWindowShows() {
        #expect(SnapshotRefreshPolicy.wait(base: SnapshotRefreshPolicy.heroInterval, state: .hidden) == nil, "nothing is fetched for a window nobody sees")
        #expect(SnapshotRefreshPolicy.wait(base: SnapshotRefreshPolicy.heroInterval, state: .active) == .seconds(10))
        #expect(SnapshotRefreshPolicy.wait(base: SnapshotRefreshPolicy.thumbnailInterval, state: .active) == .seconds(45))
        let backgrounded = SnapshotRefreshPolicy.wait(base: SnapshotRefreshPolicy.heroInterval, state: .backgrounded)
        #expect(backgrounded.map { $0 >= .seconds(60) } == true, "another app in front: rarely")
        // Sidebar thumbnails between 30 and 60 s.
        #expect(SnapshotRefreshPolicy.thumbnailInterval >= .seconds(30) && SnapshotRefreshPolicy.thumbnailInterval <= .seconds(60))
    }

    @Test func aHiddenWindowFetchesNothingAndAVisibleOneFetchesAtOnce() async throws {
        let activity = WindowActivity(state: .hidden)
        let store = SnapshotStore()
        let calls = Counter()
        let loop = Task { await store.keepFresh(interval: .milliseconds(20), activity: activity) { calls.count += 1 } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.count == 0, "no fetch while the window is hidden (\(calls.count))")

        activity.update(.active)
        try await waitUntil { calls.count >= 3 }
        #expect(calls.count >= 3, "it refreshes on its interval while the window is on screen")

        activity.update(.hidden)
        try await Task.sleep(for: .milliseconds(80))   // a refresh in flight may finish
        let stopped = calls.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.count == stopped, "and stops again when it is hidden (\(calls.count) vs \(stopped))")

        activity.update(.active)
        try await waitUntil { calls.count > stopped }
        #expect(calls.count > stopped, "a window that comes back refreshes at once")
        loop.cancel()
        await loop.value
    }

    @Test func aTaskWaitingForAHiddenWindowEndsWhenItIsCancelled() async throws {
        let activity = WindowActivity(state: .hidden)
        let store = SnapshotStore()
        let calls = Counter()
        let loop = Task { await store.keepFresh(interval: .seconds(10), activity: activity) { calls.count += 1 } }
        try await Task.sleep(for: .milliseconds(100))
        loop.cancel()
        await loop.value   // returns: a hidden window's refresh task does not hang around
        #expect(calls.count == 0)
    }

    @Test func fetchesPerMinuteDropFromEveryTenSecondsForeverToNothingWhileHidden() async throws {
        // 60 s of the app's cadence, scaled 1:100 (10 s -> 100 ms, 60 s -> 600 ms): visible the whole time, then hidden the whole time.
        func fetches(state: WindowActivity.State) async throws -> Int {
            let activity = WindowActivity(state: state)
            let store = SnapshotStore()
            let calls = Counter()
            let loop = Task { await store.keepFresh(interval: .milliseconds(100), activity: activity) { calls.count += 1 } }
            try await Task.sleep(for: .milliseconds(620))
            loop.cancel()
            await loop.value
            return calls.count
        }
        let visible = try await fetches(state: .active)
        let hidden = try await fetches(state: .hidden)
        #expect((3...9).contains(visible), "about one fetch per interval while visible (7 expected, scheduling jitter allowed): \(visible)")
        #expect(hidden == 0, "none while hidden: \(hidden)")
    }

    @Test func aFetchWithinTheMinimumIntervalIsSkippedAndAMissingPictureKeepsTheLastOne() async {
        let store = SnapshotStore()
        let id = UUID()
        let calls = Counter()
        await store.refresh(cameraID: id, minimumInterval: 60) { calls.count += 1; return Self.picture() }
        #expect(store.image(for: id) != nil && calls.count == 1)
        await store.refresh(cameraID: id, minimumInterval: 60) { calls.count += 1; return Self.picture() }
        #expect(calls.count == 1, "asked again within the minimum interval: not fetched")
        await store.refresh(cameraID: id, minimumInterval: 0) { calls.count += 1; return nil }
        #expect(calls.count == 2 && store.image(for: id) != nil, "a failed fetch keeps the last good picture")
    }

    // MARK: Helpers

    @MainActor final class Counter { var count = 0 }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
}
