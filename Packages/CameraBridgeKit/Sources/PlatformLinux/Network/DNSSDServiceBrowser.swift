#if os(Linux)
import BridgeSupport
import CDNSSD
import Dispatch
import Foundation
import Glibc
import Synchronization

/// `ServiceBrowsing` over the dns_sd API of Avahi's compatibility library: `DNSServiceBrowse` for the service type, then
/// `DNSServiceResolve` of the instance for its TXT record, which is what a controller sees when it browses `_hap._tcp`. When
/// browsing cannot start (avahi-daemon is not running) the answer is `.unavailable`, which the health check ignores. A browse
/// lasts at most `timeout` and ends once the service shows up. An instance that was renamed because the name was taken
/// ("Driveway" → "Driveway #2") is the same service.
public final class DNSSDServiceBrowser: ServiceBrowsing {
    public init() {
        DNSSDSupport.silenceCompatibilityWarning()
    }

    public func lookup(type: String, name: String, timeout: Duration) async -> ServiceLookup {
        let session = BrowseSession(type: type, name: name)
        return await withTaskCancellationHandler {
            await session.run(timeout: timeout)
        } onCancel: {
            session.cancel()
        }
    }

    /// `found` is `name` or `name #N` / `name (N)` (what the daemon calls the second registration of a name).
    static func isInstance(_ found: String, of name: String) -> Bool {
        guard found != name else { return true }
        for (opening, closing) in [(" (", ")"), (" #", "")] where found.hasPrefix(name + opening) && found.hasSuffix(closing) {
            let number = found.dropFirst(name.count + opening.count).dropLast(closing.count)
            if !number.isEmpty, number.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// The `key=value` entries of a TXT record (a key without `=` has an empty value).
    static func parseTXT(_ bytes: [UInt8]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard length > 0, index + length <= bytes.count else { break }
            let entry = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
            index += length
            if let equals = entry.firstIndex(of: "=") {
                result[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            } else {
                result[entry] = ""
            }
        }
        return result
    }
}

/// One lookup. All state is read and written only on `queue` (where the callbacks run), hence `@unchecked Sendable`.
private final class BrowseSession: @unchecked Sendable {
    private let type: String
    private let name: String
    private let queue = DispatchQueue(label: "com.coreysilvia.CameraBridge.dnssd.browse")
    private var continuation: CheckedContinuation<ServiceLookup, Never>?
    private var browse: (ref: DNSServiceRef?, watcher: any DispatchSourceRead)?
    private var resolve: (ref: DNSServiceRef?, watcher: any DispatchSourceRead)?
    private var retained: Unmanaged<BrowseSession>?
    private var finished = false

    init(type: String, name: String) {
        self.type = type
        self.name = name
    }

    func run(timeout: Duration) async -> ServiceLookup {
        await withCheckedContinuation { (continuation: CheckedContinuation<ServiceLookup, Never>) in
            queue.async { [self] in
                guard !finished else {
                    continuation.resume(returning: .notFound)
                    return
                }
                self.continuation = continuation
                let context = Unmanaged.passRetained(self)
                retained = context
                var ref: DNSServiceRef?
                let status = DNSServiceBrowse(&ref, 0, 0, type, nil, dnssdBrowseReply, context.toOpaque())
                guard Int(status) == Int(kDNSServiceErr_NoError), let ref else {
                    finish(.unavailable("DNS-SD error \(status): browsing is not available (is avahi-daemon running?)"))
                    return
                }
                browse = (ref, DNSSDSupport.watch(ref, on: queue) { [self] status in finish(.unavailable("DNS-SD error \(status)")) })
                queue.asyncAfter(deadline: .now() + SocketDescriptor.dispatchInterval(timeout)) { [self] in finish(.notFound) }
            }
        }
    }

    func cancel() {
        queue.async { [self] in finish(.notFound) }
    }

    /// Ends the lookup once: stops browsing and resolving and answers.
    private func finish(_ result: ServiceLookup) {
        guard !finished else { return }
        finished = true
        browse?.watcher.cancel()
        resolve?.watcher.cancel()
        browse = nil
        resolve = nil
        retained?.release()
        retained = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: result)
    }

    fileprivate func found(instance: String, interface: UInt32, regtype: String, domain: String) {
        guard !finished, resolve == nil, DNSSDServiceBrowser.isInstance(instance, of: name), let context = retained else { return }
        var ref: DNSServiceRef?
        let status = DNSServiceResolve(&ref, 0, interface, instance, regtype, domain, dnssdResolveReply, context.toOpaque())
        guard Int(status) == Int(kDNSServiceErr_NoError), let ref else {
            finish(.unavailable("DNS-SD error \(status) resolving \"\(instance)\""))
            return
        }
        resolve = (ref, DNSSDSupport.watch(ref, on: queue) { [self] status in finish(.unavailable("DNS-SD error \(status)")) })
    }

    fileprivate func resolved(txt: [UInt8]) {
        finish(.found(DNSSDServiceBrowser.parseTXT(txt)))
    }

    fileprivate func failed(_ status: DNSServiceErrorType) {
        finish(.unavailable("DNS-SD error \(status)"))
    }
}

private let dnssdBrowseReply: DNSServiceBrowseReply = { _, flags, interface, error, serviceName, regtype, replyDomain, context in
    guard let context else { return }
    let session = Unmanaged<BrowseSession>.fromOpaque(context).takeUnretainedValue()
    if Int(error) != Int(kDNSServiceErr_NoError) {
        session.failed(error)
    } else if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let serviceName, let regtype, let replyDomain {
        session.found(instance: String(cString: serviceName), interface: interface, regtype: String(cString: regtype),
                      domain: String(cString: replyDomain))
    }
}

private let dnssdResolveReply: DNSServiceResolveReply = { _, _, _, error, _, _, _, txtLength, txtRecord, context in
    guard let context else { return }
    let session = Unmanaged<BrowseSession>.fromOpaque(context).takeUnretainedValue()
    if Int(error) != Int(kDNSServiceErr_NoError) {
        session.failed(error)
    } else {
        session.resolved(txt: txtRecord.map { Array(UnsafeBufferPointer(start: $0, count: Int(txtLength))) } ?? [])
    }
}
#endif
