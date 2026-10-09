#if os(macOS)
import BridgeSupport
import dnssd
import Foundation
import Synchronization

/// `ServiceAdvertiser` over dns_sd: `DNSServiceRegister` with the TXT record, `DNSServiceUpdateRecord` for TXT
/// updates (NULL record ref = the primary TXT record), mDNSResponder callbacks on a private serial queue.
///
/// `advertise` returns once mDNSResponder confirms the registration (or after 5 s without an answer, with the
/// registration still pending). An error in that first answer is thrown (`-65570` → `.localNetworkDenied`); later
/// errors are yielded on `failures`. After `.failed` for "service not running" (mDNSResponder restarted) the
/// registration is gone: cancel and advertise again. Name conflicts are resolved by mDNSResponder's automatic
/// renaming (`DNSSDAdvertisedService.registeredName`). Dropping the returned service withdraws it.
public final class DNSSDServiceAdvertiser: ServiceAdvertiser {
    public enum Scope: Sendable, Equatable {
        /// Every interface (`kDNSServiceInterfaceIndexAny`): visible on the LAN.
        case allInterfaces
        /// `kDNSServiceInterfaceIndexLocalOnly`: visible to clients on this Mac only, never announced (tests).
        case localOnly
    }

    public let scope: Scope

    public convenience init() {
        self.init(scope: .allInterfaces)
    }

    public init(scope: Scope) {
        self.scope = scope
    }

    /// How long `advertise` waits for mDNSResponder's first answer.
    static let registrationWait: Duration = .seconds(5)

    public func advertise(_ advertisement: ServiceAdvertisement) async throws -> any AdvertisedService {
        let txt = try Self.txtRecord(advertisement.txt)
        let registration = DNSSDRegistration()
        try await registration.register(name: advertisement.name, type: advertisement.type, port: advertisement.port, txt: txt,
                                        interfaceIndex: scope == .localOnly ? kDNSServiceInterfaceIndexLocalOnly : 0)
        return DNSSDAdvertisedService(registration: registration)
    }

    /// DNS-SD TXT record data: `key=value` strings (keys sorted), each prefixed by its length. Empty for no keys.
    static func txtRecord(_ txt: [String: String]) throws -> Data {
        var data = Data()
        for key in txt.keys.sorted() {
            guard !key.isEmpty, !key.contains("="), key.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else {
                throw TransportError.failed("invalid TXT key \"\(key)\"")
            }
            let entry = Data("\(key)=\(txt[key] ?? "")".utf8)
            guard entry.count <= 255 else { throw TransportError.failed("TXT entry for \"\(key)\" exceeds 255 bytes") }
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        guard data.count <= Int(UInt16.max) else { throw TransportError.failed("TXT record too large") }
        return data
    }

    static func transportError(_ code: DNSServiceErrorType) -> TransportError {
        switch Int(code) {
        case kDNSServiceErr_PolicyDenied: return .localNetworkDenied
        case kDNSServiceErr_NameConflict: return .failed("DNS-SD error \(code) (name conflict)")
        case kDNSServiceErr_ServiceNotRunning: return .failed("DNS-SD error \(code) (mDNSResponder not running)")
        case kDNSServiceErr_BadParam: return .failed("DNS-SD error \(code) (bad parameter)")
        default: return .failed("DNS-SD error \(code)")
        }
    }
}

/// A live registration; see `DNSSDServiceAdvertiser`.
public final class DNSSDAdvertisedService: AdvertisedService {
    private let registration: DNSSDRegistration

    init(registration: DNSSDRegistration) {
        self.registration = registration
    }

    deinit {
        registration.cancel()
    }

    /// The instance name mDNSResponder registered (differs from the requested one after a conflict rename);
    /// nil while the registration is pending.
    public var registeredName: String? { registration.registeredName }

    public var failures: AsyncStream<TransportError> { registration.failures }

    public func updateTXT(_ txt: [String: String]) async throws {
        try await registration.updateTXT(DNSSDServiceAdvertiser.txtRecord(txt))
    }

    public func cancel() {
        registration.cancel()
    }
}

/// Owns the `DNSServiceRef`. Every mutable property except `name` (a `Mutex`) is read and written only on `queue`,
/// which is also where mDNSResponder callbacks run; that confinement is why the class is `@unchecked Sendable`.
final class DNSSDRegistration: @unchecked Sendable {
    let failures: AsyncStream<TransportError>
    private let failureContinuation: AsyncStream<TransportError>.Continuation
    private let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.dnssd")
    private let name = Mutex<String?>(nil)
    // Queue-confined:
    private var ref: DNSServiceRef?
    private var pending: CheckedContinuation<Void, any Error>?
    private var retained: Unmanaged<DNSSDRegistration>?
    private var cancelled = false

    init() {
        (failures, failureContinuation) = AsyncStream.makeStream(of: TransportError.self, bufferingPolicy: .bufferingNewest(16))
    }

    var registeredName: String? { name.withLock { $0 } }

    func register(name: String, type: String, port: UInt16, txt: Data, interfaceIndex: UInt32) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                let context = Unmanaged.passRetained(self)
                var newRef: DNSServiceRef?
                let status = txt.withUnsafeBytes { bytes in
                    DNSServiceRegister(&newRef, 0, interfaceIndex, name, type, nil, nil, port.bigEndian, UInt16(bytes.count),
                                       bytes.isEmpty ? nil : bytes.baseAddress, dnssdRegisterReply, context.toOpaque())
                }
                guard Int(status) == kDNSServiceErr_NoError, let newRef else {
                    context.release()
                    continuation.resume(throwing: DNSSDServiceAdvertiser.transportError(status))
                    return
                }
                let queueStatus = DNSServiceSetDispatchQueue(newRef, queue)
                guard Int(queueStatus) == kDNSServiceErr_NoError else {
                    DNSServiceRefDeallocate(newRef)
                    context.release()
                    continuation.resume(throwing: DNSSDServiceAdvertiser.transportError(queueStatus))
                    return
                }
                ref = newRef
                retained = context
                pending = continuation
                queue.asyncAfter(deadline: .now() + AppleNetworkTransport.dispatchInterval(DNSSDServiceAdvertiser.registrationWait)) { [self] in
                    if let waiting = pending {
                        pending = nil
                        Log(category: "bonjour").warning("No answer from mDNSResponder for \"\(name)\" yet; registration pending")
                        waiting.resume()
                    }
                }
            }
        }
    }

    /// mDNSResponder's answer (on `queue`).
    fileprivate func handleReply(error: DNSServiceErrorType, flags: DNSServiceFlags, registeredName: String?) {
        if Int(error) == kDNSServiceErr_NoError {
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let registeredName { name.withLock { $0 = registeredName } }
            if let waiting = pending {
                pending = nil
                waiting.resume()
            }
            return
        }
        let mapped = DNSSDServiceAdvertiser.transportError(error)
        if let waiting = pending {
            pending = nil
            teardown()
            waiting.resume(throwing: mapped)
            return
        }
        Log(category: "bonjour").warning("Advertisement failed: \(mapped)")
        failureContinuation.yield(mapped)
        if Int(error) == kDNSServiceErr_ServiceNotRunning { teardown() }
    }

    func updateTXT(_ txt: Data) async throws {
        let record = txt.isEmpty ? Data([0]) : txt   // an empty TXT record is one empty string
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard let ref, !cancelled else {
                    continuation.resume(throwing: TransportError.closed)
                    return
                }
                let status = record.withUnsafeBytes { bytes in
                    DNSServiceUpdateRecord(ref, nil, 0, UInt16(bytes.count), bytes.baseAddress, 0)
                }
                if Int(status) == kDNSServiceErr_NoError {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: DNSSDServiceAdvertiser.transportError(status))
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            teardown()
            failureContinuation.finish()
        }
    }

    /// On `queue`: withdraws the registration and releases the callback context.
    private func teardown() {
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
        }
        retained?.release()
        retained = nil
    }
}

/// C callback for `DNSServiceRegister`; `context` is the retained `DNSSDRegistration`.
private let dnssdRegisterReply: DNSServiceRegisterReply = { _, flags, errorCode, name, _, _, context in
    guard let context else { return }
    let registration = Unmanaged<DNSSDRegistration>.fromOpaque(context).takeUnretainedValue()
    registration.handleReply(error: errorCode, flags: flags, registeredName: name.map { String(cString: $0) })
}
#endif
