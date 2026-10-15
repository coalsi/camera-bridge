import Foundation
import Testing
@testable import BridgeEngine

@Suite struct ArchiveStatusTests {
    @Test func pausesHaveStableCodesAndReadableSentences() {
        #expect(ArchivePause.noFolder.code == "noFolder" && ArchivePause.folderMissing.code == "folderMissing")
        #expect(ArchivePause.diskFull.code == "diskFull" && ArchivePause.notWritable("x").code == "notWritable")
        #expect(ArchivePause.noFolder.readable == "Choose where to store recordings.")
        #expect(ArchivePause.notWritable("The drive isn’t answering.").readable == "The drive isn’t answering.")
        for pause in [ArchivePause.noFolder, .folderMissing, .diskFull] { #expect(pause.readable.hasSuffix("."), "\(pause.code)") }
    }

    @Test func cameraStatusDetail() {
        #expect(CameraArchiveStatus().state == .off && CameraArchiveStatus().detail == nil && CameraArchiveStatus().notes.isEmpty)
        #expect(CameraArchiveStatus(state: .recording).detail == nil)
        #expect(CameraArchiveStatus(state: .waiting("waiting for the camera")).detail == "waiting for the camera")
        #expect(CameraArchiveStatus(state: .paused(.diskFull)).detail == ArchivePause.diskFull.readable)
        #expect(CameraArchiveStatus(state: .recording, notes: [ArchiveNote(id: .sound, text: "sound could not be recorded")])
            != CameraArchiveStatus(state: .recording))
    }

    @Test func storageNumbers() {
        let gb = ArchiveConstants.gigabyte
        let status = ArchiveStorageStatus(usedBytes: 100 * gb, freeBytes: 40 * gb, totalBytes: 500 * gb, floorBytes: 25 * gb)
        #expect(status.spareBytes == 15 * gb && status.roomBytes == 115 * gb)
        #expect(ArchiveStorageStatus(freeBytes: 10 * gb, floorBytes: 25 * gb).spareBytes == 0, "below the floor: nothing spare, never negative")
        #expect(status.effectiveMaximumBytes(maxSizeGB: 500) == 450 * gb, "total - 2 x floor binds")
        #expect(status.effectiveMaximumBytes(maxSizeGB: 100) == 100 * gb, "the chosen size binds")
        #expect(ArchiveStorageStatus(totalBytes: 10 * gb, floorBytes: 8 * gb).effectiveMaximumBytes(maxSizeGB: 500) == 0, "a drive smaller than two floors holds nothing")
    }

    @Test func floors() {
        let gib: UInt64 = 1_073_741_824
        #expect(ArchivePlatformPolicy.macStartupFloor(total: 500_000_000_000) == 50_000_000_000, "10% of a 500 GB volume")
        #expect(ArchivePlatformPolicy.macStartupFloor(total: 100_000_000_000) == 20 * gib, "20 GiB at least")
        #expect(ArchivePlatformPolicy.macStartupFloor(total: 994_662_584_320) == 50 * gib, "this Mac's 926 GiB startup volume: capped at 50 GiB, not 93 GB")
        #expect(ArchivePlatformPolicy.macStartupFloor(total: 4_000_000_000_000) == 50 * gib, "a 4 TB drive does not keep 400 GB")
        #expect(ArchivePlatformPolicy.macStartupFloor(total: 536_870_912_000) == 50 * gib, "10% of 500 GiB is exactly the cap")
        #expect(ArchivePlatformPolicy.linuxSystemFloor(total: 128_000_000_000) == 8 * gib, "8 GiB at least")
        #expect(ArchivePlatformPolicy.linuxSystemFloor(total: 2_000_000_000_000) == 100_000_000_000, "5% of 2 TB")
        let policy = ArchivePlatformPolicy(space: { _ in (total: 1, free: 1) }, isSystemVolume: { $0.path.hasPrefix("/srv") },
                                           systemFloor: { ArchivePlatformPolicy.linuxSystemFloor(total: $0) }, directoryNaming: .cameraID)
        #expect(policy.floorBytes(for: URL(filePath: "/srv/recordings"), total: 128_000_000_000) == 8 * gib)
        #expect(policy.floorBytes(for: URL(filePath: "/media/usb"), total: 128_000_000_000) == ArchiveConstants.otherVolumeFloorBytes)
    }

    @Test func folderErrorsAreSentences() {
        let all: [ArchiveFolderError] = [.invalidPath, .notFound, .notAFolder, .cannotWrite, .belowFloor(freeBytes: 5, floorBytes: 8), .notAnswering]
        for error in all { #expect(error.localizedDescription.hasSuffix("."), "\(error)") }
        #expect(ArchiveFolderError.belowFloor(freeBytes: 81_000_000_000, floorBytes: 99_400_000_000).localizedDescription == "That drive needs 99.4 GB free to record, and has 81.0 GB.")
        #expect(ArchiveFolderError.belowFloor(freeBytes: 0, floorBytes: 8_589_934_592).localizedDescription == "That drive needs 8.6 GB free to record, and has 0.0 GB.")
        #expect(ArchiveFolderReport(freeBytes: 1, totalBytes: 2) == ArchiveFolderReport(freeBytes: 1, totalBytes: 2, floorBytes: 0), "the floor defaults to unknown")
    }
}
