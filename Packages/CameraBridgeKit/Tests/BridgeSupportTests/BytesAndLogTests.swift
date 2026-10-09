import Foundation
import Synchronization
import Testing
@testable import BridgeSupport

@Suite struct HexTests {
    @Test func roundTrip() {
        let data = Data([0x00, 0x01, 0xAB, 0xFF])
        #expect(data.hexString == "0001abff")
        #expect(Data(hex: "0001ABff") == data)
        #expect(Data(hex: "00 01 ab\nff") == data)
        #expect(Data(hex: "") == Data())
    }

    @Test func rejectsInvalidHex() {
        #expect(Data(hex: "abc") == nil)
        #expect(Data(hex: "zz") == nil)
        #expect(Data(hex: "0x00") == nil)
    }
}

@Suite struct ByteReaderWriterTests {
    @Test func roundTripsEveryWidth() throws {
        var w = ByteWriter()
        w.write(UInt8(0xAB))
        w.writeUInt16BE(0x1234); w.writeUInt16LE(0x1234)
        w.writeUInt24BE(0x0A0B0C)
        w.writeUInt32BE(0xDEADBEEF); w.writeUInt32LE(0xDEADBEEF)
        w.writeUInt64BE(0x0102030405060708); w.writeUInt64LE(0x0102030405060708)
        w.write(Data([9, 9]))
        #expect(w.data.hexString == "ab" + "1234" + "3412" + "0a0b0c" + "deadbeef" + "efbeadde"
                + "0102030405060708" + "0807060504030201" + "0909")

        var r = ByteReader(w.data)
        #expect(r.remaining == w.data.count)
        #expect(try r.readUInt8() == 0xAB)
        #expect(try r.readUInt16BE() == 0x1234)
        #expect(try r.readUInt16LE() == 0x1234)
        #expect(try r.readUInt24BE() == 0x0A0B0C)
        #expect(try r.readUInt32BE() == 0xDEADBEEF)
        #expect(try r.readUInt32LE() == 0xDEADBEEF)
        #expect(try r.readUInt64BE() == 0x0102030405060708)
        #expect(try r.readUInt64LE() == 0x0102030405060708)
        #expect(try r.readBytes(2) == Data([9, 9]))
        #expect(r.isAtEnd)
    }

    @Test func truncationThrows() throws {
        var r = ByteReader(Data([1, 2]))
        #expect(throws: ByteError.truncated(needed: 4, available: 2)) { try r.readUInt32BE() }
        // A failed read does not consume anything.
        #expect(try r.readUInt16BE() == 0x0102)
        #expect(throws: ByteError.truncated(needed: 1, available: 0)) { try r.skip(1) }
    }

    @Test func worksOnSlicesWithNonZeroStartIndex() throws {
        let backing = Data([0xFF, 0xFF, 0x00, 0x2A, 0x10])
        let slice = backing[2...]
        var r = ByteReader(slice)
        #expect(try r.readUInt16BE() == 0x002A)
        try r.skip(1)
        #expect(r.isAtEnd)
        let bytes = try ByteReader(slice).readBytesCopy(3)
        #expect(bytes.startIndex == 0)
    }
}

private extension ByteReader {
    func readBytesCopy(_ n: Int) throws -> Data { var copy = self; return try copy.readBytes(n) }
}

private final class CollectingSink: LogSink {
    let entries = Mutex<[LogEntry]>([])
    func record(_ entry: LogEntry) { entries.withLock { $0.append(entry) } }
}

/// These tests never change process-wide logging state that other tests rely on: level filtering is tested on a
/// private `LogRouter`, and the global `LogHub` only gains a sink that is removed again by its token.
@Suite struct LogHubTests {
    @Test func sinksReceiveEntriesAtOrAboveMinimumLevel() {
        let router = LogRouter()
        let sink = CollectingSink()
        router.addSink(sink)
        router.minimumLevel = .notice
        let camera = UUID()
        let log = Log(category: "test", cameraID: camera, router: router)
        log.debug("dbg"); log.info("inf"); log.notice("note"); log.warning("warn"); log.error("err")
        let entries = sink.entries.withLock { $0 }
        #expect(entries.map(\.message) == ["note", "warn", "err"])
        #expect(entries.map(\.level) == [.notice, .warning, .error])
        #expect(entries.allSatisfy { $0.cameraID == camera && $0.category == "test" })
    }

    @Test func autoclosureNotEvaluatedBelowMinimum() {
        let router = LogRouter()
        router.minimumLevel = .error
        let evaluated = Mutex(false)
        func expensive() -> String { evaluated.withLock { $0 = true }; return "x" }
        Log(category: "test", router: router).info(expensive())
        #expect(evaluated.withLock { $0 } == false)
    }

    @Test func routerDefaultsToInfo() {
        #expect(LogRouter().minimumLevel == .info)
    }

    @Test func removeSinkByTokenStopsDeliveryToThatSinkOnly() {
        let router = LogRouter()
        let first = CollectingSink(), second = CollectingSink()
        let firstToken = router.addSink(first)
        let secondToken = router.addSink(second)
        #expect(firstToken != secondToken)
        let log = Log(category: "test", router: router)
        log.warning("both")
        router.removeSink(firstToken)
        router.removeSink(firstToken)   // removing twice is harmless
        log.warning("second only")
        #expect(first.entries.withLock { $0.map(\.message) } == ["both"])
        #expect(second.entries.withLock { $0.map(\.message) } == ["both", "second only"])
        router.removeAllSinks()
        log.warning("nobody")
        #expect(second.entries.withLock { $0.count } == 2)
    }

    /// The public `LogHub` API on the shared router. Error-level entries pass any minimum level, and the sink is
    /// removed by its token, so concurrently running tests are unaffected.
    @Test func globalHubDeliversToRegisteredSinkUntilRemoved() {
        let sink = CollectingSink()
        let category = "test.\(UUID().uuidString)"
        let token = LogHub.addSink(sink)
        Log(category: category).error("registered")
        LogHub.removeSink(token)
        Log(category: category).error("removed")
        let mine = sink.entries.withLock { $0.filter { $0.category == category } }
        #expect(mine.map(\.message) == ["registered"])
    }

    @Test func levelsAreOrdered() {
        #expect(LogLevel.debug < .info && LogLevel.info < .notice && LogLevel.notice < .warning && LogLevel.warning < .error)
        #expect(LogLevel.allCases.count == 5)
    }
}
