import Foundation
import HAP
import Synchronization

/// A fake `HAPSessionHandle` for driving a `DataStreamServer` (or a camera controller) without a HAP connection:
/// a known shared secret, loopback addresses and a manual `close()` that runs the `onClose` handlers once.
public final class TestHAPSession: HAPSessionHandle {
    public let id: UUID
    public let controllerID: String
    public let isAdmin: Bool
    public let sharedSecret: Data
    public let localAddress: String
    public let remoteAddress: String
    public let isIPv6: Bool
    public let zone: String?
    private let state = Mutex<(closed: Bool, handlers: [@Sendable () -> Void])>((false, []))

    public init(id: UUID = UUID(), controllerID: String = UUID().uuidString, isAdmin: Bool = true,
                sharedSecret: Data = ControllerTLV.randomBytes(32), localAddress: String = "127.0.0.1",
                remoteAddress: String = "127.0.0.1", isIPv6: Bool = false, zone: String? = nil) {
        self.id = id
        self.controllerID = controllerID
        self.isAdmin = isAdmin
        self.sharedSecret = sharedSecret
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.isIPv6 = isIPv6
        self.zone = zone
    }

    public var isClosed: Bool { state.withLock { $0.closed } }

    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        let alreadyClosed = state.withLock { state in
            if !state.closed { state.handlers.append(handler) }
            return state.closed
        }
        if alreadyClosed { handler() }
    }

    /// Simulates the HAP connection closing: runs every registered handler once.
    public func close() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.closed else { return [] }
            state.closed = true
            defer { state.handlers = [] }
            return state.handlers
        }
        handlers.forEach { $0() }
    }
}
