import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// What the drive's numbers mean for recording (Mac spec 6, addendum L5.1): the pause, its hysteresis, and how the drive is measured.
@Suite struct VolumeMonitorTests {
    static let gib = ArchiveConstants.resumeMarginBytes
    static let folder = URL(fileURLWithPath: "/media/recordings", isDirectory: true)

    static func measurement(exists: Bool = true, total: UInt64 = 500 * gib, free: UInt64? = 100 * gib, floor: UInt64 = 8 * gib, problem: String? = nil) -> VolumeMonitor.Measurement {
        VolumeMonitor.Measurement(folderExists: exists, space: free.map { VolumeMonitor.Space(total: total, free: $0) }, floorBytes: floor, writeProblem: problem)
    }

    static func decide(previous: ArchivePause? = nil, folder: URL? = VolumeMonitorTests.folder, _ measurement: VolumeMonitor.Measurement?, stalled: Bool = false) -> ArchivePause? {
        VolumeMonitor.decide(previous: previous, folder: folder, measurement: measurement, stalled: stalled)
    }

    @Test func recordsWhileThereIsRoomAndTheFolderWorks() {
        #expect(Self.decide(Self.measurement()) == nil)
        #expect(Self.decide(Self.measurement(free: 8 * Self.gib)) == nil, "exactly at the floor is still room")
    }

    @Test func noFolderIsAPauseWhateverTheDriveSays() {
        #expect(Self.decide(folder: nil, nil) == .noFolder)
        #expect(Self.decide(folder: nil, Self.measurement()) == .noFolder)
        #expect(Self.decide(folder: nil, nil, stalled: true) == .noFolder)
    }

    @Test func aDriveThatDoesNotAnswerPausesWithItsOwnSentence() {
        #expect(Self.decide(Self.measurement(), stalled: true) == .notWritable("The drive isn’t answering."))
        #expect(Self.decide(nil, stalled: true) == .notWritable(VolumeMonitor.notAnswering))
        #expect(VolumeMonitor.notAnswering == ArchiveFolderError.notAnswering.errorDescription)
    }

    @Test func nothingMeasuredYetChangesNothing() {
        #expect(Self.decide(previous: nil, nil) == nil)
        #expect(Self.decide(previous: .diskFull, nil) == .diskFull)
        #expect(Self.decide(previous: .folderMissing, nil) == .folderMissing)
    }

    @Test func aMissingFolderOrUnreadableSpaceOrRefusedWriteEachPause() {
        #expect(Self.decide(Self.measurement(exists: false, free: nil)) == .folderMissing)
        #expect(Self.decide(Self.measurement(free: nil)) == .notWritable(VolumeMonitor.spaceUnreadable))
        #expect(Self.decide(Self.measurement(problem: "Camera Bridge can’t write to that folder.")) == .notWritable("Camera Bridge can’t write to that folder."))
        #expect(Self.decide(previous: .notWritable("x"), Self.measurement()) == nil, "a write that works again resumes")
    }

    @Test func belowTheFloorPausesAndResumesOneGibiByteAbove() {
        let floor = 8 * Self.gib
        #expect(Self.decide(Self.measurement(free: floor - 1)) == .diskFull)
        // A drive that was full is trusted again only 1 GiB above the floor.
        #expect(Self.decide(previous: .diskFull, Self.measurement(free: floor)) == .diskFull)
        #expect(Self.decide(previous: .diskFull, Self.measurement(free: floor + Self.gib - 1)) == .diskFull)
        #expect(Self.decide(previous: .diskFull, Self.measurement(free: floor + Self.gib)) == nil)
        // A drive that was fine is not paused by being near the floor.
        #expect(Self.decide(previous: nil, Self.measurement(free: floor + 1)) == nil)
        // It flaps no more than 1 GiB: a sequence of readings around the floor.
        var pause: ArchivePause?
        var changes = 0
        for free in [20, 9, 8, 7, 7, 8, 8.5, 9, 9.2, 8.9, 7.9, 9.1].map({ UInt64($0 * Double(Self.gib)) }) {
            let next = Self.decide(previous: pause, Self.measurement(free: free))
            if next != pause { changes += 1 }
            pause = next
        }
        #expect(changes == 4, "pause at 7, resume at 9, pause at 7.9, resume at 9.1")
    }

    @Test func aFolderThatReturnsResumesAtOnceUnlessTheDriveIsFull() {
        let floor = 8 * Self.gib
        #expect(Self.decide(previous: .folderMissing, Self.measurement(free: floor + 1)) == nil, "no 1 GiB margin for a returning folder")
        #expect(Self.decide(previous: .folderMissing, Self.measurement(free: floor - 1)) == .diskFull)
    }

    @Test func usedAndFreeAreRoundedDownToTenMegabytes() {
        #expect(VolumeMonitor.rounded(12_345_678) == 10_000_000 && VolumeMonitor.rounded(9_999_999) == 0 && VolumeMonitor.rounded(30_000_000) == 30_000_000)
    }

    // MARK: Measuring

    @Test func measuresAFolderThroughThePlatformPolicy() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let asked = Box<[URL]>([])
        let policy = ArchivePlatformPolicy(space: { url in asked.update { $0.append(url) }; return (total: 128 * 1_000_000_000, free: 60 * 1_000_000_000) },
                                           isSystemVolume: { _ in true }, systemFloor: ArchivePlatformPolicy.linuxSystemFloor, directoryNaming: .cameraID)
        let measured = VolumeMonitor.measure(folder: directory.url, policy: policy, dataDirectory: directory.url, writeTest: false)
        #expect(measured.folderExists && measured.writeProblem == nil)
        #expect(measured.space == VolumeMonitor.Space(total: 128_000_000_000, free: 60_000_000_000))
        #expect(measured.floorBytes == 8 * Self.gib, "max(8 GiB, 5%) on the system volume: 5% of 128 GB is 6.4 GB")
        #expect(asked.value.count == 1)
        let other = ArchivePlatformPolicy(space: policy.space, isSystemVolume: { _ in false }, systemFloor: policy.systemFloor, directoryNaming: .cameraID)
        #expect(VolumeMonitor.measure(folder: directory.url, policy: other, dataDirectory: directory.url, writeTest: false).floorBytes == ArchiveConstants.otherVolumeFloorBytes)
    }

    @Test func aMissingFolderOrAFileInsteadOfOneIsNotThere() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let policy = ArchivePlatformPolicy(space: { _ in (total: 1, free: 1) }, isSystemVolume: { _ in true }, systemFloor: { $0 }, directoryNaming: .cameraID)
        let missing = VolumeMonitor.measure(folder: directory.file("nothing"), policy: policy, dataDirectory: directory.url, writeTest: true)
        #expect(!missing.folderExists && missing.space == nil && missing.writeProblem == nil)
        try Data("x".utf8).write(to: directory.file("file"))
        #expect(!VolumeMonitor.measure(folder: directory.file("file"), policy: policy, dataDirectory: directory.url, writeTest: false).folderExists)
    }

    @Test func withoutAPolicyTheDriveIsMeasuredThroughFoundation() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let measured = VolumeMonitor.measure(folder: directory.url, policy: nil, dataDirectory: directory.url, writeTest: false)
        let space = try #require(measured.space, "the volume attributes of a temporary folder")
        #expect(space.total > 0 && space.free <= space.total)
        #expect(measured.floorBytes == ArchivePlatformPolicy.macStartupFloor(total: space.total), "the data directory's volume is the startup volume")
        #expect(ArchiveVolume.sameVolume(directory.url, directory.url))
    }

    @Test func theWriteTestLeavesNothingBehindAndSeesAFolderThatRefusesFiles() throws {
        let directory = try TemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path(percentEncoded: false))
            directory.remove()
        }
        let policy = ArchivePlatformPolicy(space: { _ in (total: 100, free: 100) }, isSystemVolume: { _ in false }, systemFloor: { $0 }, directoryNaming: .cameraID)
        #expect(VolumeMonitor.measure(folder: directory.url, policy: policy, dataDirectory: directory.url, writeTest: true).writeProblem == nil)
        #expect(directory.contents().isEmpty, "the probe file is deleted")
        guard ProcessInfo.processInfo.userName != "root" else { return }   // root writes anywhere
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.url.path(percentEncoded: false))
        let refused = VolumeMonitor.measure(folder: directory.url, policy: policy, dataDirectory: directory.url, writeTest: true)
        #expect(refused.writeProblem == "Camera Bridge can’t write to that folder.")
        #expect(VolumeMonitor.measure(folder: directory.url, policy: policy, dataDirectory: directory.url, writeTest: false).writeProblem == nil, "not tested, not reported")
    }
}
