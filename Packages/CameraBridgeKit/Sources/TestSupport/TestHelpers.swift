import Synchronization

/// A lock-protected value that test tasks, handlers and fakes share. The one copy for every test target
/// (PortabilityTests' SharedTestHelperTests keeps it from being redefined in Tests/).
public final class Box<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    public init(_ value: Value) {
        storage = Mutex(value)
    }

    /// The current value.
    public var value: Value {
        storage.withLock { $0 }
    }

    public func set(_ value: Value) {
        storage.withLock { $0 = value }
    }

    /// Runs `body` on the value under the lock and returns its result (a read-modify-write no other task interleaves).
    @discardableResult
    public func update<R: Sendable, E: Error>(_ body: (inout Value) throws(E) -> R) throws(E) -> R {
        try storage.withLock { value throws(E) -> R in try body(&value) }
    }
}

/// Polls `condition` every `interval` until it holds or `timeout` (real time) passes, then checks once more; returns
/// whether it held. The condition may be sync or async and need not be `@Sendable`: it runs on the caller's actor.
/// The one polling wait for every test target (PortabilityTests' SharedTestHelperTests keeps it from being redefined).
@discardableResult
public func eventually(timeout: Duration = .seconds(5), every interval: Duration = .milliseconds(10),
                       isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}
