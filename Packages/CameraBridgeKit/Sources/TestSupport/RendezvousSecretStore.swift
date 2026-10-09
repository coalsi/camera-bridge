import BridgeSupport
import Foundation
import Synchronization

/// A `SecretStore` over `base` whose reads of the accounts `matching` meet once armed: the first read, having read its
/// value, waits (blocking its thread, as the Keychain does) up to `wait` for a second read of a matching account to have
/// read too, then both return. Two callers that each read before either writes (a lost-update race) then do so every
/// time, not only when the timing happens to line up; a caller that holds a lock across its read and write makes the
/// first read time out instead, and the second reads what the first wrote. Writes are counted per account.
public final class RendezvousSecretStore: SecretStore {
    private let base: any SecretStore
    private let matching: @Sendable (String) -> Bool
    private let wait: Duration
    /// Matching reads done since `arm()`; nil: not armed, or the rendezvous is over.
    private let arrivals = Mutex<Int?>(nil)
    /// Writes per account (deletions included).
    public let writes = Box<[String: Int]>([:])
    /// Matching reads that met another one (2 after a rendezvous).
    public let meetings = Box(0)

    public init(base: any SecretStore = InMemorySecretStore(), wait: Duration = .seconds(1),
                matching: @escaping @Sendable (String) -> Bool) {
        self.base = base
        self.wait = wait
        self.matching = matching
    }

    /// From now on the next two matching reads meet (once).
    public func arm() {
        arrivals.withLock { $0 = 0 }
    }

    public func read(account: String) throws -> Data? {
        let value = try base.read(account: account)
        guard matching(account), let arrived = arrivals.withLock({ count -> Int? in
            guard let current = count, current < 2 else { return nil }
            count = current + 1
            return current + 1
        }) else { return value }
        if arrived == 2 {
            meetings.update { $0 += 1 }
            return value
        }
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline, arrivals.withLock({ ($0 ?? 2) < 2 }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let met = arrivals.withLock { count -> Bool in
            guard (count ?? 2) < 2 else { return true }
            count = nil   // nobody came: the rendezvous is over
            return false
        }
        if met { meetings.update { $0 += 1 } }
        return value
    }

    public func write(_ data: Data?, account: String) throws {
        writes.update { $0[account, default: 0] += 1 }
        try base.write(data, account: account)
    }
}
