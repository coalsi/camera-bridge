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
        ], last7d: 296)
        let security = CameraSecurity(level: .yellow, title: "Needs work", summary: "…", findings: [], checkedAt: Self.now, internetGuard: activity)
        let object = try json(CameraSecurityResource(security))
        let guarded = try #require(object["guard"] as? [String: Any])
        #expect(guarded["watched"] as? Bool == true && guarded["today"] as? Int == 3 && guarded["last24h"] as? Int == 5 && guarded["last7d"] as? Int == 296)
        let names = try #require(guarded["names"] as? [[String: Any]])
        #expect(names.count == 2 && names[0]["name"] as? String == "dev.hik-connect.com" && names[0]["count"] as? Int == 4)
        #expect(names[0]["first"] as? String == "2026-10-14T08:00:00Z" && names[0]["last"] as? String == "2026-10-17T08:00:00Z")
        #expect(names[1]["first"] is NSNull && names[1]["last"] is NSNull, "every key is always there")
        #expect(Set(names[0].keys) == ["name", "count", "first", "last"])

        let mac = try json(CameraSecurityResource(CameraSecurity(level: .green, title: "Good", summary: "…", findings: [], checkedAt: Self.now)))
        #expect(mac["guard"] is NSNull, "no guard on this bridge")
    }

    @Test func theGuardsAlertsAreInTheNoticeList() throws {
        let camera = CameraConfiguration(name: "North", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.168.77.21"), username: "admin")
        let alerts = [InternetGuardAlert(cameraID: camera.id, cameraName: "North", kind: .firstTry, date: Self.now),
                      InternetGuardAlert(cameraID: camera.id, cameraName: "North", kind: .stoppedAsking, date: Self.now)]
        let overview = BridgeOverview(state: .running, cameras: [], configurations: [camera], localNetworkAccess: .granted,
                                      networkNotices: [NetworkNotice(kind: .dualHomedSubnet, interfaceName: "eth0, wlan0", detail: "192.168.77.0/24",
                                                                     date: Self.now)],
                                      internetGuardAlerts: alerts)
        let notices = NoticeResource.resources(for: overview, now: Self.now)
        #expect(notices.map(\.kind) == ["dualHomedSubnet", "internetGuard", "internetGuard"], "no daily notice")
        let tried = notices[1], away = notices[2]
        #expect(tried.id == "guard-tried-\(camera.id.uuidString)" && tried.severity == "info" && tried.title == "North tried to reach the internet")
        #expect(tried.action == "open-camera" && tried.cameraID == camera.id && tried.cameraName == "North" && tried.category == "security")
        #expect(away.severity == "warning")
        let object = try json(tried)
        #expect(Set(object.keys) == ["id", "kind", "severity", "title", "detail", "cameraID", "cameraName", "date", "action", "category", "key"])
        #expect(NoticeResource.resources(for: BridgeOverview(state: .running, cameras: [], configurations: [camera]), now: Self.now).isEmpty)
    }
}
