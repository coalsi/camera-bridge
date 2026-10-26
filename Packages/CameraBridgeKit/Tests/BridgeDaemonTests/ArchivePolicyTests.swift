import BridgeEngine
import Foundation
import Testing
import TestSupport
@testable import BridgeDaemon

/// The `ArchivePlatformPolicy` the daemon hands the engine: free space from statvfs numbers, the system volume by device number, the
/// Linux floor, folders named by camera ID.
@Suite struct ArchivePolicyTests {
    private let gibibyte: UInt64 = 1_073_741_824
    private let dataDirectory = URL(fileURLWithPath: "/data", isDirectory: true)

    /// A policy over a made-up machine: `devices` maps a path to its device number; every volume is 100 GB with 60 GB free.
    private func policy(devices: [String: UInt64]) -> ArchivePlatformPolicy {
        DaemonArchivePolicy.make(dataDirectory: dataDirectory, deviceOf: { devices[$0.path] },
                                 spaceOf: { _ in (total: 100_000_000_000, free: 60_000_000_000) })
    }

    // MARK: The archive drive

    @Test func twoFoldersAreOnTheSameVolumeByDeviceNumberAndAnUnknownOneCountsAsTheSame() throws {
        let policy = policy(devices: ["/data": 1, "/data/recordings": 1, "/data/archive": 2, "/mnt/other": 2])
        let same = try #require(policy.isSameVolume)
        #expect(!same(URL(fileURLWithPath: "/data/archive"), URL(fileURLWithPath: "/data/recordings")))
        #expect(same(URL(fileURLWithPath: "/data/archive"), URL(fileURLWithPath: "/mnt/other")))
        #expect(same(URL(fileURLWithPath: "/nowhere"), URL(fileURLWithPath: "/data/recordings")), "what cannot be measured is the safe answer")
        #expect(policy.lowerThreadPriority != nil)
    }

    @Test func theThreadIDIsReadFromProcThreadSelf() {
        #expect(DaemonArchivePolicy.threadID(fromThreadSelf: "1234/task/1240") == 1240)
        #expect(DaemonArchivePolicy.threadID(fromThreadSelf: "1234") == nil && DaemonArchivePolicy.threadID(fromThreadSelf: "1234/task/x") == nil)
        #expect(DaemonArchivePolicy.threadID(fromThreadSelf: "1234/task/0") == nil)
    }

    // MARK: Numbers

    @Test func spaceIsBlocksTimesFragmentSizeAndFreeIsWhatAWriterMayUse() {
        let space = DaemonArchivePolicy.space(blocks: 1_000, available: 400, fragmentSize: 4_096)
        #expect(space?.total == 4_096_000)
        #expect(space?.free == 1_638_400)
    }

    @Test func freeNeverExceedsTotal() {
        let space = DaemonArchivePolicy.space(blocks: 1_000, available: 2_000, fragmentSize: 512)
        #expect(space?.total == 512_000 && space?.free == 512_000)
    }

    @Test func numbersThatCannotBeRightAreNil() {
        #expect(DaemonArchivePolicy.space(blocks: 1_000, available: 400, fragmentSize: 0) == nil, "no fragment size")
        #expect(DaemonArchivePolicy.space(blocks: 0, available: 0, fragmentSize: 4_096) == nil, "an empty volume")
        #expect(DaemonArchivePolicy.space(blocks: UInt64.max, available: 1, fragmentSize: 4_096) == nil, "total overflows")
        #expect(DaemonArchivePolicy.space(blocks: 1, available: UInt64.max, fragmentSize: 4_096) == nil, "free overflows")
    }

    // MARK: The real machine

    @Test func aFolderThatDoesNotExistYetIsMeasuredOnItsNearestExistingParent() throws {
        let directory = try TemporaryDirectory(prefix: "cb-policy")
        defer { directory.remove() }
        let missing = directory.url.appending(path: "no/such/recordings", directoryHint: .isDirectory)
        #expect(DaemonArchivePolicy.nearestExistingAncestor(of: missing).path == directory.url.standardizedFileURL.path)
        let here = try #require(DaemonArchivePolicy.volumeSpace(of: directory.url))
        #expect(here.total > 0 && here.free <= here.total)
        let there = try #require(DaemonArchivePolicy.volumeSpace(of: missing))
        #expect(there.total == here.total)
        let device = try #require(DaemonArchivePolicy.deviceNumber(of: directory.url))
        #expect(DaemonArchivePolicy.deviceNumber(of: missing) == device)
    }

    @Test func theRealPolicyOfADataDirectoryCallsItsOwnFolderTheSystemVolume() throws {
        let directory = try TemporaryDirectory(prefix: "cb-policy")
        defer { directory.remove() }
        let policy = DaemonArchivePolicy.make(dataDirectory: directory.url)
        let recordings = directory.url.appending(path: "recordings", directoryHint: .isDirectory)
        #expect(policy.isSystemVolume(recordings))
        #expect(policy.space(recordings)?.total == DaemonArchivePolicy.volumeSpace(of: directory.url)?.total)
        #expect(policy.directoryNaming == .cameraID)
    }

    // MARK: The system volume and the floors (made-up devices)

    @Test func aFolderOnTheDataDirectorysDeviceIsOnTheSystemVolume() {
        let policy = policy(devices: ["/data": 10, "/data/recordings": 10, "/mnt/usb/recordings": 20])
        #expect(policy.isSystemVolume(URL(fileURLWithPath: "/data/recordings", isDirectory: true)))
        #expect(!policy.isSystemVolume(URL(fileURLWithPath: "/mnt/usb/recordings", isDirectory: true)))
    }

    @Test func whatCannotBeMeasuredCountsAsTheSystemVolumeBecauseThatFloorIsTheSafeOne() {
        let known = policy(devices: ["/data": 10])
        #expect(known.isSystemVolume(URL(fileURLWithPath: "/nowhere", isDirectory: true)), "the folder's device is unknown")
        let blind = policy(devices: ["/mnt/usb": 20])
        #expect(blind.isSystemVolume(URL(fileURLWithPath: "/mnt/usb", isDirectory: true)), "the data directory's device is unknown")
    }

    @Test func theFloorIsTheLinuxSystemFloorOnTheDataVolumeAndTwoGiBElsewhere() {
        let policy = policy(devices: ["/data": 10, "/data/recordings": 10, "/mnt/usb/recordings": 20])
        let system = URL(fileURLWithPath: "/data/recordings", isDirectory: true), other = URL(fileURLWithPath: "/mnt/usb/recordings", isDirectory: true)
        #expect(policy.floorBytes(for: system, total: 100_000_000_000) == 8 * gibibyte, "5% of 100 GB is below 8 GiB")
        #expect(policy.floorBytes(for: system, total: 1_000_000_000_000) == 50_000_000_000, "5% of 1 TB")
        #expect(policy.floorBytes(for: system, total: 64 * gibibyte) == 8 * gibibyte, "a small partition still keeps 8 GiB")
        #expect(policy.floorBytes(for: other, total: 4_000_000_000_000) == 2 * gibibyte, "another drive keeps 2 GiB whatever its size")
        #expect(policy.space(system)?.total == 100_000_000_000 && policy.space(system)?.free == 60_000_000_000)
    }
}
