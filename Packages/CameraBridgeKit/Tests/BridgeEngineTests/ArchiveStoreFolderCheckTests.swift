import Dispatch
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// `ArchiveFolderCheck.inspect` and the probe queue it runs on (addendum L5.1): readable sentences, and a hung drive blocks one thread, no more.
@Suite struct ArchiveStoreFolderCheckTests {
    static let gb: UInt64 = 1_000_000_000

    static func policy(total: UInt64 = 500 * gb, free: UInt64? = 200 * gb) -> ArchivePlatformPolicy {
        ArchivePlatformPolicy(space: { _ in free.map { (total: total, free: $0) } }, isSystemVolume: { _ in false }, systemFloor: { $0 }, directoryNaming: .cameraID)
    }

    @Test func aUsableFolderReportsFreeAndTotalAndLeavesNoProbeBehind() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let report = try await ArchiveFolderCheck.inspect(directory.url, policy: Self.policy())
        #expect(report == ArchiveFolderReport(freeBytes: 200 * Self.gb, totalBytes: 500 * Self.gb, floorBytes: ArchiveConstants.otherVolumeFloorBytes), "a drive that is not the system volume has the 2 GiB floor")
        #expect(directory.contents().isEmpty)
        // Without a policy Foundation's volume numbers are used, and so is the Mac's startup rule: a nearly full startup disk is refused with its numbers.
        do {
            let measured = try await ArchiveFolderCheck.inspect(directory.url)
            #expect(measured.totalBytes > 0 && measured.freeBytes >= measured.floorBytes && measured.floorBytes >= ArchiveConstants.minimumFolderFreeBytes)
        } catch ArchiveFolderError.belowFloor(let free, let floor) {
            #expect(free < floor && floor >= ArchiveConstants.minimumFolderFreeBytes, "refused with the numbers that refused it")
        }
    }

    @Test func aFolderBelowTheFloorOfItsVolumeIsRefusedWithBothNumbers() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // The system volume's floor is the host's rule (the box: max(8 GiB, 5%)); here 10%: 50 GB of a 500 GB volume.
        let system = ArchivePlatformPolicy(space: { _ in (total: 500 * Self.gb, free: 40 * Self.gb) }, isSystemVolume: { _ in true }, systemFloor: { $0 / 10 }, directoryNaming: .cameraID)
        await #expect(throws: ArchiveFolderError.belowFloor(freeBytes: 40 * Self.gb, floorBytes: 50 * Self.gb)) { _ = try await ArchiveFolderCheck.inspect(directory.url, policy: system) }
        let roomy = ArchivePlatformPolicy(space: { _ in (total: 500 * Self.gb, free: 60 * Self.gb) }, isSystemVolume: { _ in true }, systemFloor: { $0 / 10 }, directoryNaming: .cameraID)
        let report = try await ArchiveFolderCheck.inspect(directory.url, policy: roomy)
        #expect(report == ArchiveFolderReport(freeBytes: 60 * Self.gb, totalBytes: 500 * Self.gb, floorBytes: 50 * Self.gb))
        // The same volume at the same free space is fine when it is not the system volume: only the 2 GiB floor applies.
        let other = ArchivePlatformPolicy(space: { _ in (total: 500 * Self.gb, free: 40 * Self.gb) }, isSystemVolume: { _ in false }, systemFloor: { $0 / 10 }, directoryNaming: .cameraID)
        #expect(try await ArchiveFolderCheck.inspect(directory.url, policy: other).floorBytes == ArchiveConstants.otherVolumeFloorBytes)
        // The check and the volume monitor use one rule: the floor in the report is the one the monitor pauses at.
        #expect(ArchiveVolume.floor(for: directory.url, total: 500 * Self.gb, policy: roomy, dataDirectory: directory.url) == report.floorBytes)
        // The sentence says what the person has to do (Mac spec 6; the numbers are decimal gigabytes).
        #expect(ArchiveFolderError.belowFloor(freeBytes: 40 * Self.gb, floorBytes: 50 * Self.gb).localizedDescription == "That drive needs 50.0 GB free to record, and has 40.0 GB.")
    }

    @Test func eachProblemHasItsOwnReadableError() async throws {
        let directory = try TemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path(percentEncoded: false))
            directory.remove()
        }
        func inspect(_ url: URL, _ policy: ArchivePlatformPolicy = Self.policy()) async -> ArchiveFolderError? {
            do { _ = try await ArchiveFolderCheck.inspect(url, policy: policy) } catch { return error as? ArchiveFolderError }
            return nil
        }
        #expect(await inspect(directory.file("nothing")) == .notFound)
        try Data("x".utf8).write(to: directory.file("a file"))
        #expect(await inspect(directory.file("a file")) == .notAFolder)
        #expect(await inspect(URL(string: "relative/folder")!) == .invalidPath, "not a file URL")
        #expect(await inspect(URL(fileURLWithPath: "/", isDirectory: true).appending(path: String(repeating: "x", count: 1_100))) == .invalidPath, "over 1,024 bytes")
        let floor = ArchiveConstants.otherVolumeFloorBytes
        #expect(await inspect(directory.url, Self.policy(free: floor - 1)) == .belowFloor(freeBytes: floor - 1, floorBytes: floor))
        #expect(await inspect(directory.url, Self.policy(free: floor)) == nil, "exactly the floor is enough")
        #expect(await inspect(directory.url, Self.policy(free: nil)) == .notAnswering, "a drive that cannot say how much it has")
        for error: ArchiveFolderError in [.notFound, .notAFolder, .invalidPath, .belowFloor(freeBytes: 1, floorBytes: 2), .notAnswering, .cannotWrite] {
            #expect(error.localizedDescription.hasSuffix("."))
        }
        guard ProcessInfo.processInfo.userName != "root" else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.url.path(percentEncoded: false))
        #expect(await inspect(directory.url) == .cannotWrite)
    }

    @Test func aHungDriveGivesUpAfterTheDeadlineAndStacksNoThreads() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let queue = ArchiveProbeQueue()
        let calls = Box(0)
        let gate = DispatchSemaphore(value: 0)
        let hung = ArchivePlatformPolicy(space: { _ in calls.update { $0 += 1 }; gate.wait(); return (total: 500 * Self.gb, free: 200 * Self.gb) },
                                         isSystemVolume: { _ in false }, systemFloor: { $0 }, directoryNaming: .cameraID)
        func inspect() async -> ArchiveFolderError? {
            do { _ = try await ArchiveFolderCheck.inspect(directory.url, policy: hung, dataDirectory: nil, queue: queue, deadline: .milliseconds(200)) } catch { return error as? ArchiveFolderError }
            return nil
        }
        let clock = ContinuousClock()
        var first: ArchiveFolderError?, second: ArchiveFolderError?
        let elapsed = await clock.measure {
            first = await inspect()
            second = await inspect()   // queued behind the hung call: it gives up too, and its work is skipped
        }
        #expect(first == .notAnswering && second == .notAnswering && elapsed < .seconds(20))
        #expect(calls.value == 1, "one blocked thread, however many times the person asked")
        gate.signal()
        let fine = ArchivePlatformPolicy(space: { _ in (total: 500 * Self.gb, free: 200 * Self.gb) }, isSystemVolume: { _ in false }, systemFloor: { $0 }, directoryNaming: .cameraID)
        #expect(try await ArchiveFolderCheck.inspect(directory.url, policy: fine, dataDirectory: nil, queue: queue, deadline: .seconds(5)).freeBytes == 200 * Self.gb, "the queue is free again")
        #expect(calls.value == 1)
    }

    @Test func theProbeQueueRunsOneThingAtATime() async {
        let queue = ArchiveProbeQueue()
        let running = Box(0), peak = Box(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await queue.run {
                        let now = running.update { count -> Int in count += 1; return count }
                        peak.update { $0 = max($0, now) }
                        Thread.sleep(forTimeInterval: 0.002)
                        running.update { $0 -= 1 }
                    }
                }
            }
        }
        #expect(peak.value == 1)
    }

    @Test func inspectedPathsDoNotNeedATrailingSlash() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        #expect(ArchiveVolume.path(of: URL(fileURLWithPath: directory.url.path + "/", isDirectory: true)) == ArchiveVolume.path(of: directory.url))
        #expect(ArchiveVolume.path(of: URL(fileURLWithPath: "/", isDirectory: true)) == "/")
        _ = try await ArchiveFolderCheck.inspect(URL(fileURLWithPath: directory.url.path + "/", isDirectory: true), policy: Self.policy())
    }
}
