import BridgeSupport
import CameraAdapters
import FMP4
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// The store as a recorder sees it: the decision the test sets (`update`) and a record of everything the recorder reported, in order.
final class FakeWriteTarget: ArchiveWriteTarget {
    enum Event: Equatable, Sendable {
        case opened(segment: String, startWallMs: Int64, initLength: UInt32, hasAudio: Bool)
        case wrote(segment: String, record: CBIndexFragmentRecord)
        case closed(segment: String, index: CBIndexFile?)
        case failed(String)
    }

    private struct State {
        var write: ArchiveWriteState
        var events: [Event] = []
    }

    private let state: Mutex<State>

    init(folder: URL?, isReady: Bool = true, pause: ArchivePause? = nil) {
        state = Mutex(State(write: ArchiveWriteState(folder: folder, pause: pause, isReady: isReady, generation: 0)))
    }

    var writeState: ArchiveWriteState { state.withLock { $0.write } }

    func update(_ change: (inout ArchiveWriteState) -> Void) {
        state.withLock { change(&$0.write) }
    }

    var events: [Event] { state.withLock { $0.events } }

    func recorderOpened(_ file: ArchiveOpenFile, startWallMs: Int64, initLength: UInt32, hasAudio: Bool) {
        state.withLock { $0.events.append(.opened(segment: file.segment, startWallMs: startWallMs, initLength: initLength, hasAudio: hasAudio)) }
    }

    func recorderWrote(_ file: ArchiveOpenFile, _ record: CBIndexFragmentRecord) {
        state.withLock { $0.events.append(.wrote(segment: file.segment, record: record)) }
    }

    func recorderClosed(_ file: ArchiveOpenFile, index: CBIndexFile?) {
        state.withLock { $0.events.append(.closed(segment: file.segment, index: index)) }
    }

    func recorderFailed(camera: UUID, _ message: String) {
        state.withLock { $0.events.append(.failed(message)) }
    }

    // MARK: Queries

    /// The files the recorder opened, oldest first (writers run on queues of their own, so the order of their reports is not the order of the files).
    var openedSegments: [String] {
        events.compactMap { event -> (start: Int64, segment: String)? in
            if case .opened(let segment, let start, _, _) = event { (start, segment) } else { nil }
        }.sorted { ($0.start, $0.segment.count, $0.segment) < ($1.start, $1.segment.count, $1.segment) }.map(\.segment)
    }

    func records(of segment: String) -> [CBIndexFragmentRecord] {
        events.compactMap { if case .wrote(let name, let record) = $0, name == segment { record } else { nil } }
    }

    func closedIndex(of segment: String) -> CBIndexFile?? {
        for event in events { if case .closed(let name, let index) = event, name == segment { return .some(index) } }
        return nil
    }

    var closedSegments: [String] {
        events.compactMap { if case .closed(let segment, _) = $0 { segment } else { nil } }
    }

    var failures: [String] {
        events.compactMap { if case .failed(let message) = $0 { message } else { nil } }
    }
}

/// A disk that fails or hangs on command. Writes to files are numbered from 1 across all files (the first write of a recording is its
/// initialization segment, then one per fragment).
final class FaultyFileSystem: RecorderFileSystem, Sendable {
    struct Plan: Sendable {
        /// The write that fails with "no space left on device".
        var failWrite: Int?
        /// The write that blocks its thread until `release()` (a drive that stopped answering).
        var blockWrite: Int?
    }

    private let inner = DiskFileSystem()
    private let state = Mutex((plan: Plan(), writes: 0, syncs: 0))
    private let gate = DispatchSemaphore(value: 0)

    init(_ plan: Plan = Plan()) {
        state.withLock { $0.plan = plan }
    }

    var writes: Int { state.withLock { $0.writes } }

    /// How many times a file was asked to reach the disk (`synchronize`).
    var synchronizations: Int { state.withLock { $0.syncs } }

    /// Lets the blocked write (and every later one) through.
    func release() {
        state.withLock { $0.plan.blockWrite = nil }
        gate.signal()
    }

    fileprivate func countSynchronize() {
        state.withLock { $0.syncs += 1 }
    }

    fileprivate func intercept() throws {
        let (number, plan) = state.withLock { state -> (Int, Plan) in
            state.writes += 1
            return (state.writes, state.plan)
        }
        if plan.blockWrite == number { gate.wait() }
        if plan.failWrite == number { throw CocoaError(.fileWriteOutOfSpace) }
    }

    func directoryExists(_ url: URL) -> Bool { inner.directoryExists(url) }
    func itemExists(_ url: URL) -> Bool { inner.itemExists(url) }
    func names(in directory: URL) throws -> [String] { try inner.names(in: directory) }
    func createDirectory(_ url: URL) throws { try inner.createDirectory(url) }
    func read(_ url: URL, limit: Int) -> Data? { inner.read(url, limit: limit) }
    func write(_ data: Data, to url: URL) throws { try inner.write(data, to: url) }
    func remove(_ url: URL) throws { try inner.remove(url) }

    func createFile(_ url: URL) throws -> any RecorderFileHandle {
        FaultyHandle(inner: try inner.createFile(url), owner: self)
    }
}

private struct FaultyHandle: RecorderFileHandle {
    let inner: any RecorderFileHandle
    let owner: FaultyFileSystem

    func write(_ data: Data) throws {
        try owner.intercept()
        try inner.write(data)
    }

    func synchronize() throws {
        owner.countSynchronize()
        try inner.synchronize()
    }
    func truncate(atOffset offset: UInt64) throws { try inner.truncate(atOffset: offset) }
    func close() throws { try inner.close() }
}

/// The log lines of one camera (the NVR logs through `Log(category: "NVR", cameraID:)`), for tests that check what is written to the log.
final class CameraLogCapture: LogSink, Sendable {
    private let camera: UUID
    private let storage = Box<[String]>([])
    private let token = Box<LogSinkToken?>(nil)

    private init(camera: UUID) {
        self.camera = camera
    }

    static func start(camera: UUID) -> CameraLogCapture {
        let capture = CameraLogCapture(camera: camera)
        capture.token.set(LogHub.addSink(capture))
        return capture
    }

    func record(_ entry: LogEntry) {
        if entry.cameraID == camera { storage.update { $0.append(entry.message) } }
    }

    var lines: [String] { storage.value }

    func stop() {
        if let token = token.value { LogHub.removeSink(token) }
    }
}

/// `array[index]`, or a failed test instead of a crash when a test that should have produced an element did not.
func item<T>(_ array: [T], _ index: Int) throws -> T {
    try #require(array.indices.contains(index) ? array[index] : nil)
}
