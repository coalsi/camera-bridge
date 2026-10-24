import BridgeSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A DNS write must never break a camera's address (2026-10-24: two ANNKE I91ET, Hikvision OEM firmware V5.8.10, added as plain ONVIF on
/// DHCP, came up at Hikvision's factory 192.168.1.64 with DHCP off after an ONVIF `SetDNS`: that firmware turns the interface's DHCP off
/// without saving an address). So, around every ONVIF `SetDNS`:
///
/// - before it, `GetNetworkInterfaces` is read: a Hikvision-family camera (`isHikvisionFamily`) with IPv4 DHCP on, or whose interfaces can't
///   be read, gets no `SetDNS` at all (`hikvisionONVIFRefusal`), as ISAPI treats a Hikvision on DHCP: not watched, with "Change it by hand";
/// - after it (Watch's forms, and Restore's), an interface that had DHCP on and shows it off now gets DHCP back at once
///   (`SetNetworkInterfaces` with DHCP true), and the step is refused in plain words (`dhcpTurnedOff`), logged as a warning.
///
/// "Fix its address so the DNS stays" turns DHCP off on purpose, with the address written: its interfaces show DHCP off before its `SetDNS`,
/// so nothing here undoes it.
extension CameraSettingsService {
    /// Why Watch does not write a Hikvision-family camera's DNS through ONVIF while it takes its address from DHCP.
    static let hikvisionONVIFRefusal = "the camera takes its address from DHCP, and a Hikvision-family camera can turn DHCP off when its DNS "
        + "is changed through ONVIF (it then comes back at its factory address, 192.168.1.64), so Camera Bridge does not change it: set its DNS by "
        + "hand on the camera’s own page, with a fixed address"

    /// The refusal after a DNS write that turned the camera's DHCP off, which Camera Bridge turned back on (`back`) or could not.
    static func dhcpTurnedOff(back: Bool, atRestart: Bool = false) -> String {
        let start = "the camera turned DHCP off when its DNS servers were changed, which would have lost its address at its next restart"
        if !back {
            return start + ", and it did not take DHCP back: open the camera’s own page now and turn DHCP on, before it restarts"
        }
        return start + (atRestart ? ", so Camera Bridge turned DHCP back on (the camera applies it when it restarts)" : ", so Camera Bridge turned DHCP back on at once")
            + " and changed nothing more"
    }

    /// The refusal when the interfaces are not shown again after a DNS write, so DHCP can't be checked.
    static let dhcpUnconfirmed = "the camera did not show its address settings again after its DNS servers were changed, so Camera Bridge "
        + "can’t tell whether it still takes its address from DHCP: check DHCP on the camera’s own page before it restarts"

    /// The makers whose ONVIF names Hikvision's family (manufacturer, any case, anywhere in it): Hikvision and the brands it makes cameras for.
    static let hikvisionFamilyMakers = ["hikvision", "hiwatch", "annke", "ezviz"]

    /// Whether an ONVIF `GetDeviceInformation` names a Hikvision-family camera: its manufacturer (`hikvisionFamilyMakers`), or a Hikvision
    /// model number (`DS-…`), or a maker or model that is Hikvision's realm text (`IP Camera(…)`).
    static func namesHikvisionFamily(manufacturer: String, model: String) -> Bool {
        let maker = manufacturer.lowercased()
        if hikvisionFamilyMakers.contains(where: maker.contains) { return true }
        let model = model.trimmingCharacters(in: .whitespaces)
        return model.uppercased().hasPrefix("DS-") || CameraDrivers.isHikvisionRealm(model) || CameraDrivers.isHikvisionRealm(manufacturer)
    }

    /// Whether the camera is Hikvision's or one of its OEMs': its vendor, its ONVIF manufacturer or model (`namesHikvisionFamily`), or its
    /// HTTP port answering ISAPI without a login (`CameraDrivers.answersISAPI`: an ISAPI document, or a Digest realm such as
    /// `IP Camera(…)`). Asked once for the service's life. Throws the camera's login refusal and a cancellation.
    func isHikvisionFamily(_ client: ONVIFClient) async throws -> Bool {
        if let hikvisionFamilyKnown { return hikvisionFamilyKnown }
        var family = vendor == .hikvision
        if !family, let info = try await onvifAnswerOrNil({ try await client.deviceInformation() }) {
            family = Self.namesHikvisionFamily(manufacturer: info.manufacturer, model: info.model)
        }
        if !family { family = await CameraDrivers.answersISAPI(endpoint: endpoint) }
        hikvisionFamilyKnown = family
        return family
    }

    /// The tokens of the interfaces that are on with IPv4 from DHCP, as `GetNetworkInterfaces` shows them now; nil when it does not answer
    /// or shows no interface.
    func onvifDHCPTokens(_ client: ONVIFClient) async throws -> Set<String>? {
        guard let interfaces = try await onvifAnswerOrNil({ try await client.networkInterfaces() }), !interfaces.isEmpty else { return nil }
        return Set(interfaces.filter { $0.enabled && $0.ipv4Enabled && $0.ipv4DHCP }.map(\.token))
    }

    /// Before Watch's ONVIF `SetDNS`: the refusal for a Hikvision-family camera on DHCP (or whose interfaces it does not show), with nothing
    /// sent; else the interfaces on DHCP now, for `restoringDHCP` after the write (nil: not shown, nothing to compare).
    func onvifDNSWriteCheck(_ client: ONVIFClient) async throws -> (refusal: String?, dhcp: Set<String>?) {
        let dhcp = try await onvifDHCPTokens(client)
        if dhcp?.isEmpty != true, try await isHikvisionFamily(client) { return (Self.hikvisionONVIFRefusal, dhcp) }
        return (nil, dhcp)
    }

    /// After an ONVIF `SetDNS`: an interface of `before` (on DHCP before the write) that shows DHCP off now gets DHCP back at once
    /// (`SetNetworkInterfaces`, DHCP true), read back, and the refusal says so (`dhcpTurnedOff`). The interfaces are read at once and while
    /// the camera restarts its network service (`timing`); one that never shows them again is refused (`dhcpUnconfirmed`). nil: DHCP is as
    /// it was (or nothing was on DHCP before).
    func restoringDHCP(_ client: ONVIFClient, before: Set<String>?, timing: DNSReadBackTiming) async throws -> CameraSetupOutcome? {
        guard let before, !before.isEmpty else { return nil }
        var now: Set<String>?
        _ = try await readBackAfterRestart(timing, immediately: true) {
            now = try await self.onvifDHCPTokensOrThrow(client)
            return true
        }
        guard let now else {
            log.warning("The camera did not show its network interfaces again after its DNS was changed through ONVIF")
            return .refused(Self.dhcpUnconfirmed)
        }
        let lost = before.subtracting(now)
        guard !lost.isEmpty else { return nil }
        log.warning("The camera turned DHCP off when its DNS was changed through ONVIF: turning DHCP back on")
        var atRestart = false
        for token in lost.sorted() {
            do {
                atRestart = try await client.setNetworkInterface(token: token, manual: nil, dhcp: true) || atRestart
            } catch let error as CameraAdapterError where !error.isLoginRefusal {
                log.error("The camera refused DHCP back after its DNS was changed: \(CameraAdapterError.refusalWords(error))")
                return .refused(Self.dhcpTurnedOff(back: false))
            }
        }
        if !atRestart {
            let back = try await readBackAfterRestart(timing, immediately: true) {
                guard let tokens = try await self.onvifDHCPTokensOrThrow(client) else { return false }
                return lost.isSubset(of: tokens)
            }
            guard back else {
                log.error("The camera did not take DHCP back after its DNS was changed")
                return .refused(Self.dhcpTurnedOff(back: false))
            }
        }
        log.notice("The camera takes its address from DHCP again\(atRestart ? " once it restarts" : "")")
        return .refused(Self.dhcpTurnedOff(back: true, atRestart: atRestart))
    }

    /// `onvifDHCPTokens`, a fault, an HTTP error or an answer without interfaces thrown (so `readBackAfterRestart` asks again) rather than nil.
    private func onvifDHCPTokensOrThrow(_ client: ONVIFClient) async throws -> Set<String>? {
        let interfaces = try await client.networkInterfaces()
        guard !interfaces.isEmpty else { throw CameraAdapterError.unsupported("no network interfaces shown") }
        return Set(interfaces.filter { $0.enabled && $0.ipv4Enabled && $0.ipv4DHCP }.map(\.token))
    }

    /// A device-service read; nil when the camera answers it with a fault or an HTTP error that is not a login refusal.
    private func onvifAnswerOrNil<T: Sendable>(_ read: () async throws -> T) async throws -> T? {
        do { return try await read() } catch let error as CameraAdapterError where !error.isLoginRefusal { return nil }
    }
}

extension CameraDrivers {
    /// A Digest realm of Hikvision's ISAPI: one naming Hikvision, a model number (`DS-…`), or `IP Camera(…)` (Hikvision's newer firmware and
    /// its OEMs', such as ANNKE).
    static func isHikvisionRealm(_ realm: String) -> Bool {
        let text = realm.trimmingCharacters(in: .whitespaces)
        return text.localizedCaseInsensitiveContains("hikvision") || text.uppercased().hasPrefix("DS-")
            || (text.hasPrefix("IP Camera(") && text.hasSuffix(")"))
    }

    /// Whether `endpoint`'s HTTP port answers ISAPI's `deviceInfo` as Hikvision's family does, asked without a login (no credentials are
    /// ever sent here): an ISAPI document, or a 401 with a Hikvision Digest realm (`isHikvisionRealm`). False for anything else, and when
    /// nothing answers within `timeout`.
    static func answersISAPI(endpoint: CameraEndpoint, timeout: Duration = .seconds(4)) async -> Bool {
        guard let url = endpoint.httpURL(path: "/ISAPI/System/deviceInfo") else { return false }
        return (try? await withTimeout(timeout + .milliseconds(500)) {
            let client = AuthenticatingHTTPClient(credentials: nil, timeout: timeout)
            defer { client.invalidate() }
            guard let (data, response) = try? await client.data(for: URLRequest(url: url)) else { return false }
            switch response.statusCode {
            case 200: return isISAPIDeviceInfo(data)
            case 401: return isHikvisionRealm(DigestChallenge.parse(response.value(forHTTPHeaderField: "WWW-Authenticate") ?? "")?.realm ?? "")
            default: return false
            }
        }) ?? false
    }
}
