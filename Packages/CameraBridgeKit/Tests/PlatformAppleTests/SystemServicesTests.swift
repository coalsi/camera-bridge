#if os(macOS)
import BridgeSupport
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import PlatformApple

@Suite struct NetworkChangeFilterTests {
    private func path(_ status: String, _ interfaces: [String], gateways: [String] = []) -> NetworkPathSignature {
        NetworkPathSignature(status: status, interfaces: interfaces, gateways: gateways)
    }

    @Test func initialPathIsNotAChange() {
        var filter = NetworkChangeFilter()
        let changed = filter.isChange(path("satisfied", ["en0"]))
        #expect(!changed)
    }

    @Test func reportsOnlyDifferences() {
        var filter = NetworkChangeFilter()
        let sequence = [
            path("satisfied", ["en0"], gateways: ["192.168.1.1"]),
            path("satisfied", ["en0"], gateways: ["192.168.1.1"]),
            path("satisfied", ["en0"], gateways: ["10.0.0.1"]),          // another network / DHCP lease
            path("satisfied", ["en0", "en1"], gateways: ["10.0.0.1"]),   // Ethernet plugged in
            path("unsatisfied", []),
            path("unsatisfied", []),
            path("satisfied", ["en1"]),
        ]
        let changes = sequence.map { filter.isChange($0) }
        #expect(changes == [false, false, true, true, true, false, true])
    }

    /// Hardening plan WS-C 5 (audit F4, network #6): a VPN client or AirDrop adds and removes `utun*`, `awdl*`, `llw*`,
    /// `anpi*` and `bridge*` interfaces all day, and each one reconnected every camera's stream.
    @Test func tunnelAndSystemInterfacesComingAndGoingAreNoChange() {
        var filter = NetworkChangeFilter()
        let lan = ["en0:wifi"]
        let sequence = [
            path("satisfied", lan, gateways: ["192.0.2.1"]),
            path("satisfied", lan + ["utun4:other"], gateways: ["192.0.2.1"]),
            path("satisfied", lan + ["utun4:other", "utun5:other", "awdl0:wifi"], gateways: ["192.0.2.1"]),
            path("satisfied", lan + ["llw0:wifi", "anpi0:wiredEthernet", "bridge100:wiredEthernet"], gateways: ["192.0.2.1"]),
            path("satisfied", ["utun3:other"] + lan, gateways: ["192.0.2.1"]),   // order does not matter either
            path("satisfied", lan, gateways: ["192.0.2.1"]),
        ]
        var results: [Bool] = []
        for signature in sequence { results.append(filter.isChange(signature)) }
        #expect(results == [false, false, false, false, false, false])
        // The interfaces that carry the LAN still count.
        let added = filter.isChange(path("satisfied", lan + ["en1:wiredEthernet"], gateways: ["192.0.2.1"]))
        let moved = filter.isChange(path("satisfied", ["en1:wiredEthernet"], gateways: ["192.0.2.1"]))
        #expect(added && moved)
        #expect(NetworkPathSignature.isIgnored(interface: "utun9") && !NetworkPathSignature.isIgnored(interface: "en0"))
    }

    /// Audit network #6: a DHCP renewal with the same gateway and a new IPv6 prefix changed nothing the monitor saw.
    @Test func anAddressOnlyChangeIsOneChange() {
        var filter = NetworkChangeFilter()
        let before = NetworkPathSignature(status: "satisfied", interfaces: ["en0:wifi"], gateways: ["192.0.2.1"],
                                          addresses: ["en0 192.0.2.69/24", "en0 2001:db8:4:7000::1/64"])
        let first = filter.isChange(before)
        let second = filter.isChange(before)
        #expect(!first && !second)
        let renewed = NetworkPathSignature(status: "satisfied", interfaces: ["en0:wifi"], gateways: ["192.0.2.1"],
                                           addresses: ["en0 192.0.2.70/24", "en0 2001:db8:4:7000::1/64"])
        let renewal = filter.isChange(renewed)
        let repeated = filter.isChange(renewed)
        #expect(renewal && !repeated)
        let prefix = NetworkPathSignature(status: "satisfied", interfaces: ["en0:wifi"], gateways: ["192.0.2.1"],
                                          addresses: ["en0 2605:aaaa:bbbb:1::1/64", "en0 192.0.2.70/24"])
        let newPrefix = filter.isChange(prefix)
        #expect(newPrefix, "a new IPv6 prefix")
        // The same addresses listed in another order are the same signature.
        let reordered = filter.isChange(NetworkPathSignature(status: "satisfied", interfaces: ["en0:wifi"], gateways: ["192.0.2.1"],
                                                             addresses: ["en0 192.0.2.70/24", "en0 2605:aaaa:bbbb:1::1/64"]))
        #expect(!reordered)
    }
}

@Suite struct ServiceBrowserNameTests {
    /// An instance mDNSResponder renamed because its name was taken is still the service (the health check must not register it
    /// again and again), but another device's name is not.
    @Test func aRenamedInstanceIsTheSameService() {
        #expect(AppleServiceBrowser.isInstance("Driveway", of: "Driveway"))
        #expect(AppleServiceBrowser.isInstance("Driveway (2)", of: "Driveway"))
        #expect(AppleServiceBrowser.isInstance("Driveway (12)", of: "Driveway"))
        #expect(!AppleServiceBrowser.isInstance("Driveway (x)", of: "Driveway"))
        #expect(!AppleServiceBrowser.isInstance("Driveway ()", of: "Driveway"))
        #expect(!AppleServiceBrowser.isInstance("Driveway Cam", of: "Driveway"))
        #expect(!AppleServiceBrowser.isInstance("Front Door", of: "Driveway"))
    }
}

@Suite struct InterfaceAddressesTests {
    /// Field report 2026-10-04: two unique local /64 addresses (a home hub's Thread prefix) flipped deprecated on every router
    /// advertisement, and every flip counted as a network change. Unique local addresses are left out of the snapshot,
    /// and deprecation no longer removes an address from it.
    @Test func uniqueLocalAddressesAreLeftOut() {
        func address(_ text: String) -> in6_addr { var raw = in6_addr(); _ = inet_pton(AF_INET6, text, &raw); return raw }
        #expect(InterfaceAddresses.isUniqueLocal(address("fd00:db8:a:b::1")))
        #expect(InterfaceAddresses.isUniqueLocal(address("fc00::1")))
        #expect(!InterfaceAddresses.isUniqueLocal(address("2001:db8:4:7000::1")))
        #expect(!InterfaceAddresses.isUniqueLocal(address("fe80::1")))
        #expect(!InterfaceAddresses.stable().contains { $0.isIPv6 && ($0.address.lowercased().hasPrefix("fc") || $0.address.lowercased().hasPrefix("fd")) })
    }

    @Test func theSnapshotHoldsOnlyStableAddressesOfEthernetAndWiFiInterfaces() {
        let addresses = InterfaceAddresses.stable()
        #expect(addresses.allSatisfy { $0.interface.hasPrefix("en") })
        #expect(addresses.allSatisfy { !$0.address.lowercased().hasPrefix("fe80") }, "link-local addresses come and go with the link")
        #expect(addresses.allSatisfy { $0.isIPv6 ? (1...128).contains($0.prefixLength) : (1...32).contains($0.prefixLength) })
        #expect(addresses == addresses.sorted { ($0.interface, $0.address) < ($1.interface, $1.address) })
        #expect(InterfaceAddresses.stable() == addresses, "stable between two reads")
    }

    @Test func gatewaysCountOnlyOnNetworksAnEthernetOrWiFiInterfaceIsOn() {
        let held = [InterfaceAddress(interface: "en0", address: "192.0.2.69", prefixLength: 24, isIPv6: false),
                    InterfaceAddress(interface: "en0", address: "2001:db8:4:7000:40b:e3c3:fe43:6f1d", prefixLength: 64, isIPv6: true)]
        #expect(InterfaceAddresses.isOnLink("192.0.2.1", among: held))
        #expect(!InterfaceAddresses.isOnLink("10.8.0.1", among: held), "a VPN's gateway")
        #expect(!InterfaceAddresses.isOnLink("192.168.5.1", among: held))
        #expect(InterfaceAddresses.isOnLink("2001:db8:4:7000::1", among: held))
        #expect(!InterfaceAddresses.isOnLink("2001:db8::1", among: held))
        #expect(InterfaceAddresses.isOnLink("fe80::1%en0", among: held))
        #expect(!InterfaceAddresses.isOnLink("fe80::1%utun3", among: held))
        #expect(!InterfaceAddresses.isOnLink("192.0.2.1", among: []))
    }
}

@Suite(.timeLimit(.minutes(1))) struct NWPathNetworkChangeMonitorTests {
    @Test func cancelFinishesSubscriptions() async {
        let monitor = NWPathNetworkChangeMonitor()
        let first = monitor.changes
        let second = monitor.changes
        monitor.cancel()
        for await _ in first {}
        for await _ in second {}
        var late = 0
        for await _ in monitor.changes { late += 1 }   // subscribing after cancel finishes immediately
        #expect(late == 0)
    }
}

@Suite struct ApplePowerManagerTests {
    @Test func backgroundActivityIsHeldOnce() {
        let power = ApplePowerManager()
        #expect(!power.isBackgroundActivityActive)
        power.beginBackgroundActivity(reason: "CameraBridge tests")
        power.beginBackgroundActivity(reason: "CameraBridge tests again")
        #expect(power.isBackgroundActivityActive)
        power.endBackgroundActivity()
        #expect(!power.isBackgroundActivityActive)
    }

    @Test func keepSystemAwakeHoldsAndReleasesAnIdleSleepAssertion() {
        let power = ApplePowerManager()
        let reason = "CameraBridge test assertion \(UUID().uuidString)"
        power.setKeepSystemAwake(true, reason: reason)
        power.setKeepSystemAwake(true, reason: reason)   // idempotent: still one assertion
        #expect(power.isKeepingSystemAwake)
        #expect(Self.assertions(named: reason) == ["PreventUserIdleSystemSleep"])
        power.setKeepSystemAwake(false, reason: reason)
        #expect(!power.isKeepingSystemAwake)
        #expect(Self.assertions(named: reason).isEmpty)
    }

    /// A desktop has no internal battery; a laptop has one. Either way the answer is stable.
    @Test func hasBatteryIsAStableAnswer() {
        let power = ApplePowerManager()
        #expect(power.hasBattery == power.hasBattery)
    }

    @Test func deinitReleasesTheAssertion() {
        let reason = "CameraBridge test assertion \(UUID().uuidString)"
        do {
            let power = ApplePowerManager()
            power.setKeepSystemAwake(true, reason: reason)
            #expect(Self.assertions(named: reason).count == 1)
        }
        #expect(Self.assertions(named: reason).isEmpty)
    }

    /// Types of this process's power assertions with the given name (independent check via IOKit).
    static func assertions(named name: String) -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess, let all = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }
        let mine = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.filter { $0[kIOPMAssertionNameKey] as? String == name }.compactMap { $0[kIOPMAssertionTypeKey] as? String }
    }
}

/// Hardening plan WS-C 12: one copy of the app per configuration.
@Suite struct AppleInstanceLockTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "InstanceLockTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func aSecondHolderOfTheSameDirectoryIsRefusedUntilTheFirstReleases() {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppleInstanceLock()
        let second = AppleInstanceLock()
        #expect(first.acquire(directory: directory) == nil)
        #expect(first.acquire(directory: directory) == nil, "idempotent for the holder")
        let refusal = second.acquire(directory: directory)
        #expect(refusal?.contains("already running") == true)
        first.release()
        #expect(second.acquire(directory: directory) == nil, "free once the first copy released it")
        second.release()
        second.release()   // idempotent
    }

    /// A Debug build under another bundle ID has its own container, so its own directory and its own lock.
    @Test func aCopyWithItsOwnDirectoryIsNotAffected() {
        let a = directory(), b = directory()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let first = AppleInstanceLock()
        let second = AppleInstanceLock()
        #expect(first.acquire(directory: a) == nil)
        #expect(second.acquire(directory: b) == nil)
        first.release()
        second.release()
    }

    /// The kernel drops the lock with the descriptor: a holder that is released by `deinit` frees it too.
    @Test func aHolderThatGoesAwayFreesTheLock() {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let gone = AppleInstanceLock()
            #expect(gone.acquire(directory: directory) == nil)
        }
        let next = AppleInstanceLock()
        #expect(next.acquire(directory: directory) == nil)
        next.release()
    }
}

@Suite struct ApplePlatformTests {
    @Test func servicesWireTheAppleImplementations() {
        let services = ApplePlatform.services()
        #expect(services.transport is AppleNetworkTransport)
        #expect(services.advertiser is DNSSDServiceAdvertiser)
        #expect((services.secrets as? KeychainSecretStore)?.service == "com.coreysilvia.CameraBridge")
        #expect(services.networkChanges is NWPathNetworkChangeMonitor)
        #expect(services.power is ApplePowerManager)
        #expect(services.browser is AppleServiceBrowser)
        #expect(services.instanceLock is AppleInstanceLock)
        (services.networkChanges as? NWPathNetworkChangeMonitor)?.cancel()
    }
}
#endif
