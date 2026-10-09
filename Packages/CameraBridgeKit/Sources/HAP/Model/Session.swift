import Foundation
import Synchronization

public protocol HAPSessionHandle: AnyObject, Sendable {
    var id: UUID { get }
    var controllerID: String { get }
    var isAdmin: Bool { get }
    /// Pair-verify X25519 shared secret (used for HDS key derivation).
    var sharedSecret: Data { get }
    /// IP of our interface this connection arrived on.
    var localAddress: String { get }
    var remoteAddress: String { get }
    var isIPv6: Bool { get }
    /// The IPv6 zone of the connection (`TCPConnection.zone`, e.g. `en0`) when it runs over link-local addresses: the
    /// interface a link-local address the controller names (SetupEndpoints carries none) is reached through. nil
    /// otherwise. Default: nil.
    var zone: String? { get }
    /// Called once when the HAP connection closes.
    func onClose(_ handler: @escaping @Sendable () -> Void)
}

extension HAPSessionHandle {
    public var zone: String? { nil }
}

public struct HAPRequestContext: Sendable {
    public let session: any HAPSessionHandle

    public init(session: any HAPSessionHandle) {
        self.session = session
    }
}

/// A verified HAP connection (created by pair-verify M3/M4).
final class HAPSession: HAPSessionHandle {
    let id = UUID()
    let controllerID: String
    let sharedSecret: Data
    let localAddress: String
    let remoteAddress: String
    let isIPv6: Bool
    let zone: String?
    private let state: Mutex<(isAdmin: Bool, closed: Bool, handlers: [@Sendable () -> Void])>

    init(controllerID: String, isAdmin: Bool, sharedSecret: Data, localAddress: String, remoteAddress: String, isIPv6: Bool,
         zone: String? = nil) {
        self.controllerID = controllerID
        self.sharedSecret = sharedSecret
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.isIPv6 = isIPv6
        self.zone = zone
        state = Mutex((isAdmin, false, []))
    }

    var isAdmin: Bool { state.withLock { $0.isAdmin } }

    func setAdmin(_ admin: Bool) {
        state.withLock { $0.isAdmin = admin }
    }

    /// Runs `handler` when the connection closes (at once if it already has).
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let closed = state.withLock { state -> Bool in
            if !state.closed { state.handlers.append(handler) }
            return state.closed
        }
        if closed { handler() }
    }

    func markClosed() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.closed else { return [] }
            state.closed = true
            defer { state.handlers.removeAll() }
            return state.handlers
        }
        for handler in handlers { handler() }
    }
}
