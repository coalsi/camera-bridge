import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The banner: the storage notice, its action, and how it travels (contract C.7).
@Suite(.timeLimit(.minutes(1))) struct NVRNoticeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gigabyte: UInt64 = 1_000_000_000
    private let gibibyte: UInt64 = 1_073_741_824

    private func overview(recording: Bool = true, folder: String? = NVRRig.folder, storage: ArchiveStorageStatus? = nil, notices: [NetworkNotice] = []) -> BridgeOverview {
        var camera = CameraConfiguration(name: "Porch", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: "")
        camera.nvrEnabled = recording
        var settings = BridgeSettings()
        settings.nvrFolder = folder
        return BridgeOverview(state: .running, cameras: [], configurations: [camera], localNetworkAccess: .granted, networkNotices: notices, settings: settings, nvrStorage: storage)
    }

    /// A drive with `spare` bytes above the floor.
    private func drive(spare: UInt64, pause: ArchivePause? = nil, total: UInt64 = 500_000_000_000) -> ArchiveStorageStatus {
        ArchiveStorageStatus(pause: pause, usedBytes: 100 * gigabyte, freeBytes: 25 * gibibyte + spare, totalBytes: total, floorBytes: 25 * gibibyte)
    }

    @Test func aBridgeWhereNothingRecordsSaysNothingAboutStorage() {
        for storage in [nil, drive(spare: 0, pause: .diskFull), drive(spare: 1_000)] as [ArchiveStorageStatus?] {
            #expect(NoticeResource.resources(for: overview(recording: false, folder: nil, storage: storage), now: now).isEmpty)
        }
    }

    @Test func recordingWithNoFolderAsksForOne() throws {
        let notice = try #require(NoticeResource.resources(for: overview(folder: nil), now: now).first)
        #expect(notice.id == "nvr-storage" && notice.kind == "nvrStorage" && notice.severity == "warning")
        #expect(notice.title == "Recording Can’t Continue" && notice.detail == "Choose where to store recordings.")
        #expect(notice.action == "choose-folder" && notice.cameraID == nil && notice.cameraName == nil && notice.date == now)
    }

    @Test func everyOtherPauseSendsThePersonToTheSettings() throws {
        let cases: [(ArchivePause, String)] = [
            (.folderMissing, "The recordings folder isn’t available. Reconnect the drive or choose another folder."),
            (.diskFull, "There isn’t enough free space on the recordings drive."), (.notWritable("The drive isn’t answering."), "The drive isn’t answering."),
        ]
        for (pause, sentence) in cases {
            let notices = NoticeResource.resources(for: overview(storage: drive(spare: 20 * gigabyte, pause: pause)), now: now)
            #expect(notices.count == 1)
            let notice = try #require(notices.first)
            #expect(notice.title == "Recording Can’t Continue" && notice.detail == sentence && notice.action == "open-settings", "\(pause)")
        }
        let noFolderButStorageKnown = NoticeResource.resources(for: overview(folder: nil, storage: drive(spare: 20 * gigabyte)), now: now)
        #expect(noFolderButStorageKnown.first?.action == "choose-folder", "no folder wins over whatever the engine measured")
    }

    @Test func lowSpaceIsAnnouncedBeforeTheDriveIsFull() throws {
        let low = try #require(NoticeResource.resources(for: overview(storage: drive(spare: 3_200_000_000)), now: now).first)
        #expect(low.title == "Recording Storage Almost Full" && low.detail == "About 3 GB are left before recording pauses." && low.action == "open-settings")
        #expect(low.severity == "warning" && low.id == "nvr-storage")
        #expect(NoticeResource.resources(for: overview(storage: drive(spare: 5 * gibibyte)), now: now).isEmpty, "5 GiB above the floor is enough")
        #expect(NoticeResource.resources(for: overview(storage: drive(spare: 5 * gibibyte - 1)), now: now).first?.detail == "About 5 GB are left before recording pauses.")
        #expect(NoticeResource.resources(for: overview(storage: drive(spare: 0)), now: now).first?.detail == "About 0 GB are left before recording pauses.")
        #expect(NoticeResource.resources(for: overview(storage: drive(spare: 0, total: 0)), now: now).isEmpty, "a drive that was never measured says nothing")
        #expect(NoticeResource.resources(for: overview(storage: nil), now: now).isEmpty)
    }

    @Test func aPauseWinsOverLowSpace() throws {
        let notice = try #require(NoticeResource.resources(for: overview(storage: drive(spare: 1_000_000_000, pause: .diskFull)), now: now).first)
        #expect(notice.title == "Recording Can’t Continue")
    }

    @Test func theTextChangesAtMostOncePerGigabyteSoTheEventStreamStaysQuiet() {
        var details: [String] = []
        var spare = 5 * gibibyte
        while spare > 0 {
            spare -= min(spare, 10_000_000)   // the engine rounds to 10 MB
            if let detail = NoticeResource.resources(for: overview(storage: drive(spare: spare)), now: now).first?.detail, details.last != detail { details.append(detail) }
        }
        #expect(details == (0...5).reversed().map { "About \($0) GB are left before recording pauses." }, "\(details)")
    }

    @Test func theStorageNoticeComesFirstAndTheNetworkNoticesAreKept() {
        let network = NetworkNotice(kind: .dualHomedSubnet, interfaceName: "eth0, wlan0")
        let notices = NoticeResource.resources(for: overview(folder: nil, notices: [network]), now: Date())   // a network notice fades with the clock
        #expect(notices.map(\.id) == ["nvr-storage", network.id])
        #expect(notices.map(\.action) == ["choose-folder", nil])
    }

    @Test func theActionIsAlwaysEncodedAndTheOtherKeysAreAsBefore() throws {
        func json(_ notice: NoticeResource) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: try JSONEncoder.iso.encode(notice)) as? [String: Any])
        }
        let storage = try json(try #require(NoticeResource.resources(for: overview(folder: nil), now: now).first))
        #expect(Set(storage.keys) == ["id", "kind", "severity", "title", "detail", "date", "action"], "no camera: those two keys stay out, as for other notices")
        #expect(storage["action"] as? String == "choose-folder")
        let network = try json(try #require(NoticeResource.resources(for: overview(recording: false, notices: [NetworkNotice(kind: .dualHomedSubnet, interfaceName: "eth0, wlan0")]),
                                                                     now: Date()).first))
        #expect(network["action"] is NSNull && network["kind"] as? String == "dualHomedSubnet")
        let camera = try json(NoticeResource(id: "x", kind: "k", severity: "info", title: "t", detail: "d", cameraID: UUID(), cameraName: "Porch", date: now))
        #expect(Set(camera.keys) == ["id", "kind", "severity", "title", "detail", "cameraID", "cameraName", "date", "action"])
    }

    @Test func theStatusAnswerCarriesTheNoticeAndLeavesItOutWhenAllIsWell() async throws {
        let rig = try await NVRRig.make()
        #expect((await rig.get("status")).array("notices").isEmpty)
        rig.backend.write { $0.configurations[0].nvrEnabled = true; $0.nvrStorage = ArchiveStorageStatus(pause: .folderMissing, totalBytes: 500_000_000_000) }
        let notice = try #require(await rig.get("status").array("notices").first)
        #expect(notice["id"] as? String == "nvr-storage" && notice["title"] as? String == "Recording Can’t Continue" && notice["action"] as? String == "open-settings")
        rig.backend.write { $0.nvrStorage = ArchiveStorageStatus(usedBytes: 1, freeBytes: 400_000_000_000, totalBytes: 500_000_000_000, floorBytes: 25_000_000_000) }
        #expect((await rig.get("status")).array("notices").isEmpty)
    }

    @Test func theEventStreamAnnouncesEachChangeOnceAndTellsANewListenerAtOnce() async throws {
        let rig = try await NVRRig.make()
        rig.backend.write { $0.configurations[0].nvrEnabled = true; $0.nvrStorage = ArchiveStorageStatus(freeBytes: 400_000_000_000, totalBytes: 500_000_000_000, floorBytes: 25_000_000_000) }
        rig.harness.app.startEvents()
        defer { rig.harness.app.stopEvents() }
        let stream = await rig.session.stream("/api/v1/events")
        defer { stream.stop() }
        func announcements() -> Int { stream.text.components(separatedBy: "event: notices\n").count - 1 }
        #expect(await stream.wait { $0.contains("event: notices") }, "the snapshot a new listener gets")
        try await Task.sleep(for: .milliseconds(150))   // the hub takes its baseline
        #expect(announcements() == 1 && !stream.text.contains("Recording Can’t Continue"))
        rig.backend.write { $0.nvrStorage = ArchiveStorageStatus(pause: .folderMissing, totalBytes: 500_000_000_000) }
        #expect(await stream.wait { $0.contains("Recording Can’t Continue") })
        try await Task.sleep(for: .milliseconds(300))   // many polls pass: the same notice is not announced again
        #expect(announcements() == 2)
        rig.backend.write { $0.nvrStorage = ArchiveStorageStatus(pause: .diskFull, totalBytes: 500_000_000_000) }
        #expect(await stream.wait { $0.contains("There isn’t enough free space") })
        rig.backend.write { $0.nvrStorage = ArchiveStorageStatus(freeBytes: 400_000_000_000, totalBytes: 500_000_000_000, floorBytes: 25_000_000_000) }
        #expect(await eventually { announcements() == 4 }, "and one more when it goes away: \(announcements())")
        let late = await rig.session.stream("/api/v1/events")
        defer { late.stop() }
        rig.backend.write { $0.nvrStorage = ArchiveStorageStatus(pause: .notWritable("The drive isn’t answering."), totalBytes: 500_000_000_000) }
        #expect(await late.wait { $0.contains("The drive isn’t answering.") })
    }
}
