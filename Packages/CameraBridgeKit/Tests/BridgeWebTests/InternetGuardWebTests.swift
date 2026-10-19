import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The internet guard on the web API: `status.security.guard` (what the box saw of the camera; null where there is no guard) and the day's
/// notice in the banner list, with the camera page as its action.
@Suite(.timeLimit(.minutes(1))) struct InternetGuardWebTests {
    static let now = Date(timeIntervalSince1970: 1_792_224_000)   // 2026-10-17T08:00:00Z

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder.iso.encode(value)) as? [String: Any])
    }

    @Test func theSecurityCarriesWhatTheGuardSaw() throws {
        let activity = CameraGuardActivity(watched: true, today: 3, last24h: 5, names: [
            GuardReport.Lookup(name: "dev.hik-connect.com", count: 4, first: Self.now.addingTimeInterval(-3 * 86_400), last: Self.now),
            GuardReport.Lookup(name: "time.example.com", count: 1),
        ])
        let security = CameraSecurity(level: .yellow, title: "Needs work", summary: "…", findings: [], checkedAt: Self.now, internetGuard: activity)
        let object = try json(CameraSecurityResource(security))
        let guarded = try #require(object["guard"] as? [String: Any])
        #expect(guarded["watched"] as? Bool == true && guarded["today"] as? Int == 3 && guarded["last24h"] as? Int == 5)
        let names = try #require(guarded["names"] as? [[String: Any]])
        #expect(names.count == 2 && names[0]["name"] as? String == "dev.hik-connect.com" && names[0]["count"] as? Int == 4)
        #expect(names[0]["first"] as? String == "2026-10-14T08:00:00Z" && names[0]["last"] as? String == "2026-10-17T08:00:00Z")
        #expect(names[1]["first"] is NSNull && names[1]["last"] is NSNull, "every key is always there")
        #expect(Set(names[0].keys) == ["name", "count", "first", "last"])

        let mac = try json(CameraSecurityResource(CameraSecurity(level: .green, title: "Good", summary: "…", findings: [], checkedAt: Self.now)))
        #expect(mac["guard"] is NSNull, "no guard on this bridge")
    }

    @Test func theDaysNoticeIsInTheBannerList() throws {
        let camera = CameraConfiguration(name: "North", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.168.77.21"), username: "admin")
        let notice = InternetGuardNotice(day: Self.now.addingTimeInterval(-8 * 3600), lookups: 7, cameras: 2, cameraID: camera.id, cameraName: "North",
                                         date: Self.now)
        let overview = BridgeOverview(state: .running, cameras: [], configurations: [camera], localNetworkAccess: .granted,
                                      networkNotices: [NetworkNotice(kind: .dualHomedSubnet, interfaceName: "eth0, wlan0", detail: "192.168.77.0/24",
                                                                     date: Self.now)],
                                      internetGuardNotice: notice)
        let notices = NoticeResource.resources(for: overview, now: Self.now)
        #expect(notices.map(\.kind) == ["dualHomedSubnet", "internetGuard"])
        let shown = try #require(notices.last)
        #expect(shown.id == "internet-guard" && shown.severity == "info" && shown.title == "Cameras Tried to Reach the Internet")
        #expect(shown.detail == "Internet guard blocked 7 lookups from 2 cameras today.", "a notice made without its cameras says what it did before")
        #expect(shown.action == "open-camera" && shown.cameraID == camera.id && shown.cameraName == "North" && shown.date == Self.now)
        #expect(NoticeResource.resources(for: BridgeOverview(state: .running, cameras: [], configurations: [camera]), now: Self.now).isEmpty)
    }

    /// The notice carries every camera that tried, most first, with its count and most asked name (null when none is known), and the
    /// text names them; `cameraID`, `cameraName` and `action` stay as before (the page falls back to them on a bridge from before). The
    /// other notices carry no `cameras`, nor does a guard notice without any.
    @Test func theNoticeCarriesEveryCameraThatTried() throws {
        let north = UUID(), south = UUID()
        let tried = [InternetGuardNotice.Camera(id: south, name: "South", today: 5, mostAsked: "*.p2p.example.com"),
                     InternetGuardNotice.Camera(id: north, name: "North", today: 2, mostAsked: nil)]
        let notice = InternetGuardNotice(day: Self.now.addingTimeInterval(-8 * 3600), lookups: 7, cameras: 2, cameraID: south, cameraName: "South",
                                         date: Self.now, tried: tried)
        let resource = try #require(NoticeResource.internetGuardNotice(notice))
        #expect(resource.detail == "Internet guard blocked 7 lookups from 2 cameras today. South tried 5 times, North 2 times.")
        let object = try json(resource)
        #expect(Set(object.keys) == ["id", "kind", "severity", "title", "detail", "cameraID", "cameraName", "date", "action", "cameras"])
        #expect(object["cameraID"] as? String == south.uuidString && object["cameraName"] as? String == "South" && object["action"] as? String == "open-camera")
        let cameras = try #require(object["cameras"] as? [[String: Any]])
        #expect(cameras.map { $0["id"] as? String } == [south.uuidString, north.uuidString])
        #expect(cameras.map { $0["name"] as? String } == ["South", "North"] && cameras.map { $0["today"] as? Int } == [5, 2])
        #expect(cameras[0]["mostAsked"] as? String == "*.p2p.example.com" && cameras[1]["mostAsked"] is NSNull, "every key is always there")
        #expect(Set(cameras[0].keys) == ["id", "name", "today", "mostAsked"])

        let storage = NoticeResource(id: "nvr-storage", kind: "nvrStorage", severity: "warning", title: "t", detail: "d", date: Self.now, action: "open-settings")
        #expect(try json(storage)["cameras"] == nil, "only the guard's notice names cameras")
        let without = InternetGuardNotice(day: notice.day, lookups: 7, cameras: 2, cameraID: south, cameraName: "South", date: Self.now)
        let bare = try json(try #require(NoticeResource.internetGuardNotice(without)))
        #expect(bare["cameras"] == nil, "an empty list is left out: the page falls back to cameraID")
        #expect(bare["cameraID"] as? String == south.uuidString && bare["action"] as? String == "open-camera")
    }
}
