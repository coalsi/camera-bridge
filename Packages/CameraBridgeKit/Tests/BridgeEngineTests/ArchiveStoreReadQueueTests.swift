import Dispatch
import Foundation
import TestSupport
import Testing
@testable import BridgeEngine

/// The read side's building blocks (Mac spec 7): the 6-wide queue with its deadline, the 16 open handles, the 64 MB cache.
@Suite struct ArchiveStoreReadQueueTests {
    @Test func runsAtMostWidthReadsAtOnceAndAllOfThem() async throws {
        let queue = ArchiveReadQueue(width: 3, deadline: .seconds(30))
        let running = Box(0), peak = Box(0)
        let gate = DispatchSemaphore(value: 0)
        let results = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for number in 0..<10 {
                group.addTask {
                    try await queue.run {
                        let now = running.update { count -> Int in count += 1; return count }
                        peak.update { $0 = max($0, now) }
                        gate.wait()
                        running.update { $0 -= 1 }
                        return number
                    }
                }
            }
            #expect(await eventually(timeout: archiveStorePatience) { running.value == 3 && queue.load.waiting == 7 }, "three run, seven wait: \(queue.load)")
            for _ in 0..<10 { gate.signal() }
            var all: [Int] = []
            for try await result in group { all.append(result) }
            return all
        }
        #expect(results.sorted() == Array(0..<10) && peak.value == 3)
        #expect(await eventually(timeout: archiveStorePatience) { queue.load.running == 0 && queue.load.waiting == 0 }, "the slots are free again")
    }

    @Test func aReadThatOverrunsItsDeadlineTimesOutAndHoldsItsSlotUntilItReturns() async throws {
        let queue = ArchiveReadQueue(width: 1, deadline: .milliseconds(200))
        let gate = DispatchSemaphore(value: 0)
        let secondRan = Box(false)
        let stuck = Task { try await queue.run { gate.wait(); return 1 } }
        #expect(await eventually(timeout: archiveStorePatience) { queue.load.running == 1 })
        let waiting = Task { try await queue.run { secondRan.set(true); return 2 } }
        await #expect(throws: ArchiveError.timedOut) { try await stuck.value }
        await #expect(throws: ArchiveError.timedOut) { try await waiting.value }
        #expect(!secondRan.value, "a read that gave up while waiting for the slot never runs")
        #expect(queue.load.running == 1 && queue.load.waiting == 0, "the stuck read still occupies its slot, and nothing waits behind it")
        gate.signal()
        #expect(await eventually(timeout: archiveStorePatience) { queue.load.running == 0 })
        // Under a full parallel test run a worker thread can take longer than the 200 ms deadline to start: the read is tried until it gets one.
        #expect(await eventually(timeout: archiveStorePatience) { (try? await queue.run { 3 }) == 3 }, "the queue works again once the stuck read returns")
    }

    @Test func errorsOfTheWorkPassThrough() async {
        struct Boom: Error, Equatable {}
        let queue = ArchiveReadQueue(width: 2, deadline: .seconds(5))
        await #expect(throws: Boom.self) { try await queue.run { throw Boom() } as Int }
        #expect(await eventually(timeout: archiveStorePatience) { queue.load.running == 0 })
    }

    // MARK: Handles

    /// A file of 1,000 bytes whose byte at position `i` is `i % 251`.
    static func file(in directory: TemporaryDirectory, _ name: String) throws -> URL {
        let url = directory.file(name)
        try Data((0..<1_000).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    @Test func handlesReadAtOffsetsAndStayOpenAfterTheFileIsUnlinked() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = try Self.file(in: directory, "a.mp4")
        let cache = ArchiveHandleCache(capacity: 4)
        #expect(try cache.read(segment: "a", url: url, offset: 10, count: 5) == Data([10, 11, 12, 13, 14]))
        #expect(try cache.read(segment: "a", url: url, offset: 995, count: 20) == Data((995..<1_000).map { UInt8($0 % 251) }), "shorter at the end of the file")
        #expect(cache.openCount == 1 && cache.isOpen("a"))
        try FileManager.default.removeItem(at: url)
        #expect(try cache.read(segment: "a", url: url, offset: 250, count: 3) == Data([250, 0, 1]), "an unlinked file is readable through the open handle")
        cache.closeAll()
        #expect(cache.openCount == 0)
        #expect(throws: (any Error).self) { try cache.read(segment: "a", url: url, offset: 0, count: 1) }
        #expect(ArchiveErrors.map(CocoaError(.fileReadNoSuchFile)) == .fileGone)
        do { _ = try cache.read(segment: "a", url: url, offset: 0, count: 1) } catch { #expect(ArchiveErrors.map(error) == .fileGone, "a later open finds nothing") }
    }

    /// T13 (real unmount): a handle opened before the drive went away is useless after it comes back. It reads nothing, the store took that for a fragment that is
    /// not where its index says, quarantined the file, and every later read of it failed until the daemon was restarted. The same path, asked through a new handle,
    /// reads fine, so the stale handle is replaced instead.
    @Test func aHandleThatWentStaleIsReplacedByAFreshOneInsteadOfReadingNothing() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("a.mp4")
        try Data((0..<100).map { UInt8($0) }).write(to: url)
        let cache = ArchiveHandleCache(capacity: 4)
        #expect(try cache.read(segment: "a", url: url, offset: 0, count: 10).count == 10, "opens the handle and keeps it")
        // The path holds the file again after the drive returned, but the cached handle is on the old inode, which ends at 100 bytes (a stale handle sees no more).
        try FileManager.default.removeItem(at: url)
        try Data((0..<300).map { UInt8($0 % 251) }).write(to: url)
        let data = try cache.read(segment: "a", url: url, offset: 200, count: 50)
        #expect(data == Data((200..<250).map { UInt8($0 % 251) }), "the short read through the cached handle is asked again through a new one")
        #expect(!cache.isOpen("a"), "the stale handle is gone")
        #expect(try cache.read(segment: "a", url: url, offset: 150, count: 50) == Data((150..<200).map { UInt8($0) }), "the next read opens the file again")
        #expect(cache.openCount == 1 && cache.isOpen("a"), "and keeps that handle")
        // A short read at the real end of a file stays short, and an unlinked file still reads through its open handle.
        #expect(try cache.read(segment: "a", url: url, offset: 295, count: 20) == Data((295..<300).map { UInt8($0 % 251) }))
        try FileManager.default.removeItem(at: url)
        #expect(try cache.read(segment: "a", url: url, offset: 295, count: 20) == Data((295..<300).map { UInt8($0 % 251) }), "short at the end, the file unlinked: what the open handle has")
    }

    @Test func atMostCapacityHandlesStayOpenLeastRecentlyUsedClosedFirst() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let cache = ArchiveHandleCache(capacity: 2)
        let urls = try ["a", "b", "c"].map { try Self.file(in: directory, $0 + ".mp4") }
        _ = try cache.read(segment: "a", url: urls[0], offset: 0, count: 1)
        _ = try cache.read(segment: "b", url: urls[1], offset: 0, count: 1)
        _ = try cache.read(segment: "a", url: urls[0], offset: 0, count: 1)   // a is the most recent now
        _ = try cache.read(segment: "c", url: urls[2], offset: 0, count: 1)
        #expect(cache.openCount == 2 && cache.isOpen("a") && cache.isOpen("c") && !cache.isOpen("b"))
        #expect(try cache.read(segment: "b", url: urls[1], offset: 3, count: 2) == Data([3, 4]), "an evicted file is simply opened again")
        #expect(cache.openCount == 2)
    }

    @Test func aRetiredHandleClosesOnceItsGraceHasPassed() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = try Self.file(in: directory, "a.mp4")
        let cache = ArchiveHandleCache(capacity: 4)
        _ = try cache.read(segment: "a", url: url, offset: 0, count: 1)
        cache.retire("a")
        cache.sweep(grace: .seconds(60))
        #expect(cache.isOpen("a"), "a reader in the middle of the file is not cut off")
        cache.sweep(grace: .zero)
        #expect(!cache.isOpen("a") && cache.openCount == 0)
        cache.retire("never-opened")
        cache.sweep(grace: .zero)
    }

    @Test func readsOnSharedHandlesNeverMixUpTheirPositions() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let urls = try ["a", "b", "c"].map { try Self.file(in: directory, $0 + ".mp4") }
        let cache = ArchiveHandleCache(capacity: 2)   // smaller than the files in use: evictions happen in the middle of reads
        let wrong = try await withThrowingTaskGroup(of: Int.self) { group -> Int in
            for worker in 0..<8 {
                group.addTask {
                    var wrong = 0
                    for round in 0..<300 {
                        let file = (worker + round) % 3
                        let offset = (worker * 37 + round * 11) % 900
                        let data = try cache.read(segment: "file\(file)", url: urls[file], offset: UInt64(offset), count: 50)
                        if data != Data((offset..<offset + 50).map { UInt8($0 % 251) }) { wrong += 1 }
                    }
                    return wrong
                }
            }
            var total = 0
            for try await count in group { total += count }
            return total
        }
        #expect(wrong == 0)
        #expect(cache.openCount <= 2)
    }

    // MARK: Cached bytes

    @Test func theBlockCacheKeepsTheMostRecentBytesWithinItsCapacity() {
        var cache = ArchiveBlockCache(capacity: 100)
        func key(_ number: UInt64) -> ArchiveBlockCache.Key { ArchiveBlockCache.Key(segment: "s", offset: number, length: 40) }
        cache.insert(Data(repeating: 1, count: 40), for: key(1))
        cache.insert(Data(repeating: 2, count: 40), for: key(2))
        #expect(cache.data(for: key(1)) != nil, "touching 1 makes 2 the oldest")
        cache.insert(Data(repeating: 3, count: 40), for: key(3))
        #expect(cache.bytes == 80 && cache.data(for: key(2)) == nil && cache.data(for: key(1)) != nil && cache.data(for: key(3)) != nil)
        cache.insert(Data(repeating: 4, count: 101), for: key(4))
        #expect(cache.data(for: key(4)) == nil && cache.bytes == 80, "bigger than the whole cache: not kept, and nothing else is thrown out")
        cache.insert(Data(repeating: 5, count: 10), for: key(1))   // replaces
        #expect(cache.bytes == 50 && cache.data(for: key(1))?.count == 10)
        cache.remove(segment: "s")
        #expect(cache.count == 0 && cache.bytes == 0)
    }

    @Test func theBlockCacheForgetsOneFileWithoutTheOthers() {
        var cache = ArchiveBlockCache(capacity: 1_000)
        cache.insert(Data(count: 10), for: ArchiveBlockCache.Key(segment: "a", offset: 0, length: 10))
        cache.insert(Data(count: 10), for: ArchiveBlockCache.Key(segment: "a", offset: 10, length: 10))
        cache.insert(Data(count: 10), for: ArchiveBlockCache.Key(segment: "b", offset: 0, length: 10))
        cache.remove(segment: "a")
        #expect(cache.count == 1 && cache.bytes == 10 && cache.data(for: ArchiveBlockCache.Key(segment: "b", offset: 0, length: 10)) != nil)
    }

    @Test func fileErrorsBecomeArchiveErrorsWithoutNamingAFile() {
        #expect(ArchiveErrors.map(CocoaError(.fileNoSuchFile)) == .fileGone)
        #expect(ArchiveErrors.map(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOENT.rawValue))) == .fileGone)
        #expect(ArchiveErrors.map(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTDIR.rawValue))) == .fileGone)
        #expect(ArchiveErrors.map(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EIO.rawValue))) == .unreadable("The recordings drive reported an error."))
        #expect(ArchiveErrors.map(ArchiveError.timedOut) == .timedOut)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 4_000, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOENT.rawValue))])
        #expect(ArchiveErrors.map(wrapped) == .fileGone)
        let described = ArchiveErrors.brief(CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/Volumes/Secret/camera/x.mp4"]))
        #expect(described == "error 257" && !described.contains("Secret"))
    }
}
