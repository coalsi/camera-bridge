import Foundation
import Testing
@testable import BridgeSupport

@Suite struct DiagnosticsLogTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "DiagnosticsLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func entry(_ message: String, level: LogLevel = .debug, category: String = "Test", cameraID: UUID? = nil, date: Date = Date()) -> LogEntry {
        LogEntry(date: date, level: level, category: category, message: message, cameraID: cameraID)
    }

    @Test func theMemoryRingIsBoundedAndKeepsTheNewest() {
        let log = DiagnosticsLog(directory: nil, memoryCapacity: 100)
        for index in 0..<1_000 { log.record(entry("line \(index)")) }
        let entries = log.entries()
        #expect(entries.count == 100)
        #expect(entries.first?.message == "line 900" && entries.last?.message == "line 999")
        #expect(log.totalRecorded == 1_000)
        #expect(log.entries(limit: 3).map(\.message) == ["line 997", "line 998", "line 999"])
    }

    @Test func secretsAreRedactedBeforeTheyAreStored() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticsLog(directory: directory)
        log.record(entry("opening rtsp://admin:hunter2@192.0.2.44:554/stream1?token=abc123&channel=1"))
        log.record(entry("login failed password=hunter2 apiKey=XYZ"))
        log.record(entry(#"body {"password": "hunter2", "name": "front"}"#))
        let text = log.entries().map(\.message).joined(separator: "\n")
        #expect(!text.contains("hunter2") && !text.contains("abc123") && !text.contains("XYZ"), "\(text)")
        #expect(text.contains("192.0.2.44") && text.contains("channel=1"), "everything else is kept")
        log.flush()
        let onDisk = log.fileText()
        #expect(!onDisk.contains("hunter2") && !onDisk.contains("abc123"))
    }

    @Test func linesAreSingleLinesWithLevelCategoryAndCamera() {
        let camera = UUID()
        let date = Date(timeIntervalSince1970: 1_790_000_000.25)
        let line = DiagnosticsLog.line(for: entry("first\nsecond", level: .warning, category: "LiveStream", cameraID: camera, date: date),
                                       cameraNames: [camera: "Patio"])
        #expect(line == "2026-09-21T14:13:20.250Z WARNING [LiveStream] <Patio (\(camera.uuidString.prefix(8)))> first\\nsecond", Comment(rawValue: line))
        #expect(DiagnosticsLog.line(for: entry("x")).contains("<-> x"))
    }

    @Test func filesRotateAtTheSizeLimitAndKeepOnlyFiveFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 5 files of at most 2 KiB (the production limits are 5 × 2 MiB).
        let log = DiagnosticsLog(directory: directory, memoryCapacity: 10, fileCount: 5, fileBytes: 2_048)
        for index in 0..<400 { log.record(entry("entry number \(index) " + String(repeating: "x", count: 60))) }
        log.flush()
        let files = log.fileURLs()
        #expect(files.count == 5, "\(files.map(\.lastPathComponent))")
        #expect(files.map(\.lastPathComponent) == ["diagnostics.log", "diagnostics.1.log", "diagnostics.2.log", "diagnostics.3.log", "diagnostics.4.log"])
        for url in files {
            let size = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int ?? 0
            #expect(size <= 2_048 + 200, "\(url.lastPathComponent) holds \(size) bytes")
        }
        let text = log.fileText()
        #expect(text.contains("entry number 399"), "the newest entry is there")
        #expect(!text.contains("entry number 0 "), "the oldest was rotated away")
        // Oldest first.
        let numbers = text.split(separator: "\n").compactMap { $0.split(separator: " ").drop { $0 != "number" }.dropFirst().first.flatMap { Int($0) } }
        #expect(numbers == numbers.sorted() && !numbers.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func aRestartAppendsToTheExistingFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DiagnosticsLog(directory: directory)
        first.record(entry("before the restart"))
        first.flush()
        let second = DiagnosticsLog(directory: directory)
        second.record(entry("after the restart"))
        second.flush()
        let text = second.fileText()
        #expect(text.contains("before the restart") && text.contains("after the restart"))
        #expect(second.entries().map(\.message) == ["after the restart"], "memory holds this run only")
    }

    @Test func aDirectoryThatCannotBeUsedLeavesTheLogInMemory() {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "DiagnosticsLogTests-file-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        let log = DiagnosticsLog(directory: blocker.appending(path: "inside"))
        log.record(entry("still recorded"))
        #expect(log.entries().count == 1 && log.fileURLs().isEmpty)
    }

    @Test func veryLongMessagesAreCut() {
        let log = DiagnosticsLog(directory: nil)
        log.record(entry(String(repeating: "a", count: 50_000)))
        #expect(log.entries()[0].message.count == DiagnosticsLog.maximumMessageLength)
    }
}

@Suite struct SessionTraceTests {
    @Test func phasesAreRecordedOnceWithOffsetsAndTheFirstEndReasonWins() async throws {
        let center = DiagnosticsCenter()
        let id = UUID()
        let camera = UUID()
        let trace = center.begin(kind: "live", id: id, cameraID: camera, summary: "to 192.0.2.69")
        trace.mark("prepare", "ports 1/2")
        try await Task.sleep(for: .milliseconds(30))
        trace.mark("first video packet")
        trace.mark("first video packet", "again")
        trace.finish("controllerTimeout")
        trace.finish("stopped")
        trace.mark("too late")
        let record = try #require(center.sessions(cameraID: camera).first)
        #expect(record.phases.map(\.name) == ["prepare", "first video packet"])
        #expect(record.offset(of: "first video packet").map { $0 >= 0.025 } == true)
        #expect(record.endReason == "controllerTimeout" && (record.duration ?? 0) >= 0.025)
        #expect(record.oneLine.contains("prepare +") && record.oneLine.contains("ended (controllerTimeout)"), Comment(rawValue: record.oneLine))
        #expect(center.sessions(cameraID: UUID()).isEmpty)
    }

    @Test func onlyTheNewestSessionsAreKept() {
        let center = DiagnosticsCenter()
        var ids: [UUID] = []
        for _ in 0..<(DiagnosticsCenter.maximumSessions + 25) {
            let id = UUID()
            ids.append(id)
            center.begin(kind: "live", id: id, cameraID: nil).finish("stopped")
        }
        let kept = center.sessions()
        #expect(kept.count == DiagnosticsCenter.maximumSessions)
        #expect(kept.first?.id == ids[25] && kept.last?.id == ids.last)
    }
}
