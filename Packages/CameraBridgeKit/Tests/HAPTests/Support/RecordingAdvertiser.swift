import BridgeSupport
import Foundation
import Synchronization

/// `ServiceAdvertiser` fake that records every advertisement and TXT update (never touches DNS-SD, so nothing is
/// announced on the LAN). `failNextAdvertise` makes `advertise` throw (queued: one error per call); `service.fail(_:)`
/// reports a later failure.
final class RecordingAdvertiser: ServiceAdvertiser {
    struct Record: Sendable, Equatable {
        var advertisement: ServiceAdvertisement
        var txtUpdates: [[String: String]]
        var cancelled: Bool
    }

    private let state = Mutex<(records: [Record], services: [RecordingAdvertisedService], failNext: [TransportError], attempts: Int)>(
        ([], [], [], 0))

    var records: [Record] { state.withLock { $0.records } }
    var services: [RecordingAdvertisedService] { state.withLock { $0.services } }
    /// `advertise` calls so far, failed ones included.
    var attempts: Int { state.withLock { $0.attempts } }

    /// The TXT record most recently advertised or updated (nil before the first advertisement).
    var currentTXT: [String: String]? {
        state.withLock { state in
            guard let last = state.records.last else { return nil }
            return last.txtUpdates.last ?? last.advertisement.txt
        }
    }

    func failNextAdvertise(with error: TransportError) {
        failNextAdvertises([error])
    }

    /// The next `advertise` calls throw these errors, in order.
    func failNextAdvertises(_ errors: [TransportError]) {
        state.withLock { $0.failNext.append(contentsOf: errors) }
    }

    func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService {
        let (error, index): (TransportError?, Int) = state.withLock { state in
            state.attempts += 1
            if !state.failNext.isEmpty {
                return (state.failNext.removeFirst(), -1)
            }
            state.records.append(Record(advertisement: advertisement, txtUpdates: [], cancelled: false))
            return (nil, state.records.count - 1)
        }
        if let error { throw error }
        let service = RecordingAdvertisedService(index: index, owner: self)
        state.withLock { $0.services.append(service) }
        return service
    }

    fileprivate func recordUpdate(_ index: Int, txt: [String: String]) {
        state.withLock { $0.records[index].txtUpdates.append(txt) }
    }

    fileprivate func recordCancel(_ index: Int) {
        state.withLock { $0.records[index].cancelled = true }
    }

    /// Polls until `condition` holds for the current TXT record (or `timeout` passes).
    func waitForTXT(timeout: Duration = .seconds(5), _ condition: ([String: String]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let txt = currentTXT, condition(txt) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

final class RecordingAdvertisedService: AdvertisedService {
    let index: Int
    private weak let owner: RecordingAdvertiser?
    private let failureStream = AsyncStream<TransportError>.makeStream()
    private let updateError = Mutex<TransportError?>(nil)

    fileprivate init(index: Int, owner: RecordingAdvertiser) {
        self.index = index
        self.owner = owner
    }

    var failures: AsyncStream<TransportError> { failureStream.stream }

    func updateTXT(_ txt: [String: String]) async throws {
        if let error = updateError.withLock({ $0 }) { throw error }
        owner?.recordUpdate(index, txt: txt)
    }

    /// Every later `updateTXT` throws `error` (as DNS-SD does once mDNSResponder dropped the registration: `.closed`).
    func failUpdates(with error: TransportError) {
        updateError.withLock { $0 = error }
    }

    func cancel() {
        owner?.recordCancel(index)
        failureStream.continuation.finish()
    }

    /// Simulates a DNS-SD failure after registration (e.g. `.localNetworkDenied`).
    func fail(_ error: TransportError) {
        failureStream.continuation.yield(error)
    }
}
