import BridgeEngine
import CameraAdapters
import Foundation
import Testing
@testable import BridgeWeb

/// "Driveway Is Offline" and "Driveway Isn't Recording": only after five minutes, told in the bridge's zone, gone when the camera is back.
@Suite struct CameraNoticesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC, 01:00 in Phoenix

    private func overview(_ connection: ConnectionState, since: TimeInterval, waitingSince: TimeInterval? = nil, enabled: Bool = true,
                          recording: Bool = true) -> BridgeOverview {
        var camera = CameraConfiguration(name: "Driveway", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        camera.isEnabled = enabled
        camera.nvrEnabled = recording
        var status = CameraStatus(id: camera.id, name: camera.name, kind: .camera, vendor: .demo, connection: connection)
        status.connectionSince = now.addingTimeInterval(-since)
        status.nvrWaitingSince = waitingSince.map { now.addingTimeInterval(-$0) }
        if waitingSince != nil { status.nvr.state = .waiting("Waiting for the camera’s video.") }
        var settings = BridgeSettings()
        settings.timeZone = "America/Phoenix"
        return BridgeOverview(state: .running, cameras: [status], configurations: [camera], localNetworkAccess: .granted, networkNotices: [], settings: settings)
    }

    @Test func aCameraOfflineForFiveMinutesIsAWarningWithTheTimeInTheBridgesZone() throws {
        #expect(NoticeResource.cameraNotices(for: overview(.offline("Connection timed out"), since: 299), now: now).isEmpty, "not yet")
        let notice = try #require(NoticeResource.cameraNotices(for: overview(.offline("Connection timed out"), since: 600), now: now).first)
        #expect(notice.title == "Driveway Is Offline" && notice.severity == "warning" && notice.kind == "cameraOffline" && notice.category == "cameras")
        #expect((notice.detail.contains("since 12:50") || notice.detail.contains("since 00:50")) && notice.action == "open-camera", "\(notice.detail)")
        #expect(NoticeResource.cameraNotices(for: overview(.online, since: 600), now: now).isEmpty, "back")
        #expect(NoticeResource.cameraNotices(for: overview(.offline("x"), since: 600, enabled: false), now: now).isEmpty, "turned off on purpose")
    }

    @Test func aCameraOnlineButNotRecordingForFiveMinutesIsAWarning() throws {
        let notice = try #require(NoticeResource.cameraNotices(for: overview(.online, since: 3_600, waitingSince: 900), now: now).first)
        #expect(notice.title == "Driveway Isn’t Recording" && notice.category == "recording")
        #expect(notice.detail.hasSuffix("Waiting for the camera’s video."), "\(notice.detail)")
        #expect(NoticeResource.cameraNotices(for: overview(.online, since: 3_600, waitingSince: 60), now: now).isEmpty)
        #expect(NoticeResource.cameraNotices(for: overview(.online, since: 3_600, waitingSince: 900, recording: false), now: now).isEmpty)
        // They are part of every notice list (status, event stream, notification log).
        #expect(NoticeResource.resources(for: overview(.online, since: 3_600, waitingSince: 900), now: now).contains { $0.kind == "cameraNotRecording" })
    }
}
