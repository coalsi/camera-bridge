import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The notification log (`notifications.json` in the data directory): an entry is added when a notice first appears or changes, never
/// twice for the same thing, bounded, kept across restarts, with a read marker and a once-only claim for the page's toast.
@Suite(.timeLimit(.minutes(1))) struct NotificationLogTests {
    static let now = Date(timeIntervalSince1970: 1_792_224_000)   // 2026-10-17T08:00:00Z

    private func directory() throws -> URL { try TemporaryDirectory(prefix: "notification-log").url }

    private func storage(_ detail: String = "d", title: String = "Recording Storage Almost Full") -> NoticeResource {
        NoticeResource(id: "nvr-storage", kind: "nvrStorage", severity: "warning", title: title, detail: detail, date: Self.now, action: "open-settings")
    }

    private func tried(_ camera: UUID, name: String = "Patio New") -> NoticeResource {
        NoticeResource(id: "guard-tried-\(camera.uuidString)", kind: "internetGuard", severity: "info", title: "\(name) tried to reach the internet",
                       detail: "Camera Bridge blocked it.", cameraID: camera, cameraName: name, date: Self.now, action: "open-camera")
    }

    @Test func aNoticeIsAddedWhenItFirstAppearsAndOnlyWhenItChanges() throws {
        let log = NotificationLog(directory: try directory())
        log.record([storage()], now: Self.now)
        log.record([storage("another figure")], now: Self.now.addingTimeInterval(5))
        #expect(log.entries().count == 1, "the same notice with other figures is not a new thing")
        log.record([storage(title: "Recording Can’t Continue")], now: Self.now.addingTimeInterval(10))
        #expect(log.entries().map(\.title) == ["Recording Can’t Continue", "Recording Storage Almost Full"], "newest first")
        log.record([], now: Self.now.addingTimeInterval(15))
        log.record([storage(title: "Recording Can’t Continue")], now: Self.now.addingTimeInterval(20))
        #expect(log.entries().count == 3, "it went away and came back: it happened again")
    }

    @Test func anEventIsNotLoggedAgainWhenItLeavesTheListAndComesBack() throws {
        let log = NotificationLog(directory: try directory())
        let camera = UUID()
        log.record([tried(camera)], now: Self.now)
        log.record([], now: Self.now.addingTimeInterval(5))
        log.record([tried(camera)], now: Self.now.addingTimeInterval(10))
        #expect(log.entries().count == 1)
        let entry = try #require(log.entries().first)
        #expect(entry.category == "security" && entry.cameraID == camera && entry.action == "open-camera")
    }

    @Test func theLogIsBoundedByCountAndAge() throws {
        let log = NotificationLog(directory: try directory(), maximumEntries: 3, maximumAge: 90 * 86_400)
        for index in 0..<5 { log.record([tried(UUID(), name: "Camera \(index)")], now: Self.now.addingTimeInterval(Double(index))) }
        #expect(log.entries().map(\.title) == ["Camera 4 tried to reach the internet", "Camera 3 tried to reach the internet", "Camera 2 tried to reach the internet"])
        log.record([], now: Self.now.addingTimeInterval(91 * 86_400))
        #expect(log.entries().isEmpty, "older than 90 days")
    }

    @Test func theLogSurvivesARestartWithItsMarkers() throws {
        let folder = try directory()
        let camera = UUID()
        let first = NotificationLog(directory: folder)
        first.record([storage(), tried(camera)], now: Self.now)
        let id = try #require(first.entries().first { $0.noticeID == "nvr-storage" }?.id)
        first.markRead(ids: [id])
        _ = first.claim([storage()])

        let second = NotificationLog(directory: folder)
        #expect(second.entries().count == 2 && second.unread == 1)
        second.record([storage(), tried(camera)], now: Self.now.addingTimeInterval(60))
        #expect(second.entries().count == 2, "the same things are not new after a restart")
        #expect(second.claim([storage(), tried(camera)]).map(\.noticeID) == ["guard-tried-\(camera.uuidString)"], "the storage toast was shown already")
    }

    @Test func aToastIsClaimedOnceAndMarkAllReadClears() throws {
        let log = NotificationLog(directory: try directory())
        let notices = [storage()]
        log.record(notices, now: Self.now)
        #expect(log.claim(notices).count == 1)
        #expect(log.claim(notices).isEmpty, "not again on a reload, another page or another browser")
        #expect(log.unread == 1)
        log.markRead(ids: nil)
        #expect(log.unread == 0 && log.entries().allSatisfy(\.read))
    }

    @Test func aDamagedFileStartsAnEmptyLog() throws {
        let folder = try directory()
        try Data("{nope".utf8).write(to: folder.appending(path: "notifications.json"))
        let log = NotificationLog(directory: folder)
        #expect(log.entries().isEmpty)
        log.record([storage()], now: Self.now)
        #expect(log.entries().count == 1)
    }
}
