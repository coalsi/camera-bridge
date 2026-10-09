import Synchronization

/// A `Mutex`-protected value in a class, so closures and tasks can share it.
final class LockedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    var value: Value { mutex.withLock { $0 } }

    func set(_ value: Value) { mutex.withLock { $0 = value } }

    @discardableResult
    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result { mutex.withLock { body(&$0) } }
}
