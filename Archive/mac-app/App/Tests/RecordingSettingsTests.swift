import BridgeEngine
import CameraAdapters
import Foundation
import Testing

@Suite struct RecordingSettingsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let english = Locale(identifier: "en_US")

    private func storage(used: UInt64 = 0, free: UInt64 = 1_000_000_000_000, total: UInt64 = 2_000_000_000_000, floor: UInt64 = 20 * 1_073_741_824,
                         oldest: TimeInterval? = nil, newest: TimeInterval = 0) -> ArchiveStorageStatus {
        ArchiveStorageStatus(folder: URL(fileURLWithPath: "/Volumes/Recordings"), usedBytes: used, freeBytes: free, totalBytes: total, floorBytes: floor,
                             oldest: oldest.map { now.addingTimeInterval(-$0) }, newest: oldest == nil ? nil : now.addingTimeInterval(-newest))
    }

    private func camera(kilobits: Int?, recording: Bool = true) -> CameraStatus {
        CameraStatus(id: UUID(), name: "Gate", kind: .camera, vendor: .rtsp,
                     mainStreamInfo: kilobits.map { SourceStreamInfo(codec: "h264", width: 2688, height: 1520, fps: 20, bitrateKbps: $0) },
                     nvr: CameraArchiveStatus(state: recording ? .recording : .off))
    }

    @Test func theChoicesAreFixedPlusTheStoredValueWhenItIsNotOneOfThem() {
        #expect(RecordingSettings.choices(RecordingSettings.keepDaysChoices, including: 7) == [1, 3, 7, 14, 30, 90])
        #expect(RecordingSettings.choices(RecordingSettings.keepDaysChoices, including: 10) == [1, 3, 7, 10, 14, 30, 90], "Custom: a value from a hand-edited file shows")
        #expect(RecordingSettings.choices(RecordingSettings.maxSizeChoices, including: 12_000) == RecordingSettings.maxSizeChoices + [12_000])
        #expect(RecordingSettings.keepDaysChoices.allSatisfy { BridgeSettings.nvrKeepDaysRange.contains($0) })
        #expect(RecordingSettings.maxSizeChoices.allSatisfy { BridgeSettings.nvrMaxSizeGBRange.contains($0) })
    }

    @Test func labels() {
        #expect(RecordingSettings.keepLabel(1) == "1 day" && RecordingSettings.keepLabel(14) == "14 days")
        #expect(RecordingSettings.sizeLabel(500) == "500 GB" && RecordingSettings.sizeLabel(1_000) == "1 TB" && RecordingSettings.sizeLabel(4_000) == "4 TB")
        #expect(RecordingSettings.sizeLabel(1_500) == "\(1_500.formatted()) GB", "in the person's own number format")
    }

    @Test func loweringTheSizeDeletesWhatIsOverTheNewLimit() {
        let state = storage(used: 400_000_000_000, oldest: 5 * 86_400, newest: 0)
        #expect(RecordingSettings.bytesToDelete(keepDays: 7, maxSizeGB: 500, storage: state, now: now) == 0, "nothing is over 500 GB, and nothing is older than 7 days")
        #expect(RecordingSettings.bytesToDelete(keepDays: 7, maxSizeGB: 250, storage: state, now: now) == 150_000_000_000)
        #expect(RecordingSettings.deletionWarning(keepDays: 7, maxSizeGB: 250, storage: state, now: now, locale: english) == "This deletes about 150 GB of the oldest recordings. It can’t be undone.")
        #expect(RecordingSettings.deletionWarning(keepDays: 7, maxSizeGB: 500, storage: state, now: now) == nil)
    }

    @Test func loweringTheDaysDeletesTheShareOfFootageOlderThanTheCutoff() {
        let state = storage(used: 400_000_000_000, oldest: 8 * 86_400, newest: 0)   // eight days of footage
        // Keeping 4 days: the older half (by time) goes.
        let bytes = RecordingSettings.bytesToDelete(keepDays: 4, maxSizeGB: 500, storage: state, now: now)
        #expect(abs(Double(bytes) - 200_000_000_000) < 1_000_000, "about half: \(bytes)")
        #expect(RecordingSettings.bytesToDelete(keepDays: 1, maxSizeGB: 500, storage: state, now: now) > bytes)
        #expect(RecordingSettings.bytesToDelete(keepDays: 90, maxSizeGB: 500, storage: state, now: now) == 0)
    }

    @Test func theLargerOfTheTwoRulesIsUsedAndNothingIsEstimatedWithoutNumbers() {
        let state = storage(used: 400_000_000_000, oldest: 8 * 86_400, newest: 0)
        #expect(RecordingSettings.bytesToDelete(keepDays: 4, maxSizeGB: 100, storage: state, now: now) == 300_000_000_000, "size: 300 GB over beats age: 200 GB")
        #expect(RecordingSettings.bytesToDelete(keepDays: 1, maxSizeGB: 500, storage: nil, now: now) == 0)
        #expect(RecordingSettings.bytesToDelete(keepDays: 1, maxSizeGB: 500, storage: storage(used: 0), now: now) == 0)
        // The drive's own room caps the maximum: effective maximum = min(500 GB, total - 2 x floor).
        let small = storage(used: 100_000_000_000, free: 50_000_000_000, total: 150_000_000_000, floor: 20_000_000_000)
        #expect(RecordingSettings.bytesToDelete(keepDays: 90, maxSizeGB: 500, storage: small, now: now) == 0, "100 GB fits in 150 - 40 = 110 GB")
    }

    @Test func theUsageAndDriveLinesAndTheRoomWarning() {
        let state = storage(used: 212_000_000_000, free: 1_200_000_000_000, total: 2_000_000_000_000)
        #expect(RecordingSettings.usageLine(storage: state, maxSizeGB: 500, locale: english) == "Using 212 GB of up to 500 GB.")
        #expect(RecordingSettings.driveLine(storage: state, locale: english) == "1.2 TB free of 2 TB on this drive.")
        #expect(RecordingSettings.roomWarning(storage: state, maxSizeGB: 500, locale: english) == nil, "plenty of room")
        let tight = storage(used: 40_000_000_000, free: 70_000_000_000, total: 128_000_000_000, floor: 20_000_000_000)
        // room = used + (free - floor) = 40 + 50 = 90 GB, below the chosen 500 GB.
        #expect(RecordingSettings.roomWarning(storage: tight, maxSizeGB: 500, locale: english)?.contains("room for about 90 GB") == true)
        #expect(RecordingSettings.roomWarning(storage: tight, maxSizeGB: 50, locale: english) == nil, "the limit is the smaller one")
        #expect(RecordingSettings.usageLine(storage: nil, maxSizeGB: 500) == nil && RecordingSettings.driveLine(storage: nil) == nil)
        #expect(RecordingSettings.usageLine(storage: tight, maxSizeGB: 500, locale: english) == "Using 40 GB of up to 88 GB.", "the effective maximum: total - 2 x floor")
    }

    @Test func theDaysAreHonestAboutTheRateNotAPromise() {
        // Measured: 86.4 GB over two days is 43.2 GB a day.
        let measured = storage(used: 86_400_000_000, oldest: 2 * 86_400, newest: 0)
        #expect(abs((RecordingSettings.gigabytesPerDay(storage: measured, cameras: []) ?? 0) - 43.2) < 0.01)
        // Not enough stored yet (under an hour): the cameras' bit rates, 4 Mbps x 10.8.
        let young = storage(used: 1_000_000, oldest: 600, newest: 0)
        #expect(abs((RecordingSettings.gigabytesPerDay(storage: young, cameras: [camera(kilobits: 4_000)]) ?? 0) - 43.2) < 0.01)
        #expect(abs((RecordingSettings.gigabytesPerDay(storage: nil, cameras: [camera(kilobits: 4_000), camera(kilobits: 2_000), camera(kilobits: 8_000, recording: false)]) ?? 0) - 64.8) < 0.01,
                "only the cameras that record count")
        #expect(RecordingSettings.gigabytesPerDay(storage: nil, cameras: [camera(kilobits: nil)]) == nil)
        let line = RecordingSettings.holdsLine(storage: nil, cameras: [camera(kilobits: 4_000)], maxSizeGB: 500, locale: english)
        #expect(line == "The cameras recording now write about 43 GB a day, so this much holds about 12 days.", "500 / 43.2 = 11.6")
        #expect(RecordingSettings.holdsLine(storage: nil, cameras: [], maxSizeGB: 500) == nil)
    }

    @Test func keepMacAwakeIsSuggestedOnlyWhileACameraRecordsAndItIsOff() {
        #expect(RecordingSettings.suggestsKeepAwake(anyCameraRecording: true, keepsAwake: false))
        #expect(!RecordingSettings.suggestsKeepAwake(anyCameraRecording: true, keepsAwake: true))
        #expect(!RecordingSettings.suggestsKeepAwake(anyCameraRecording: false, keepsAwake: false))
    }
}
