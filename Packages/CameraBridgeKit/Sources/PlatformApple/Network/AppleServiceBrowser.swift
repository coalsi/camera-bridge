#if os(macOS)
import BridgeSupport
import Foundation
import Network
import Synchronization

/// `ServiceBrowsing` over `NWBrowser` with TXT records: what a controller sees when it browses `_hap._tcp`. Needs Local
/// Network access like advertising does; without it (or when the browser cannot start) the answer is `.unavailable`, which
/// the health check ignores. A browse lasts at most `timeout` and is cancelled once the service shows up. An instance that
/// mDNSResponder renamed because the name was taken ("Driveway" → "Driveway (2)") is the same service.
public final class AppleServiceBrowser: ServiceBrowsing {
    public init() {}

    public func lookup(type: String, name: String, timeout: Duration) async -> ServiceLookup {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: NWParameters())
        let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.browse")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ServiceLookup, Never>) in
                let once = LookupOnce(continuation)
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error):
                        once.finish(.unavailable("\(error)"), cancelling: browser)
                    case .waiting(let error):
                        // Waiting for the local network: denied access never resolves by waiting.
                        if case .dns(let code) = error, code == AppleNetworkTransport.dnsPolicyDenied {
                            once.finish(.unavailable("Local Network access was denied"), cancelling: browser)
                        }
                    default:
                        break
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        guard case .service(let found, _, _, _) = result.endpoint, Self.isInstance(found, of: name),
                              case .bonjour(let record) = result.metadata else { continue }
                        once.finish(.found(record.dictionary), cancelling: browser)
                        return
                    }
                }
                queue.asyncAfter(deadline: .now() + AppleNetworkTransport.dispatchInterval(timeout)) {
                    once.finish(.notFound, cancelling: browser)
                }
                browser.start(queue: queue)
            }
        } onCancel: {
            browser.cancel()
        }
    }
}

extension AppleServiceBrowser {
    /// `found` is `name` or `name (N)` (the name mDNSResponder gives the second registration of a name).
    static func isInstance(_ found: String, of name: String) -> Bool {
        guard found != name else { return true }
        guard found.hasPrefix(name + " ("), found.hasSuffix(")") else { return false }
        let number = found.dropFirst(name.count + 2).dropLast()
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }
}

/// Resumes a lookup once and cancels its browser.
private final class LookupOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<ServiceLookup, Never>?>

    init(_ continuation: CheckedContinuation<ServiceLookup, Never>) {
        self.continuation = Mutex(continuation)
    }

    func finish(_ result: ServiceLookup, cancelling browser: NWBrowser) {
        let taken = continuation.withLock { state in
            defer { state = nil }
            return state
        }
        guard let taken else { return }
        browser.cancel()
        taken.resume(returning: result)
    }
}
#endif
