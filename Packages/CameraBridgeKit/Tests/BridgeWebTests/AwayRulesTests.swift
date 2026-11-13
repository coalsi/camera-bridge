import BridgeEngine
import BridgeSupport
import Foundation
import Testing
@testable import BridgeWeb

/// A generator that repeats one sequence, so a test can draw the same numbers again.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        // SplitMix64: small, and good enough to spread 2,000 draws over 256 values.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite(.timeLimit(.minutes(1))) struct AwayRulesTests {
    static func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! }
    }

    static func global(_ address: String, _ lifetime: UInt32, temporary: Bool = false, deprecated: Bool = false) -> AwayAddress {
        AwayAddress(address: address, prefixLength: 64, preferredLifetime: lifetime, isTemporary: temporary, isDeprecated: deprecated)
    }

    @Test func theSubnetAvoidsTheReservedAndTheHomesOwnNetworks() {
        var generator = SeededGenerator(state: 7)
        // The third entry is how the network reports a prefix ("address/length"): its second octet counts too.
        let avoided = ["10.77.3.9", "192.0.2.4", "10.200.1.20", "10.88.0.7/16"]
        var seenSecondOctets = Set<Int>()
        for _ in 0..<2_000 {
            let subnet = AwayRules.chooseSubnet(avoiding: avoided, using: &generator)
            #expect(subnet.wholeMatch(of: /10\.\d{1,3}\.\d{1,3}\.0\/24/) != nil)
            let octet = Int(subnet.split(separator: ".")[1])!
            seenSecondOctets.insert(octet)
            #expect(![0, 1, 10, 42, 77, 88, 200, 255].contains(octet))
        }
        #expect(seenSecondOctets.count > 200)
    }

    @Test func devicesGetTwoToTwoFiftyFour() {
        let subnet = "10.77.12.0/24"
        #expect(AwayRules.boxAddress(subnet: subnet) == "10.77.12.1")
        #expect(AwayRules.nextDeviceAddress(subnet: subnet, taken: []) == "10.77.12.2")
        #expect(AwayRules.nextDeviceAddress(subnet: subnet, taken: ["10.77.12.2", "10.77.12.3"]) == "10.77.12.4")
        #expect(AwayRules.nextDeviceAddress(subnet: subnet, taken: ["10.77.12.2", "10.77.12.4"]) == "10.77.12.3")
        #expect(AwayRules.nextDeviceAddress(subnet: subnet, taken: (2...254).map { "10.77.12.\($0)" }) == nil)
    }

    // The box's own addresses here are in 3fff:1000::/36, since the website refuses the documentation prefixes (2001:db8::/32 and 3fff::/20)
    // like every range `AwayRules.websiteTakes` leaves out: 3fff:1000:: lies just past 3fff::/20, in space IANA has given to nobody.
    @Test func theStableAddressSticksWhileItQualifies() {
        let first = Self.global("3fff:1000:4:7000::1", 600), second = Self.global("3fff:1000:4:7000::2", 86_400)
        #expect(AwayRules.stableAddress(among: [first, second], previous: "3fff:1000:4:7000::1")?.address == "3fff:1000:4:7000::1")
        // The previous address is found by its text, not by the whole value: the system's lifetime counts down on every read.
        let later = Self.global("3fff:1000:4:7000::1", 300)
        #expect(later != first)
        #expect(AwayRules.stableAddress(among: [later, second], previous: first.address) == later)
        // A deprecated previous address no longer qualifies.
        #expect(AwayRules.stableAddress(among: [Self.global("3fff:1000:4:7000::1", 600, deprecated: true), second], previous: "3fff:1000:4:7000::1")?.address == "3fff:1000:4:7000::2")
        // A temporary address never wins, however long it lasts.
        #expect(AwayRules.stableAddress(among: [Self.global("3fff:1000:4:7000::9", 604_800, temporary: true), second], previous: nil)?.address == "3fff:1000:4:7000::2")
        #expect(AwayRules.stableAddress(among: [Self.global("3fff:1000:4:7000::9", 604_800, temporary: true)], previous: "3fff:1000:4:7000::9") == nil)
        #expect(AwayRules.stableAddress(among: [second, Self.global("3fff:1000:4:7000::3", .max)], previous: nil)?.address == "3fff:1000:4:7000::3")
        #expect(AwayRules.stableAddress(among: [Self.global("fd00::1", .max), Self.global("fe80::1", .max)], previous: nil) == nil)
        #expect(AwayRules.stableAddress(among: [], previous: nil) == nil)
        #expect(AwayRules.stableAddress(among: [], previous: "3fff:1000:4:7000::1") == nil)
        #expect(AwayRules.stableAddress(among: [Self.global("3fff:1000:4:7000::3", 86_400), second], previous: nil)?.address == "3fff:1000:4:7000::2")
    }

    /// An address the website refuses would be refused at every send, so a box whose longest-lived address is one of them falls back to its
    /// other address, and one that has no other has none to publish (the card's "no IPv6").
    @Test func onlyAnAddressTheWebsiteTakesIsChosen() {
        let sixToFour = Self.global("2002:c000:204::1", .max), home = Self.global("3fff:1000:4:7000::1", 600)
        #expect(AwayRules.stableAddress(among: [sixToFour, home], previous: nil) == home)
        #expect(AwayRules.stableAddress(among: [sixToFour, home], previous: sixToFour.address) == home, "not even as the address sent before")
        #expect(AwayRules.stableAddress(among: [Self.global("2001:db8:4:7000::1", .max), Self.global("2001:0:4136:e378::1", .max), home], previous: nil) == home)
        #expect(AwayRules.stableAddress(among: [sixToFour], previous: nil) == nil)
    }

    /// The website's own ranges, at their edges (its verify.ts: 2000::/3 less 2001::/23, 2001:db8::/32, 2002::/16 and 3fff::/20).
    @Test func theWebsitesRangesAtTheirEdges() throws {
        let taken = ["2000::", "2001:200::", "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db9::", "2001:ffff::1", "2003::",
                     "3ffe::1", "3fff:1000::", "3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"]
        let refused = ["2001::", "2001::1", "2001:0:4136:e378::1", "2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db8::", "2001:db8:ffff::1",
                       "2002::", "2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "3fff::", "3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff",
                       "1fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "4000::", "::1", "fd00::1", "fe80::1", "ff02::1", "::ffff:192.0.2.1"]
        for address in taken {
            #expect(AwayRules.websiteTakes(try #require(StreamAddress.addressBytes(address), "\(address)")), "\(address)")
        }
        for address in refused {
            #expect(!AwayRules.websiteTakes(try #require(StreamAddress.addressBytes(address), "\(address)")), "\(address)")
        }
        #expect(!AwayRules.websiteTakes([0x20, 0x01]), "not an address")
    }

    @Test func fromAwayIsNeitherTheHomesPrefixesNorPrivate() {
        let own = ["192.0.2.0/24", "2001:db8:4:7000::/64"]
        for address in ["2001:db8:99::1", "198.51.100.7"] {
            #expect(AwayRules.isFromAway(address, ownPrefixes: own), "\(address)")
        }
        let notAway: [String?] = ["2001:db8:4:7000::99", "192.0.2.50", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.5", "100.64.1.1",
                                  "169.254.1.1", "127.0.0.1", "fd00::1", "fe80::1", "::1", "::", "::ffff:192.168.1.5", nil, "", "[2001:db8:99::1]:51820"]
        for address in notAway {
            #expect(!AwayRules.isFromAway(address, ownPrefixes: own), "\(address ?? "nil")")
        }
        // Just outside the private ranges.
        #expect(AwayRules.isFromAway("172.32.0.1", ownPrefixes: own))
        #expect(AwayRules.isFromAway("100.128.0.1", ownPrefixes: own))
    }

    @Test func theCardStatesFollowTheSpec() {
        let earlier = Date(timeIntervalSince1970: 1_792_224_000), later = earlier.addingTimeInterval(60)
        let address = "2001:db8:4:7000::1"
        func state(on: Bool = true, checked: Bool = true, problem: String? = nil, address: String? = address, lastAway: Date? = earlier, changed: Date? = nil) -> String {
            AwayRules.cardState(on: on, checked: checked, problem: problem, address: address, lastAway: lastAway, addressChangedAt: changed)
        }
        #expect(state(on: false) == "off")
        #expect(state(on: false, problem: "x") == "problem")
        #expect(state(problem: "x") == "problem")
        #expect(state(checked: false) == "checking")
        #expect(state(checked: false, address: nil) == "checking")
        #expect(state(address: nil) == "no_ipv6")
        #expect(state(lastAway: nil) == "setup")
        #expect(state(lastAway: nil, changed: later) == "setup")
        #expect(state(lastAway: earlier, changed: later) == "address_changed")
        // A handshake newer than the change means the phone has found the box at its new address.
        #expect(state(lastAway: later, changed: earlier) == "working")
        #expect(state(lastAway: earlier, changed: earlier) == "working")
        #expect(state(lastAway: earlier, changed: nil) == "working")
    }

    @Test func theConfigIsWhatTheWireGuardAppReads() {
        let text = AwayRules.wireGuardConfig(privateKey: "PRIVATE=", address: "10.77.12.2", boxPublicKey: "BOXPUBLIC=",
                                             endpoint: "[2001:db8:4:7000::1]:51820", allowedIPs: ["10.77.12.1/32", "192.0.2.10/32"])
        #expect(text == """
        [Interface]
        PrivateKey = PRIVATE=
        Address = 10.77.12.2/32
        MTU = 1280

        [Peer]
        PublicKey = BOXPUBLIC=
        AllowedIPs = 10.77.12.1/32, 192.0.2.10/32
        Endpoint = [2001:db8:4:7000::1]:51820

        """)
        #expect(!text.contains("DNS") && !text.contains("PersistentKeepalive"))
        #expect(AwayRules.endpoint(address: "2001:db8:4:7000::1") == "[2001:db8:4:7000::1]:51820")
        #expect(AwayRules.endpoint(address: nil) == nil)
        #expect(AwayRules.endpoint(address: "not an address") == nil)
        #expect(AwayRules.endpoint(address: "192.0.2.10") == nil)
    }

    /// The away name holds a TXT record, not an address one, so a WireGuard app that was given the name could not resolve it: the endpoint is
    /// the box's address itself, written the one way an address is written (the service's test shows it with the name known).
    @Test func theEndpointIsTheBoxsAddressNeverTheAwayName() {
        #expect(AwayRules.endpoint(address: "2001:0db8:0004:7000:0000:0000:0000:0001") == "[2001:db8:4:7000::1]:51820")
        #expect(AwayRules.endpoint(address: "[2001:db8:4:7000::1]") == "[2001:db8:4:7000::1]:51820")
    }

    @Test func aKeyPairIsAWireGuardKeyPair() throws {
        // RFC 7748 section 6.1: Alice's private key and the public key it gives.
        let pair = try #require(AwayKeyPair(privateKey: Data(Self.hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")).base64EncodedString()))
        #expect(Array(try #require(Data(base64Encoded: pair.publicKey))) == Self.hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))

        let fresh = AwayKeyPair()
        let bytes = Array(try #require(Data(base64Encoded: fresh.privateKey)))
        #expect(bytes.count == 32)
        #expect(bytes[0] & 7 == 0)
        #expect(bytes[31] & 0x80 == 0)
        #expect(bytes[31] & 0x40 != 0)
        #expect(AwayRequest.isPublicKey(fresh.privateKey))
        #expect(AwayRequest.isPublicKey(fresh.publicKey))
        #expect(AwayKeyPair(privateKey: fresh.privateKey)?.publicKey == fresh.publicKey)
        #expect(AwayKeyPair().privateKey != fresh.privateKey)
        #expect(AwayKeyPair(privateKey: "short") == nil)
        #expect(AwayKeyPair(privateKey: Data(count: 31).base64EncodedString()) == nil)
    }

    @Test func awayNamesAreOurs() {
        #expect(AwayRules.isAwayName("abcdefghij0123456789.away.camera-bridge.app"))
        #expect(!AwayRules.isAwayName("ABCDEFGHIJ0123456789.away.camera-bridge.app"))
        #expect(!AwayRules.isAwayName("abcdefghij0123456789.box.camera-bridge.app"))
        #expect(!AwayRules.isAwayName("abcdefghij01234.away.camera-bridge.app"))
        #expect(!AwayRules.isAwayName("abcdefghij.0123456789.away.camera-bridge.app"))
        #expect(!AwayRules.isAwayName("abcdefghij0123456789.away.example.test"))
    }

    @Test func namesAreCleanedAsTheBoxCleansADevicesName() {
        #expect(AwayRules.cleanedName("  Pixel\n") == "Pixel")
        #expect(AwayRules.cleanedName(" \n") == nil)
        #expect(AwayRules.cleanedName(nil) == nil)
        #expect(AwayRules.cleanedName(String(repeating: "a", count: 80))?.count == 60)
    }

    @Test func theStateSurvivesOlderAndDamagedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("away-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(AwayState.fileName)

        #expect(AwayState.load(from: directory) == AwayState())

        try Data(#"{"on":true}"#.utf8).write(to: file)
        var older = AwayState()
        older.on = true
        #expect(AwayState.load(from: directory) == older)

        try Data("not json".utf8).write(to: file)
        #expect(AwayState.load(from: directory) == AwayState())
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("away.json.unreadable").path))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // A file that is there but can't be read (a disk error, its permissions) is moved aside too, so the next save never writes over its
        // devices and away name. A folder in its place can't be read as a file by anyone, root included.
        let moved = directory.appendingPathComponent("away.json.unreadable")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("kept".utf8).write(to: file.appendingPathComponent("inside"))
        #expect(AwayState.load(from: directory) == AwayState())
        #expect(!FileManager.default.fileExists(atPath: file.path), "moved aside")
        #expect(FileManager.default.contents(atPath: moved.appendingPathComponent("inside").path) == Data("kept".utf8))
        try FileManager.default.removeItem(at: moved)
        // A file its permissions keep from being read (where they do: root reads it anyway).
        let unreadable = #"{"on":true,"name":"abcdefghij0123456789.away.camera-bridge.app"}"#
        try Data(unreadable.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        if !FileManager.default.isReadableFile(atPath: file.path) {
            #expect(AwayState.load(from: directory) == AwayState())
            #expect(!FileManager.default.fileExists(atPath: file.path), "moved aside")
            #expect(AwayState().save(to: directory), "a new state is saved beside it")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: moved.path)
            #expect(FileManager.default.contents(atPath: moved.path) == Data(unreadable.utf8), "and the old one is kept as it was")
        }
        try? FileManager.default.removeItem(at: file)

        let date = Date(timeIntervalSince1970: 1_792_224_000)
        var state = AwayState()
        state.on = true
        state.subnet = "10.77.12.0/24"
        state.name = "abcdefghij0123456789.away.camera-bridge.app"
        state.devices = [AwayDevice(id: "d1", kind: .wireguard, name: "Laptop", publicKey: "KEY=", address: "10.77.12.2", created: date, lastAwayAt: nil)]
        state.lastAddress = "2001:db8:4:7000::1"
        state.addressChangedAt = date
        state.changes = [AwayState.AddressChange(at: date, address: "2001:db8:4:7000::1")]
        state.publishedAddress = "2001:db8:4:7000::1"
        state.publishedAt = date
        state.withdrawPending = true
        state.websiteFailures = 3
        state.websiteWaitUntil = date.addingTimeInterval(600)
        state.applyPending = true
        state.applyError = "x"
        state.save(to: directory)
        #expect(AwayState.load(from: directory) == state)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
