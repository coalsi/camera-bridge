#if os(macOS)
import BridgeSupport
import dnssd
import Foundation
import TestSupport
import Testing
@testable import PlatformApple

/// Registers `_cbtest._tcp` services with `kDNSServiceInterfaceIndexLocalOnly`: they are visible to clients on this
/// Mac only and never announced on the LAN. Resolution uses the same local-only interface index.
@Suite(.timeLimit(.minutes(1))) struct DNSSDServiceAdvertiserTests {
    @Test func registersResolvesUpdatesAndWithdrawsALocalOnlyService() async throws {
        let advertiser = DNSSDServiceAdvertiser(scope: .localOnly)
        let name = "CameraBridge Test \(UUID().uuidString.prefix(8))"
        let txt = ["c#": "1", "sf": "1", "id": "AA:BB:CC:DD:EE:FF", "md": "Driveway"]
        let service = try await advertiser.advertise(ServiceAdvertisement(name: name, type: "_cbtest._tcp", port: 21_234, txt: txt))
        defer { service.cancel() }
        #expect((service as? DNSSDAdvertisedService)?.registeredName == name)

        let resolved = try #require(await LocalOnlyResolver.resolve(name: name, type: "_cbtest._tcp"))
        #expect(resolved.port == 21_234)
        #expect(resolved.txt == txt)

        try await service.updateTXT(["c#": "2", "sf": "0"])
        var updated: [String: String]?
        for _ in 0..<50 where updated != ["c#": "2", "sf": "0"] {
            updated = await LocalOnlyResolver.resolve(name: name, type: "_cbtest._tcp")?.txt
            if updated != ["c#": "2", "sf": "0"] { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(updated == ["c#": "2", "sf": "0"])

        let failures = service.failures
        service.cancel()
        for await failure in failures { Issue.record("unexpected failure \(failure)") }
        var stillListed = true
        for _ in 0..<30 where stillListed {
            stillListed = await LocalOnlyBrowser.names(type: "_cbtest._tcp", for: .milliseconds(300)).contains(name)
        }
        #expect(!stillListed, "service still browsable after cancel")
        await #expect(throws: TransportError.closed) { try await service.updateTXT(["c#": "3"]) }
    }

    @Test func invalidServiceTypeFails() async {
        await #expect(throws: TransportError.self) {
            let service = try await DNSSDServiceAdvertiser(scope: .localOnly)
                .advertise(ServiceAdvertisement(name: "x", type: "not a service type", port: 1, txt: [:]))
            service.cancel()
        }
    }

    @Test func encodesTXTRecords() throws {
        #expect(try DNSSDServiceAdvertiser.txtRecord([:]) == Data())
        // Sorted by key; an empty value is written as "key=".
        #expect(try DNSSDServiceAdvertiser.txtRecord(["sf": "1", "c#": "12", "e": ""])
                == Data([5]) + Data("c#=12".utf8) + Data([2]) + Data("e=".utf8) + Data([4]) + Data("sf=1".utf8))
        #expect(throws: TransportError.self) { try DNSSDServiceAdvertiser.txtRecord(["k": String(repeating: "v", count: 254)]) }
        #expect(throws: TransportError.self) { try DNSSDServiceAdvertiser.txtRecord(["": "v"]) }
        #expect(throws: TransportError.self) { try DNSSDServiceAdvertiser.txtRecord(["a=b": "v"]) }
        #expect(try DNSSDServiceAdvertiser.txtRecord(["k": String(repeating: "v", count: 253)]).count == 256)
    }

    @Test func mapsDNSServiceErrors() {
        #expect(DNSSDServiceAdvertiser.transportError(Int32(kDNSServiceErr_PolicyDenied)) == .localNetworkDenied)
        #expect(DNSSDServiceAdvertiser.transportError(-65570) == .localNetworkDenied)
        guard case .failed(let conflict) = DNSSDServiceAdvertiser.transportError(Int32(kDNSServiceErr_NameConflict)) else {
            Issue.record("name conflict should map to .failed"); return
        }
        #expect(conflict.contains("-65548"))
        guard case .failed = DNSSDServiceAdvertiser.transportError(Int32(kDNSServiceErr_ServiceNotRunning)) else {
            Issue.record("service not running should map to .failed"); return
        }
    }
}

// MARK: - Local-only DNS-SD client (independent of the advertiser under test)

private enum LocalOnlyResolver {
    struct Result: Sendable { var port: UInt16; var txt: [String: String] }

    /// Resolves `name.type.local.` on the local-only interface; nil if nothing answers within one second.
    static func resolve(name: String, type: String) async -> Result? {
        let box = Box<Result?>(nil)
        let queue = DispatchQueue(label: "test.resolve")
        var ref: DNSServiceRef?
        // `box` outlives the DNSServiceRef: the ref is deallocated (on its queue) before this function returns.
        let context = Unmanaged.passUnretained(box).toOpaque()
        let status = DNSServiceResolve(&ref, 0, kDNSServiceInterfaceIndexLocalOnly, name, type, "local.", { _, _, _, error, _, _, port, txtLength, txtBytes, context in
            guard Int(error) == kDNSServiceErr_NoError, let context else { return }
            let box = Unmanaged<Box<Result?>>.fromOpaque(context).takeUnretainedValue()
            let txt = txtBytes.map { Data(bytes: $0, count: Int(txtLength)) } ?? Data()
            box.set(Result(port: UInt16(bigEndian: port), txt: LocalOnlyResolver.parseTXT(txt)))
        }, context)
        guard Int(status) == kDNSServiceErr_NoError, let ref else { return nil }
        DNSServiceSetDispatchQueue(ref, queue)
        for _ in 0..<20 where box.value == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let sendableRef = SendableRef(ref)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                DNSServiceRefDeallocate(sendableRef.ref)
                continuation.resume()
            }
        }
        return box.value
    }

    /// Length-prefixed `key=value` strings.
    static func parseTXT(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index += 1
            guard length > 0, index + length <= data.endIndex else { index += length; continue }
            let entry = String(decoding: data[index..<index + length], as: UTF8.self)
            index += length
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            result[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        return result
    }
}

private enum LocalOnlyBrowser {
    /// Instance names currently registered for `type` on the local-only interface.
    static func names(type: String, for window: Duration) async -> Set<String> {
        let box = Box<Set<String>>([])
        let queue = DispatchQueue(label: "test.browse")
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(box).toOpaque()   // outlives the ref, as in `resolve`
        let status = DNSServiceBrowse(&ref, 0, kDNSServiceInterfaceIndexLocalOnly, type, "local.", { _, flags, _, error, name, _, _, context in
            guard Int(error) == kDNSServiceErr_NoError, let context, let name else { return }
            let box = Unmanaged<Box<Set<String>>>.fromOpaque(context).takeUnretainedValue()
            let instance = String(cString: name)
            box.update { names in
                if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 { names.insert(instance) } else { names.remove(instance) }
            }
        }, context)
        guard Int(status) == kDNSServiceErr_NoError, let ref else { return [] }
        DNSServiceSetDispatchQueue(ref, queue)
        try? await Task.sleep(for: window)
        let sendableRef = SendableRef(ref)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                DNSServiceRefDeallocate(sendableRef.ref)
                continuation.resume()
            }
        }
        return box.value
    }
}

private struct SendableRef: @unchecked Sendable {   // only used on its dispatch queue
    let ref: DNSServiceRef
    init(_ ref: DNSServiceRef) { self.ref = ref }
}
#endif
