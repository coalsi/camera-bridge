import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The internet guard's Watch (`CameraSettingsService+DNS.swift`) on a Dahua, Amcrest or Lorex camera, through the camera's own CGI before
/// ONVIF: these cameras' ONVIF `SetDNS` is known to be unreliable, and their `configManager.cgi` is the one their web page uses (Dahua HTTP
/// API, "Network": `table.Network.DefaultInterface`, `table.Network.<interface>.DnsServers[0|1]`). A reading is nil when the answer is not
/// Dahua's `table.` text (a web server's login page, a 404, a table without the DNS slots): the camera is then left to ONVIF.
///
/// - The DNS slots are editable while the camera is on DHCP (the web pages lock only the address, mask and gateway), and nothing else is
///   written: `setConfig` names the two slots and no other key, so the camera's address cannot change.
/// - The interface name and the servers go into the address of the change, so they are checked first: a plain interface name (letters, digits,
///   `_`, `-`; the camera reports it, and a backup can be edited) and IPv4 addresses, and nothing else is sent. Percent-encoding is left to
///   the URL builder, which encodes the brackets of `DnsServers[0]`.
/// - Every request goes through `AmcrestAPI`'s Digest client and the login guard (`ONVIFLoginGuard`, shared with ONVIF): a refused login
///   pauses the camera's logins and is thrown, never answered with ONVIF's.
extension AmcrestAPI {
    static let configPath = "/cgi-bin/configManager.cgi"
    /// Dahua cameras have two DNS slots; a table that shows more is read in full (every server a camera asks counts).
    static let maximumDNSSlots = 8

    /// A plain interface name (`eth0`, `eth2`, `wlan0`, `bond0`).
    static func isInterfaceName(_ name: String) -> Bool {
        (1...16).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The DNS slots of `interface` (the default interface when nil) in a `getConfig` answer for `Network`, in order, each as the camera
    /// shows it ("0.0.0.0" or "" for an emptied slot, a slot it does not show as ""); nil when the text is not that table (no
    /// `table.Network.DefaultInterface` for the default interface, an interface that is not a plain name, no DNS slot).
    static func parseNetworkDNS(_ text: String, interface wanted: String? = nil) -> (interface: String, servers: [String])? {
        let values = parseKeyValues(text)
        guard let interface = wanted ?? values["table.Network.DefaultInterface"], isInterfaceName(interface) else { return nil }
        let prefix = "table.Network.\(interface).DnsServers["
        var slots: [Int: String] = [:]
        for (key, value) in values where key.hasPrefix(prefix) && key.hasSuffix("]") {
            guard let index = Int(key.dropFirst(prefix.count).dropLast()), (0..<maximumDNSSlots).contains(index) else { continue }
            slots[index] = value
        }
        guard let last = slots.keys.max() else { return nil }
        return (interface, (0...last).map { slots[$0] ?? "" })
    }

    /// `getConfig` of `Network`: the DNS servers of the camera's default interface (`interface` nil) or of `interface`, as `parseNetworkDNS`
    /// reads them. nil when the answer is not Dahua's (any status but 2xx, HTML, a table without the slots). Throws the camera's login
    /// refusal, and the transport's errors (no answer).
    func networkDNS(interface wanted: String? = nil) async throws -> (interface: String, servers: [String])? {
        let query = [URLQueryItem(name: "action", value: "getConfig"), URLQueryItem(name: "name", value: "Network")]
        let reply = try await answer(Self.configPath, query: query)
        guard (200..<300).contains(reply.status) else { return nil }
        return Self.parseNetworkDNS(reply.text, interface: wanted)
    }

    /// `setConfig` of `Network.<interface>.DnsServers[0]`, `[1]` to `servers` (one or two IPv4 addresses, "0.0.0.0" for an empty slot): the
    /// camera answers "OK", or `AmcrestRefusal` with its words. An HTTP 403 is `.notPermitted` (the account signed in may not change it).
    /// Anything else is not sent: `CameraAdapterError.invalidResponse`.
    func setNetworkDNS(interface: String, servers: [String]) async throws {
        guard Self.isInterfaceName(interface), (1...2).contains(servers.count), servers.allSatisfy(ONVIFClient.isIPv4) else {
            throw CameraAdapterError.invalidResponse("not a DNS change this camera takes")
        }
        var query = [URLQueryItem(name: "action", value: "setConfig")]
        for (index, server) in servers.enumerated() { query.append(URLQueryItem(name: "Network.\(interface).DnsServers[\(index)]", value: server)) }
        let reply = try await answer(Self.configPath, query: query)
        if reply.status == 403 { throw CameraAdapterError.notPermitted("setConfig") }
        guard (200..<300).contains(reply.status), Self.isOK(reply.text) else {
            throw AmcrestRefusal(words: Self.refusalWords(status: reply.status, text: reply.text))
        }
    }

    /// The first line of the answer is "OK" (any case).
    static func isOK(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first(where: { !$0.isEmpty })?.lowercased() == "ok"
    }

    /// The camera's words for a change it did not make: its text on one line (at most 120 characters), or the status when it said none.
    static func refusalWords(status: Int, text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? "HTTP \(status)" : Redact.string(String(line.prefix(120)))
    }
}

/// A change the camera's CGI answered with something but "OK": its own words ("Error Bad Request!").
struct AmcrestRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    var words: String
    var description: String { words }
}

extension CameraSettingsService {
    static let dahuaDone = "via Dahua API"

    /// Why Restore leaves a backup's servers alone: a slot that is not an IPv4 address cannot be written back through the CGI.
    static let dahuaOldServersLeftAlone = "the camera’s old DNS servers can’t be written back through its own API (it takes IPv4 addresses), "
        + "so Camera Bridge left them as they are: set them on the camera"

    /// The servers of `slots` as a reading: the camera takes them as set whatever its addressing (DHCP does not lock the DNS fields), so
    /// `fromDHCP` is false; the backup keeps both slots as they are, and the interface they belong to.
    static func dahuaReading(interface: String, slots: [String]) -> CameraDNSReading {
        CameraDNSReading(servers: distinctServers(slots), fromDHCP: false, method: .dahuaCGI,
                         backup: CameraDNSBackup(method: .dahuaCGI, fromDHCP: false, servers: slots, dahuaInterface: interface))
    }

    /// The first two slots, a missing one empty.
    static func firstTwoSlots(_ slots: [String]) -> [String] { Array((slots + ["", ""]).prefix(2)) }

    /// `readDNS()` of a Dahua, Amcrest or Lorex camera: its default interface's servers through the CGI; nil when the camera does not
    /// answer it as Dahua's (ONVIF then). Throws the camera's login refusal and a cancellation.
    func readDahuaDNS() async throws -> CameraDNSReading? {
        guard let (interface, slots) = try await ownAPIRead({ try await self.amcrest().networkDNS() }) else { return nil }
        return Self.dahuaReading(interface: interface, slots: slots)
    }

    /// What the camera's CGI made of a change to its DNS (`applyDahuaDNS`).
    enum DahuaDNSResult: Sendable {
        /// The step is settled: done, not read back as written, or ended by the account (it may not make the change).
        case outcome(CameraSetupOutcome)
        /// The camera does not answer the CGI as Dahua's: ONVIF.
        case notDahua
        /// The camera's own API did not make the change: it refused it (an "Error", a 400), or said "OK" and, once the whole read-back had
        /// passed, showed none of the bridge's servers (it ignored the keys, or shows what it showed before). ONVIF follows, as before this
        /// API was used: Camera Bridge cannot know that every firmware reads the encoded brackets of `DnsServers%5B0%5D`. `why` is what a
        /// refusal by ONVIF too says after its own words.
        case declined(why: String)
    }

    static func dahuaRefusedWhy(_ words: String) -> String { "the camera’s own API refused the change (\(words))" }
    static let dahuaIgnoredWhy = "the camera’s own API said OK but kept its own DNS servers"

    /// Points a Dahua, Amcrest or Lorex camera's DNS at `server` through its CGI (`applyDNS`): the bridge in both slots of the default
    /// interface, read back while the camera may restart its network (no answer meanwhile is no refusal). Already done when both slots are
    /// the bridge. `.notDahua` when the camera does not answer the CGI as Dahua's, `.declined` when it refuses the change or shows none of
    /// the bridge's servers after it (ONVIF follows in all cases); a camera that shows the bridge beside a server it kept is refused in
    /// those words (it took the change), and one that never answers again is refused too; an account that may not make the change ends the
    /// step. Throws the camera's login refusal and a cancellation.
    func applyDahuaDNS(server: String, readBack: DNSReadBackTiming) async throws -> DahuaDNSResult {
        guard let (interface, slots) = try await ownAPIRead({ try await self.amcrest().networkDNS() }) else { return .notDahua }
        if Self.dahuaReading(interface: interface, slots: slots).pointsAt(server), Self.sameSlots(Self.firstTwoSlots(slots), [server, server]) {
            return .outcome(CameraSetupOutcome(succeeded: true, detail: Self.dahuaDone))
        }
        switch try await writeDahuaDNS(interface: interface, servers: [server, server]) {
        case .ended(let outcome)?: return .outcome(outcome)
        case .refused(let words)?: return .declined(why: Self.dahuaRefusedWhy(words))
        case nil: break
        }
        var last: CameraDNSReading?
        let done = try await readBackAfterRestart(readBack, immediately: true) {
            guard let (_, now) = try await self.amcrest().networkDNS(interface: interface) else { return false }
            let reading = Self.dahuaReading(interface: interface, slots: now)
            last = reading
            return reading.pointsAt(server)
        }
        guard !done else {
            log.info("Set the camera's DNS servers through its Dahua API")
            return .outcome(CameraSetupOutcome(succeeded: true, detail: Self.dahuaDone))
        }
        if let last, !last.servers.contains(where: { ONVIFClient.sameAddress($0, server) }) { return .declined(why: Self.dahuaIgnoredWhy) }
        return .outcome(.refused(Self.keptAfterRestart(last, server: server)))
    }

    /// ONVIF's refusal of the change, after the camera's own API had not made it first: `why` follows ONVIF's words. A change the account
    /// may not make keeps its own words (the camera's "Error" says nothing more there), and a success is as it was.
    static func afterDahuaRefusal(_ outcome: CameraSetupOutcome, _ why: String?) -> CameraSetupOutcome {
        guard let why, !outcome.succeeded, !outcome.notPermitted else { return outcome }
        return CameraSetupOutcome(succeeded: false, needsRestart: outcome.needsRestart, detail: "\(outcome.detail); \(why)")
    }

    /// Puts a Dahua, Amcrest or Lorex camera's two slots back as the backup has them (`restoreDNS`), on the interface the backup names, read
    /// back as `applyDahuaDNS` is. An empty slot goes back as 0.0.0.0. Nothing is written when the camera already has them. A camera whose
    /// own API refuses the change, or answers "OK" and shows its slots as they were after the whole read-back, gets it through ONVIF, as the
    /// run's change did (`restoreONVIFDNS`). nil when the backup names no interface or the camera does not answer the CGI as Dahua's.
    func restoreDahuaDNS(_ backup: CameraDNSBackup, readBack: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        guard let interface = backup.dahuaInterface else { return nil }
        var wanted: [String] = []
        for slot in Self.firstTwoSlots(backup.servers) {
            if CameraDNSReading.isEmptySlot(slot) { wanted.append("0.0.0.0") } else if ONVIFClient.isIPv4(slot) { wanted.append(slot) } else {
                return .refused(Self.dahuaOldServersLeftAlone)
            }
        }
        guard let (_, slots) = try await ownAPIRead({ try await self.amcrest().networkDNS(interface: interface) }) else { return nil }
        if !Self.sameSlots(Self.firstTwoSlots(slots), wanted) {
            switch try await writeDahuaDNS(interface: interface, servers: wanted) {
            case .ended(let outcome)?:
                return outcome
            case .refused(let words)?:
                log.info("The camera’s Dahua API refused the DNS change (\(words)): putting the servers back through ONVIF")
                return try await restoreDahuaDNSThroughONVIF(backup)
            case nil:
                break
            }
            var last: [String]?
            let done = try await readBackAfterRestart(readBack, immediately: true) {
                guard let (_, now) = try await self.amcrest().networkDNS(interface: interface) else { return false }
                last = now
                return Self.sameSlots(Self.firstTwoSlots(now), wanted)
            }
            if !done {
                if let last, Self.sameSlots(Self.firstTwoSlots(last), Self.firstTwoSlots(slots)) {
                    log.info("The camera’s Dahua API said OK but changed nothing: putting the servers back through ONVIF")
                    return try await restoreDahuaDNSThroughONVIF(backup)
                }
                return .refused(Self.notTakenBack)
            }
        }
        log.info("Set the camera's DNS servers through its Dahua API")
        return CameraSetupOutcome(succeeded: true, detail: Self.dahuaDone)
    }

    private func restoreDahuaDNSThroughONVIF(_ backup: CameraDNSBackup) async throws -> CameraSetupOutcome {
        guard let client = await client(), let current = try await onvifDNS(client) else {
            return .refused("the camera no longer shows its DNS servers")
        }
        return try await restoreONVIFDNS(client, backup, searchDomains: backup.searchDomains ?? current.searchDomains)
    }

    /// How `setConfig` ended when it did not simply go through.
    private enum DahuaDNSWrite {
        /// The account may not make the change (HTTP 403): the step is over.
        case ended(CameraSetupOutcome)
        /// The camera answered something but "OK", in these words.
        case refused(words: String)
    }

    /// `setConfig`; nil when the camera took it or did not answer (it may restart its network before it answers: the read-back tells). A login
    /// refusal and a cancellation are thrown, and so is a failure of Camera Bridge's own check of the interface and servers (nothing was sent).
    private func writeDahuaDNS(interface: String, servers: [String]) async throws -> DahuaDNSWrite? {
        do {
            try await amcrest().setNetworkDNS(interface: interface, servers: servers)
        } catch let refusal as AmcrestRefusal {
            return .refused(words: refusal.words)
        } catch let error as CameraAdapterError where error.isLoginRefusal {
            throw error
        } catch let error as CameraAdapterError where CameraAdapterError.isNotPermitted(error) {
            return .ended(.notPermittedRefusal)
        } catch CameraAdapterError.invalidResponse(let why) {
            throw CameraAdapterError.invalidResponse(why)   // not the camera's: `setNetworkDNS` refused values it would not send
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.debug("The camera did not answer the DNS change through its Dahua API (it may be restarting its network)")
        }
        return nil
    }
}
