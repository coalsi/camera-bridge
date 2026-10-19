import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing

@Suite struct LogFilterTests {
    private let camera = UUID()
    private var entries: [LogEntry] {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        return [
            LogEntry(date: base, level: .debug, category: "HAP", message: "pair-verify done", cameraID: camera),
            LogEntry(date: base + 1, level: .info, category: "RTSP", message: "Connected to rtsp://192.0.2.1/stream", cameraID: camera),
            LogEntry(date: base + 2, level: .warning, category: "Engine", message: "Webhook port busy"),
            LogEntry(date: base + 3, level: .error, category: "RTSP", message: "Garage timed out", cameraID: UUID()),
        ]
    }

    @Test func showsNewestFirst() {
        #expect(LogFilter().apply(to: entries).map(\.message) == ["Garage timed out", "Webhook port busy",
                                                                   "Connected to rtsp://192.0.2.1/stream", "pair-verify done"])
    }

    @Test func filtersByLevelSearchAndCamera() {
        #expect(LogFilter(minimumLevel: .warning).apply(to: entries).count == 2)
        #expect(LogFilter(searchText: "rtsp").apply(to: entries).count == 2)          // category or message, any case
        #expect(LogFilter(searchText: "  webhook ").apply(to: entries).map(\.category) == ["Engine"])
        #expect(LogFilter(cameraID: camera).apply(to: entries).count == 2)
        #expect(LogFilter(minimumLevel: .info, searchText: "connected", cameraID: camera).apply(to: entries).count == 1)
    }

    @Test func plainTextExportIsOneLinePerEntry() {
        let text = LogFilter.plainText(LogFilter().apply(to: entries))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].contains("ERROR") && lines[0].contains("[RTSP]") && lines[0].hasSuffix("Garage timed out"))
        #expect(LogFilter.levelName(.notice) == "Notice")
    }

    /// Review finding (W4 App): the camera page keeps only the camera's own entries, and HAP, HAPCamera, HDS and RTSP
    /// logged without a camera, so a recording stream's close never showed there. The engine now tags them
    /// (`RuntimeCameraLogTests` in the package); such an entry is on the camera's page and nowhere else's.
    @Test func cameraPageShowsTheCamerasRecordingLines() {
        let close = LogEntry(date: Date(timeIntervalSince1970: 1_790_000_010), level: .info, category: "camera",
                             message: "Recording stream 1 closed with reason 0: the hub closed it", cameraID: camera)
        #expect(LogFilter(cameraID: camera).apply(to: entries + [close]).first == close)
        #expect(!LogFilter(cameraID: UUID()).apply(to: entries + [close]).contains(close))
    }

    /// Review finding (W4 App): with two cameras, lines like "Recording turned on" in the Settings log didn't say whose
    /// they were. An entry tagged with a camera shows that camera's name — on screen, in the copied text and in the
    /// search — while engine-wide entries and those of a removed camera show none.
    @Test func entriesNameTheirCameraInTheSettingsLog() throws {
        let names = [camera: "Driveway"]
        let all = LogFilter().apply(to: entries, cameraNames: names)
        #expect(LogFilter.cameraName(of: entries[0], in: names) == "Driveway")
        #expect(LogFilter.cameraName(of: entries[2], in: names) == nil, "engine-wide")
        #expect(LogFilter.cameraName(of: entries[3], in: names) == nil, "a camera that is no longer configured")
        let lines = LogFilter.plainText(all, cameraNames: names).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[3].hasSuffix("DEBUG [HAP] Driveway: pair-verify done"))
        #expect(lines[1].hasSuffix("WARNING [Engine] Webhook port busy"))
        #expect(LogFilter.plainText(all) == LogFilter.plainText(all, cameraNames: [:]), "no names, no prefix")
        let found = LogFilter(searchText: "driveway").apply(to: entries, cameraNames: names)
        #expect(found.map(\.message) == ["Connected to rtsp://192.0.2.1/stream", "pair-verify done"])
    }

    /// Spec §3.2 "recent events": the engine's event history for the camera (not the log, which a log level of Notice or
    /// above empties of events), newest first, at most `limit`.
    @Test func recentEventsComeFromTheCamerasEventHistory() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var status = CameraStatus(id: camera, name: "Driveway", kind: .camera, vendor: .hikvision)
        #expect(RecentEvents.newestFirst(in: status).isEmpty)
        #expect(RecentEvents.newestFirst(in: nil).isEmpty)
        status.recentEvents = (0..<7).map { CameraEventRecord(name: "Motion \($0)", date: base + Double($0)) }
        #expect(RecentEvents.newestFirst(in: status, limit: 5).map(\.name) == ["Motion 6", "Motion 5", "Motion 4", "Motion 3", "Motion 2"])
        #expect(RecentEvents.newestFirst(in: status).count == RecentEvents.defaultLimit)
    }
}
