#if os(Linux)
import BridgeSupport
import Crypto
import Foundation
#if canImport(Glibc)
import Glibc
#endif
import MediaCore
import TestSupport
import Testing
@testable import PlatformLinux

@Suite struct FileSecretStoreTests {
    private func makeStore() throws -> (FileSecretStore, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        return (FileSecretStore(directory: directory.url), directory)
    }

    @Test func writesReadsOverwritesAndDeletes() throws {
        let (store, directory) = try makeStore()
        defer { directory.remove() }
        #expect(try store.read(account: "camera.1") == nil)
        try store.write(Data("first".utf8), account: "camera.1")
        #expect(try store.read(account: "camera.1") == Data("first".utf8))
        try store.write(Data("second".utf8), account: "camera.1")
        #expect(try store.read(account: "camera.1") == Data("second".utf8))
        try store.write(Data([0, 1, 2, 255]), account: "hap.1")
        #expect(try store.read(account: "hap.1") == Data([0, 1, 2, 255]))
        try store.write(Data(), account: "empty")
        #expect(try store.read(account: "empty") == Data())
        try store.write(nil, account: "camera.1")
        #expect(try store.read(account: "camera.1") == nil)
        try store.write(nil, account: "camera.1")   // deleting a missing item is not an error
        #expect(try store.read(account: "hap.1") == Data([0, 1, 2, 255]))
    }

    @Test func aSecondStoreOnTheSameDirectoryReadsWhatTheFirstWrote() throws {
        let (store, directory) = try makeStore()
        defer { directory.remove() }
        try store.write(Data("shared".utf8), account: "a")
        #expect(try FileSecretStore(directory: directory.url).read(account: "a") == Data("shared".utf8))
    }

    @Test func theKeyFileIsPrivateRandomAndKeptAcrossWrites() throws {
        let (store, directory) = try makeStore()
        defer { directory.remove() }
        #expect(!FileManager.default.fileExists(atPath: store.keyURL.path(percentEncoded: false)), "reading creates no key")
        _ = try store.read(account: "x")
        #expect(!FileManager.default.fileExists(atPath: store.keyURL.path(percentEncoded: false)))
        try store.write(Data("a".utf8), account: "x")
        let key = try Data(contentsOf: store.keyURL)
        #expect(key.count == 32)
        try store.write(Data("b".utf8), account: "y")
        #expect(try Data(contentsOf: store.keyURL) == key)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: store.keyURL.path(percentEncoded: false))[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        let other = try makeStore()
        defer { other.1.remove() }
        try other.0.write(Data("a".utf8), account: "x")
        #expect(try Data(contentsOf: other.0.keyURL) != key, "every store has its own key")
    }

    @Test func theFilesHoldNoPlaintextAndAreOwnerOnly() throws {
        let (store, directory) = try makeStore()
        defer { directory.remove() }
        let secret = "correct horse battery staple"
        try store.write(Data(secret.utf8), account: "camera.7")
        let url = store.itemURL(account: "camera.7")
        let stored = try Data(contentsOf: url)
        #expect(stored.range(of: Data(secret.utf8)) == nil)
        #expect(!url.lastPathComponent.contains("camera"), "the account name is not in the file name")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        // The same secret sealed twice differs (a fresh nonce each time).
        try store.write(Data(secret.utf8), account: "camera.7")
        #expect(try Data(contentsOf: url) != stored)
    }

    @Test func aTamperedOrSwappedFileFailsInsteadOfReturningWrongData() throws {
        let (store, directory) = try makeStore()
        defer { directory.remove() }
        try store.write(Data("one".utf8), account: "a")
        try store.write(Data("two".utf8), account: "b")
        // Flip one byte of a's ciphertext.
        var damaged = try Data(contentsOf: store.itemURL(account: "a"))
        damaged[damaged.count - 20] ^= 0x01
        try damaged.write(to: store.itemURL(account: "a"))
        #expect(throws: FileSecretStore.Failure.self) { _ = try store.read(account: "a") }
        // b's file copied over a's place: authenticated by account, so it does not open as a.
        try Data(contentsOf: store.itemURL(account: "b")).write(to: store.itemURL(account: "a"))
        #expect(throws: FileSecretStore.Failure.self) { _ = try store.read(account: "a") }
        #expect(try store.read(account: "b") == Data("two".utf8))
    }

    @Test func aDamagedKeyFileIsNeverReplaced() throws {
        let (store, directory) = try makeStore()
        defer { directory.remove() }
        try store.write(Data("one".utf8), account: "a")
        try Data([1, 2, 3]).write(to: store.keyURL)
        let reopened = FileSecretStore(directory: directory.url)
        #expect(throws: FileSecretStore.Failure.invalidKeyFile) { _ = try reopened.read(account: "a") }
        #expect(throws: FileSecretStore.Failure.invalidKeyFile) { try reopened.write(Data("two".utf8), account: "b") }
        #expect(try Data(contentsOf: store.keyURL) == Data([1, 2, 3]))
    }

    @Test func theKeyLivesWhereTheOperatingSystemPutsIt() throws {
        let (store, directory) = try makeStore()
        defer { directory.remove() }
        #expect(store.keyURL.path(percentEncoded: false).hasSuffix("/secrets/master.key"))
        try store.write(Data("x".utf8), account: "a")
        #expect(FileManager.default.fileExists(atPath: directory.url.appending(path: "secrets/master.key").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(path: "secrets.key").path(percentEncoded: false)))
        let folder = try #require(FileManager.default.attributesOfItem(atPath: store.itemsDirectory.path(percentEncoded: false))[.posixPermissions] as? Int)
        #expect(folder == 0o700, "the folder the store creates is as private as the image's")
    }

    @Test func aKeyTheImageCreatedIsUsed() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // What cb-firstboot does: secrets/ (0700) with master.key = 32 random bytes (0600).
        let folder = directory.url.appending(path: "secrets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = Data((0..<32).map { UInt8($0 &* 7 &+ 1) })
        let keyURL = folder.appending(path: "master.key")
        try key.write(to: keyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path(percentEncoded: false))
        let store = FileSecretStore(directory: directory.url)
        try store.write(Data("with the image key".utf8), account: "camera.1")
        #expect(try Data(contentsOf: keyURL) == key, "the image's key is never replaced")
        // The same secret opened by an independent implementation of the format: AES-256-GCM, account as authenticated data.
        let stored = try Data(contentsOf: store.itemURL(account: "camera.1"))
        let box = try AES.GCM.SealedBox(combined: stored.dropFirst())
        #expect(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data("camera.1".utf8)) == Data("with the image key".utf8))
        #expect(try FileSecretStore(directory: directory.url).read(account: "camera.1") == Data("with the image key".utf8))
    }

    @Test func anOldKeyFileIsMovedToTheNewPlace() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let key = Data((0..<32).map { UInt8($0) })
        let legacy = directory.url.appending(path: "secrets.key")
        // An item sealed with the old key, in the old folder layout (the items folder was already `secrets/`).
        let folder = directory.url.appending(path: "secrets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let account = "camera.old"
        let probe = FileSecretStore(directory: directory.url)
        let sealed = try AES.GCM.seal(Data("old secret".utf8), using: SymmetricKey(data: key), authenticating: Data(account.utf8))
        try (Data([1]) + #require(sealed.combined)).write(to: probe.itemURL(account: account))
        try key.write(to: legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.path(percentEncoded: false))

        let store = FileSecretStore(directory: directory.url)
        #expect(try store.read(account: account) == Data("old secret".utf8), "secrets written by an earlier version still open")
        #expect(try Data(contentsOf: store.keyURL) == key)
        #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)), "the old file is gone")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: store.keyURL.path(percentEncoded: false))[.posixPermissions] as? Int)
        #expect(mode == 0o600)
    }

    @Test func whenBothKeysExistTheImagesWinsAndTheOldOneIsKept() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = directory.url.appending(path: "secrets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imageKey = Data(repeating: 0xAA, count: 32), oldKey = Data(repeating: 0xBB, count: 32)
        try imageKey.write(to: folder.appending(path: "master.key"))
        try oldKey.write(to: directory.url.appending(path: "secrets.key"))
        let store = FileSecretStore(directory: directory.url)
        try store.write(Data("v".utf8), account: "a")
        #expect(try Data(contentsOf: store.keyURL) == imageKey)
        #expect(try Data(contentsOf: directory.url.appending(path: "secrets.key")) == oldKey)
    }

    @Test func concurrentFirstWritesAgreeOnOneKey() async throws {
        let (store, directory) = try makeStore()
        defer { directory.remove() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 { group.addTask { try store.write(Data("v\(index)".utf8), account: "acct.\(index)") } }
            try await group.waitForAll()
        }
        for index in 0..<8 { #expect(try store.read(account: "acct.\(index)") == Data("v\(index)".utf8)) }
    }
}

@Suite struct LinuxInstanceLockTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "InstanceLockTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func aSecondHolderOfTheSameDirectoryIsRefusedUntilTheFirstReleases() {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = LinuxInstanceLock()
        let second = LinuxInstanceLock()
        #expect(first.acquire(directory: directory) == nil)
        #expect(first.acquire(directory: directory) == nil, "idempotent for the holder")
        let refusal = second.acquire(directory: directory)
        #expect(refusal?.contains("already running") == true)
        first.release()
        #expect(second.acquire(directory: directory) == nil, "free once the first copy released it")
        second.release()
        second.release()   // idempotent
    }

    @Test func aCopyWithItsOwnDirectoryIsNotAffected() {
        let a = directory(), b = directory()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let first = LinuxInstanceLock()
        let second = LinuxInstanceLock()
        #expect(first.acquire(directory: a) == nil)
        #expect(second.acquire(directory: b) == nil)
        first.release()
        second.release()
    }

    @Test func aHolderThatGoesAwayFreesTheLock() {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let gone = LinuxInstanceLock()
            #expect(gone.acquire(directory: directory) == nil)
        }
        let next = LinuxInstanceLock()
        #expect(next.acquire(directory: directory) == nil)
        next.release()
    }
}

@Suite struct LinuxPowerManagerTests {
    @Test func theCallsDoNothingAndAreIdempotent() {
        let power = LinuxPowerManager()
        power.beginBackgroundActivity(reason: "tests")
        power.beginBackgroundActivity(reason: "tests again")
        power.endBackgroundActivity()
        power.setKeepSystemAwake(true, reason: "tests")
        power.setKeepSystemAwake(false, reason: "tests")
    }

    @Test func aBatteryUnderPowerSupplyMakesItALaptop() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        #expect(!LinuxPowerManager(powerSupplyDirectory: directory.url).hasBattery, "an empty folder: no battery")
        for (name, type) in [("AC", "Mains"), ("ups0", "UPS")] {
            try FileManager.default.createDirectory(at: directory.url.appending(path: name), withIntermediateDirectories: true)
            try Data("\(type)\n".utf8).write(to: directory.url.appending(path: name).appending(path: "type"))
        }
        #expect(!LinuxPowerManager(powerSupplyDirectory: directory.url).hasBattery, "mains and a UPS are not a battery")
        try FileManager.default.createDirectory(at: directory.url.appending(path: "BAT0"), withIntermediateDirectories: true)
        try Data("Battery\n".utf8).write(to: directory.url.appending(path: "BAT0").appending(path: "type"))
        #expect(LinuxPowerManager(powerSupplyDirectory: directory.url).hasBattery)
        #expect(!LinuxPowerManager(powerSupplyDirectory: directory.url.appending(path: "missing")).hasBattery)
    }
}

/// The helper launcher with small system programs: output, exit, environment, ending, and the leftover-process cleanup.
@Suite(.timeLimit(.minutes(1)), .serialized) struct ProcessHelperLauncherTests {
    private let launcher = ProcessHelperLauncher(searchDirectories: [URL(filePath: "/bin", directoryHint: .isDirectory),
                                                                      URL(filePath: "/usr/bin", directoryHint: .isDirectory)])

    private func collect(_ helper: any HelperProcess) async -> [String] {
        var lines: [String] = []
        for await line in helper.output { lines.append(line) }
        return lines
    }

    private func shell(_ script: String, environment: [String: String] = [:], pidFile: URL? = nil) throws -> any HelperProcess {
        try launcher.launch(HelperLaunchSpec(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script], environment: environment, pidFile: pidFile))
    }

    @Test func locateFindsOnlyExecutablesByPlainName() {
        #expect(launcher.locate("sh") != nil)
        #expect(launcher.locate("env")?.lastPathComponent == "env")
        #expect(launcher.locate("definitely-not-installed") == nil)
        #expect(launcher.locate("../bin/sh") == nil && launcher.locate("") == nil && launcher.locate("/bin/sh") == nil)
        #expect(ProcessHelperLauncher(searchDirectories: []).locate("sh") == nil)
    }

    @Test func outputIsDeliveredLineByLineWithStdoutAndStderrTogether() async throws {
        let helper = try shell("echo one; echo two 1>&2; printf 'no newline at the end'; exit 3")
        let lines = await collect(helper)
        #expect(lines == ["one", "two", "no newline at the end"])
        let exit = await helper.waitUntilExit()
        #expect(exit == HelperExit(status: 3, reason: .exited))
        #expect(await helper.waitUntilExit() == exit, "waiting again returns the same answer")
    }

    @Test func aLongLineIsClipped() async throws {
        let helper = try shell("head -c 5000 /dev/zero | tr '\\0' 'x'; echo")
        let lines = await collect(helper)
        #expect(lines.count == 1 && lines[0].count == HelperOutput.maximumLineLength + 1 && lines[0].hasSuffix("…"))
    }

    @Test func theHelperGetsOnlyWhatItIsGiven() async throws {
        setenv("CB_TEST_SECRET_LEAK", "leaked", 1)
        defer { unsetenv("CB_TEST_SECRET_LEAK") }
        let env = try #require(launcher.locate("env"))
        let helper = try launcher.launch(HelperLaunchSpec(executable: env, environment: ["CB_GIVEN": "yes"]))
        let lines = await collect(helper)
        _ = await helper.waitUntilExit()
        #expect(lines.contains("CB_GIVEN=yes") && lines.contains { $0.hasPrefix("PATH=") })
        #expect(!lines.joined().contains("CB_TEST_SECRET_LEAK") && !lines.joined().contains("leaked"))
        #expect(!lines.contains { $0.hasPrefix("HOME=") || $0.hasPrefix("USER=") }, "\(lines)")
    }

    @Test func standardInputIsClosed() async throws {
        let helper = try shell("cat; echo cat-ended")
        #expect(await collect(helper) == ["cat-ended"])
    }

    @Test func terminateEndsAHelperWithSIGTERM() async throws {
        let sleep = try #require(launcher.locate("sleep"))
        let helper = try launcher.launch(HelperLaunchSpec(executable: sleep, arguments: ["30"]))
        #expect(helper.processID != nil)
        helper.terminate()
        let exit = await helper.waitUntilExit()
        #expect(exit == HelperExit(status: 15, reason: .signaled))
        helper.terminate()   // idempotent
        helper.kill()
    }

    @Test func killEndsAHelperThatIgnoresSIGTERM() async throws {
        let helper = try shell("trap '' TERM; while true; do sleep 0.1; done")
        try await Task.sleep(for: .milliseconds(300))
        helper.terminate()
        try await Task.sleep(for: .milliseconds(400))
        let stillRunning = !(await helperHasExited(helper))
        #expect(stillRunning, "SIGTERM was ignored")
        helper.kill()
        let exit = await helper.waitUntilExit()
        #expect(exit == HelperExit(status: 9, reason: .signaled))
    }

    @Test func aMissingProgramIsReportedWithoutItsPath() throws {
        do {
            _ = try launcher.launch(HelperLaunchSpec(executable: URL(filePath: "/nonexistent/secret-folder/go2rtc")))
            Issue.record("launched")
        } catch let error as HelperLaunchError {
            guard case .unavailable(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(!message.contains("secret-folder"))
        }
    }

    @Test func pidFileAndLeftoverCleanup() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let sleep = try #require(launcher.locate("sleep"))
        let pidFile = directory.file("helper.pid")
        let helper = try launcher.launch(HelperLaunchSpec(executable: sleep, arguments: ["30"], pidFile: pidFile))
        let written = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int32(written) == helper.processID)
        let attributes = try FileManager.default.attributesOfItem(atPath: pidFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        // A different program at that number is left alone (the number may belong to anything by now).
        let other = ProcessHelperLauncher(searchDirectories: [])
        #expect(!other.endStaleProcess(pidFile: pidFile, executable: URL(filePath: "/bin/sh")))
        #expect(!FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)), "the file is removed either way")
        #expect(!(await helperHasExited(helper)))

        // The same program: a helper left behind by a crashed daemon is ended.
        try Data("\(written)\n".utf8).write(to: pidFile)
        #expect(other.endStaleProcess(pidFile: pidFile, executable: sleep))
        let exit = await helper.waitUntilExit()
        #expect(exit.reason == .signaled)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)))
    }

    @Test func leftoverCleanupIgnoresNonsense() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let other = ProcessHelperLauncher(searchDirectories: [])
        let pidFile = directory.file("x.pid")
        #expect(!other.endStaleProcess(pidFile: pidFile, executable: URL(filePath: "/bin/sleep")))   // no file
        for text in ["", "abc", "0", "1", "-5", "99999999999", "4999999"] {
            try Data(text.utf8).write(to: pidFile)
            #expect(!other.endStaleProcess(pidFile: pidFile, executable: URL(filePath: "/bin/sleep")), "\(text)")
            #expect(!FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)))
        }
    }

    /// Whether the helper ended within a moment. A deadline, not a task group: a group waits for `waitUntilExit`, which only returns
    /// when the process ends.
    private func helperHasExited(_ helper: any HelperProcess) async -> Bool {
        let exited = Box(false)
        let waiter = Task { _ = await helper.waitUntilExit(); exited.set(true) }
        defer { waiter.cancel() }
        return await eventually(timeout: .milliseconds(150)) { exited.value }
    }
}

@Suite struct InterfaceAddressesTests {
    private func kernel(index: UInt32 = 2, _ text: String, prefix: Int = 64, flags: UInt32 = 0) -> KernelAddress {
        var bytes = [UInt8](repeating: 0, count: 16)
        if text.contains(":") {
            _ = inet_pton(AF_INET6, text, &bytes)
            return KernelAddress(interfaceIndex: index, family: AF_INET6, prefixLength: prefix, flags: flags, bytes: bytes)
        }
        var four = [UInt8](repeating: 0, count: 4)
        _ = inet_pton(AF_INET, text, &four)
        return KernelAddress(interfaceIndex: index, family: AF_INET, prefixLength: prefix, flags: flags, bytes: four)
    }

    @Test func onlyEthernetAndWiFiInterfacesCarryTheLAN() {
        for name in ["eth0", "eno1", "enp3s0", "ens18", "wlan0", "wlp2s0"] { #expect(InterfaceAddresses.isLANInterface(name), "\(name)") }
        for name in ["lo", "docker0", "veth1a2b", "br-12ab", "virbr0", "tun0", "wg0", "tailscale0", "bond0"] {
            #expect(!InterfaceAddresses.isLANInterface(name), "\(name)")
        }
    }

    /// Field report 2026-10-04 (macOS): two unique local /64 addresses (a home hub's Thread prefix) flipped deprecated on every
    /// router advertisement, and every flip counted as a network change. Same noise on Linux.
    @Test func theSnapshotKeepsStableAddressesOnly() {
        let names: [UInt32: String] = [1: "lo", 2: "eth0", 3: "docker0", 4: "wlan0"]
        let running: Set<String> = ["lo", "eth0", "docker0"]   // wlan0 has no carrier
        let found = InterfaceAddresses.stable(kernel: [
            kernel(index: 1, "127.0.0.1", prefix: 8),
            kernel(index: 2, "192.0.2.69", prefix: 24),
            kernel(index: 2, "2001:db8:4:7000::1", flags: KernelAddress.deprecated),     // deprecation flips: kept
            kernel(index: 2, "2001:db8:4:7000:aaaa::2", flags: KernelAddress.temporary),  // privacy address: left out
            kernel(index: 2, "2001:db8:4:7000:bbbb::3", flags: KernelAddress.tentative),  // duplicate detection running: left out
            kernel(index: 2, "fd00:db8:a:b::1"),                                          // unique local (Thread): left out
            kernel(index: 2, "fe80::1"),                                                  // link-local: left out
            kernel(index: 3, "198.51.100.1", prefix: 16),                                 // container bridge: left out
            kernel(index: 4, "203.0.113.9", prefix: 24),                                  // no carrier: left out
        ], names: names, running: running)
        #expect(found.map(\.description) == ["eth0 192.0.2.69/24", "eth0 2001:db8:4:7000::1/64"])
        #expect(found.map(\.isIPv6) == [false, true])
    }

    @Test func theSnapshotIsSorted() {
        let found = InterfaceAddresses.stable(kernel: [kernel(index: 2, "192.0.2.70", prefix: 24), kernel(index: 2, "192.0.2.5", prefix: 24)],
                                              names: [2: "eth0"], running: ["eth0"])
        #expect(found.map(\.address) == ["192.0.2.5", "192.0.2.70"])
    }

    @Test func theLiveSnapshotIsStableAndOnlyHoldsLANInterfaces() {
        let addresses = InterfaceAddresses.stable()
        #expect(addresses.allSatisfy { InterfaceAddresses.isLANInterface($0.interface) })
        #expect(addresses.allSatisfy { !$0.address.lowercased().hasPrefix("fe80") })
        #expect(InterfaceAddresses.stable() == addresses, "stable between two reads")
    }

    @Test func theKernelAddressDumpListsLoopback() {
        let loopback = Netlink.dumpAddresses().filter { $0.family == AF_INET && $0.bytes == [127, 0, 0, 1] }
        #expect(loopback.count == 1 && loopback[0].prefixLength == 8)
    }

    @Test func gatewaysCountOnlyOnNetworksALANInterfaceIsOn() {
        let held = [InterfaceAddress(interface: "eth0", address: "192.0.2.69", prefixLength: 24, isIPv6: false),
                    InterfaceAddress(interface: "eth0", address: "2001:db8:4:7000:40b:e3c3:fe43:6f1d", prefixLength: 64, isIPv6: true)]
        #expect(InterfaceAddresses.isOnLink("192.0.2.1", among: held))
        #expect(!InterfaceAddresses.isOnLink("10.8.0.1", among: held), "a VPN's gateway")
        #expect(InterfaceAddresses.isOnLink("2001:db8:4:7000::1", among: held))
        #expect(!InterfaceAddresses.isOnLink("2001:db8::1", among: held))
        #expect(InterfaceAddresses.isOnLink("fe80::1", among: held))
        #expect(!InterfaceAddresses.isOnLink("192.0.2.1", among: []))
    }
}

@Suite(.timeLimit(.minutes(1))) struct NetlinkNetworkChangeMonitorTests {
    private func addresses(_ list: String...) -> NetworkSignature {
        NetworkSignature(addresses: list, gateway: nil)
    }

    @Test func filterIgnoresTheInitialStateAndRepeats() {
        var filter = NetworkChangeFilter()
        let sequence = [addresses("eth0 192.0.2.5/24"), addresses("eth0 192.0.2.5/24"), addresses("eth0 192.0.2.6/24"),
                        addresses("eth0 192.0.2.6/24", "eth0 2001:db8::1/64"), addresses("eth0 2001:db8::1/64", "eth0 192.0.2.6/24"), addresses()]
        var results: [Bool] = []
        for signature in sequence { results.append(filter.isChange(signature)) }
        #expect(results == [false, false, true, true, false, true])
        var first = NetworkChangeFilter()
        let initial = first.isChange(NetworkSignature(addresses: [], gateway: "192.0.2.1"))
        #expect(!initial)
        var gateway = NetworkChangeFilter()
        _ = gateway.isChange(NetworkSignature(addresses: ["eth0 192.0.2.5/24"], gateway: "192.0.2.1"))
        let moved = gateway.isChange(NetworkSignature(addresses: ["eth0 192.0.2.5/24"], gateway: "192.0.2.254"))
        #expect(moved, "another router on the same network")
    }

    @Test func cancelFinishesSubscriptions() async {
        let monitor = NetlinkNetworkChangeMonitor()
        let first = monitor.changes
        let second = monitor.changes
        monitor.cancel()
        for await _ in first {}
        for await _ in second {}
        var late = 0
        for await _ in monitor.changes { late += 1 }   // subscribing after cancel finishes immediately
        #expect(late == 0)
    }

    /// A real kernel event: a dummy `en*` interface gets an address. Needs `ip` and CAP_NET_ADMIN (Tools/linux-test.sh grants it);
    /// elsewhere the test does nothing.
    @Test func anAddressOnALANInterfaceIsAChangeAndOneOnAContainerBridgeIsNot() async throws {
        guard Self.ip(["link", "add", "endummy0", "type", "dummy"]) else { return }
        defer { _ = Self.ip(["link", "del", "endummy0"]); _ = Self.ip(["link", "del", "dockdummy0"]) }
        #expect(Self.ip(["link", "set", "endummy0", "up"]))
        let monitor = NetlinkNetworkChangeMonitor()
        defer { monitor.cancel() }
        let received = Box(0)
        let watcher = Task { for await _ in monitor.changes { received.update { $0 += 1 } } }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(300))   // subscribed

        // Noise: an interface that does not carry the LAN.
        #expect(Self.ip(["link", "add", "dockdummy0", "type", "dummy"]))
        #expect(Self.ip(["link", "set", "dockdummy0", "up"]))
        #expect(Self.ip(["addr", "add", "198.51.100.1/24", "dev", "dockdummy0"]))
        try await Task.sleep(for: .milliseconds(800))
        #expect(received.value == 0, "a container bridge's address is no network change")

        #expect(Self.ip(["addr", "add", "198.51.100.7/24", "dev", "endummy0"]))
        #expect(await eventually(timeout: .seconds(3)) { received.value >= 1 })
        let afterAdd = received.value
        #expect(Self.ip(["addr", "del", "198.51.100.7/24", "dev", "endummy0"]))
        #expect(await eventually(timeout: .seconds(3)) { received.value > afterAdd })
    }

    private static func ip(_ arguments: [String]) -> Bool {
        let process = Process()
        guard let ip = ["/usr/sbin/ip", "/sbin/ip", "/usr/bin/ip", "/bin/ip"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        process.executableURL = URL(filePath: ip)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

@Suite struct DNSSDTests {
    @Test func encodesTXTRecords() throws {
        #expect(try DNSSDServiceAdvertiser.txtRecord([:]) == Data())
        #expect(try DNSSDServiceAdvertiser.txtRecord(["md": "Cam", "c#": "2"]) == Data([4, 99, 35, 61, 50] + [6, 109, 100, 61, 67, 97, 109]))
        #expect(throws: TransportError.self) { _ = try DNSSDServiceAdvertiser.txtRecord(["bad=key": "v"]) }
        #expect(throws: TransportError.self) { _ = try DNSSDServiceAdvertiser.txtRecord(["": "v"]) }
        #expect(throws: TransportError.self) { _ = try DNSSDServiceAdvertiser.txtRecord(["k": String(repeating: "x", count: 300)]) }
    }

    @Test func parsesTXTRecords() throws {
        let record = try DNSSDServiceAdvertiser.txtRecord(["id": "AA:BB", "sf": "1", "empty": ""])
        #expect(DNSSDServiceBrowser.parseTXT([UInt8](record)) == ["id": "AA:BB", "sf": "1", "empty": ""])
        #expect(DNSSDServiceBrowser.parseTXT([4, 102, 108, 97, 103]) == ["flag": ""], "a key without a value")
        #expect(DNSSDServiceBrowser.parseTXT([9, 97]).isEmpty, "a length past the end is dropped")
        #expect(DNSSDServiceBrowser.parseTXT([]).isEmpty)
    }

    @Test func aRenamedInstanceIsTheSameService() {
        #expect(DNSSDServiceBrowser.isInstance("Driveway", of: "Driveway"))
        #expect(DNSSDServiceBrowser.isInstance("Driveway #2", of: "Driveway"))
        #expect(DNSSDServiceBrowser.isInstance("Driveway (12)", of: "Driveway"))
        #expect(!DNSSDServiceBrowser.isInstance("Driveway #x", of: "Driveway"))
        #expect(!DNSSDServiceBrowser.isInstance("Driveway ()", of: "Driveway"))
        #expect(!DNSSDServiceBrowser.isInstance("Driveway Cam", of: "Driveway"))
        #expect(!DNSSDServiceBrowser.isInstance("Front Door", of: "Driveway"))
    }

    /// No avahi-daemon in the test container: registering fails with an error (not a crash or a hang), browsing says it cannot
    /// run. With a daemon the same calls succeed, so only the shape of the answer is checked.
    @Test func withoutADaemonAdvertisingThrowsAndBrowsingIsUnavailable() async {
        let advertisement = ServiceAdvertisement(name: "Test \(UUID().uuidString.prefix(8))", type: "_cbtest._tcp", port: 51_999, txt: ["a": "b"])
        let service = try? await DNSSDServiceAdvertiser().advertise(advertisement)
        defer { service?.cancel() }
        let lookup = await DNSSDServiceBrowser().lookup(type: "_cbtest._tcp", name: "nobody-\(UUID().uuidString.prefix(8))", timeout: .seconds(1))
        switch lookup {
        case .unavailable, .notFound: break
        case .found: Issue.record("found a service nobody advertised")
        }
    }

    @Test func rejectsAnUnknownInterfaceScope() async {
        await #expect(throws: TransportError.self) {
            _ = try await DNSSDServiceAdvertiser(scope: .interface("nonexistent9")).advertise(
                ServiceAdvertisement(name: "x", type: "_cbtest._tcp", port: 1, txt: [:]))
        }
    }
}

@Suite struct LinuxPlatformServicesTests {
    @Test func servicesWireTheLinuxImplementations() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let services = LinuxPlatform.services(dataDirectory: directory.url)
        #expect(services.transport is LinuxNetworkTransport)
        #expect(services.advertiser is DNSSDServiceAdvertiser)
        #expect(services.secrets is FileSecretStore)
        #expect(services.networkChanges is NetlinkNetworkChangeMonitor)
        #expect(services.power is LinuxPowerManager)
        #expect(services.browser is DNSSDServiceBrowser)
        #expect(services.instanceLock is LinuxInstanceLock)
        #expect(services.helpers is ProcessHelperLauncher)
        (services.networkChanges as? NetlinkNetworkChangeMonitor)?.cancel()
    }

    @Test func unavailableCodecsThrowUnsupported() {
        let codecs = UnavailableMediaCodecs()
        #expect(throws: MediaCodecError.self) { _ = try codecs.resizeJPEG(Data(), maxWidth: 1, maxHeight: 1) }
    }
}
#endif
