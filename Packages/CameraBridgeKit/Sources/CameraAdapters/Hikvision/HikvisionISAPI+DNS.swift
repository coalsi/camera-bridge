import BridgeSupport
import Foundation

/// The DNS servers of a Hikvision camera's first network interface as `/ISAPI/System/Network/interfaces/1/ipAddress` has them.
struct ISAPIDNSServers: Sendable, Equatable {
    /// `PrimaryDNS` and `SecondaryDNS` IPv4 addresses as the document has them ("0.0.0.0" and empty kept; an absent `SecondaryDNS` left
    /// out): what a backup keeps and puts back in place.
    var slots: [String]
    /// "static", "dynamic" (DHCP) or "apipa": never changed by the DNS step.
    var addressingType: String?

    /// The servers the camera asks: no empty or 0.0.0.0 entry, each once.
    var servers: [String] {
        var result: [String] = []
        for slot in slots where !slot.isEmpty && slot != "0.0.0.0" && !result.contains(slot) { result.append(slot) }
        return result
    }
}

/// The camera's DNS servers through ISAPI (the internet guard's Watch points them at the bridge). The document also holds the camera's own
/// address, mask and gateway, each with an `ipAddress` element too, so reads and edits stay inside `PrimaryDNS` and `SecondaryDNS`; the
/// write is a read-modify-write of the whole document in which only those elements differ (`addressingType` stays as it is). Built from
/// the ISAPI 2.0 schema's shape: not yet checked against a real camera's answer. IPv4 servers only (the elements' `ipv6Address` is left
/// as it is).
extension HikvisionISAPI {
    static let ipAddressPath = "/ISAPI/System/Network/interfaces/1/ipAddress"
    static let dnsSections = ["PrimaryDNS", "SecondaryDNS"]

    /// The document's DNS servers; nil when it has no `PrimaryDNS` (not this camera's way to set them).
    static func dnsServers(in document: String) -> ISAPIDNSServers? {
        guard let tree = try? XMLTree.parse(Data(document.utf8)), tree.matches("IPAddress"), let primary = tree.child("PrimaryDNS") else { return nil }
        let slots = [primary] + (tree.child("SecondaryDNS").map { [$0] } ?? [])
        return ISAPIDNSServers(slots: slots.map { $0.string("ipAddress")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" },
                               addressingType: tree.string("addressingType")?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `document` with `servers[0]` as the `PrimaryDNS` address and `servers[1]` as the `SecondaryDNS` one (a missing `SecondaryDNS` is
    /// not added); nil when it has no `PrimaryDNS`.
    static func settingDNS(_ servers: [String], in document: String) -> String? {
        var result = document
        for (section, value) in zip(dnsSections, servers) {
            guard let edited = settingElement("ipAddress", inSection: section, to: value, in: result) else {
                if section == dnsSections[0] { return nil }
                continue
            }
            result = edited
        }
        return result
    }

    /// `document` with the `<name>` element inside the first `<section>` element set to `value` (added before `</section>` when the
    /// section lacks it); nil when there is no such section.
    static func settingElement(_ name: String, inSection section: String, to value: String, in document: String) -> String? {
        var searchStart = document.startIndex
        var found: Range<String.Index>?
        // The section's own tag: `<PrimaryDNS>` or `<PrimaryDNS …>`, not a longer name that starts the same.
        while let open = document.range(of: "<\(section)", options: .caseInsensitive, range: searchStart..<document.endIndex) {
            if open.upperBound < document.endIndex, [">", " ", "\t", "\n", "\r"].contains(document[open.upperBound]) { found = open; break }
            searchStart = open.upperBound
        }
        guard let open = found, let tagEnd = document.range(of: ">", range: open.upperBound..<document.endIndex),
              let close = document.range(of: "</\(section)>", options: .caseInsensitive, range: tagEnd.upperBound..<document.endIndex)
        else { return nil }
        let inner = String(document[tagEnd.upperBound..<close.lowerBound])
        let edited: String
        if let replaced = replacingElement(name, in: inner, with: XMLTree.escape(value)) {
            edited = replaced
        } else {
            edited = inner + "<\(name)>\(XMLTree.escape(value))</\(name)>"
        }
        var result = document
        result.replaceSubrange(tagEnd.upperBound..<close.lowerBound, with: edited)
        return result
    }
}
