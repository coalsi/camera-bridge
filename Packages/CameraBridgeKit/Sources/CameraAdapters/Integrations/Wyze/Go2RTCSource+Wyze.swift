import Foundation

extension Go2RTCSource {
    /// go2rtc's local Wyze connection to `device` at `host` (go2rtc's `internal/wyze/README.md`, MIT):
    /// `wyze://HOST?dtls=true&enr=…&mac=…&model=…&subtype=hd|sd&uid=…` (query sorted and escaped as Go's `url.Values.Encode()`, so the `enr`
    /// is percent-encoded). `host` is the camera's current address (resolve it from the MAC first, `NeighborTable`).
    /// Throws for a camera go2rtc cannot reach locally (`connection` RTSP-only or unsupported, no UID or `enr`) or an unusable host.
    public static func wyze(_ device: WyzeDevice, host: String, hd: Bool) throws -> Go2RTCSource {
        guard device.connection == .rtspAndLocal || device.connection == .localOnly else {
            throw Invalid(reason: "This Wyze camera cannot be reached through the local Wyze connection.")
        }
        guard let uid = device.p2pID, !uid.isEmpty, let enr = device.enr, !enr.isEmpty else {
            throw Invalid(reason: "Wyze did not give the camera's connection details (UID and key).")
        }
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.utf8.count <= 255,
              address.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-:[]".unicodeScalars.contains($0)) })
        else {
            throw Invalid(reason: "The camera's address is not a host name or IP address.")
        }
        var items = ["enr": enr, "mac": device.mac, "model": device.productModel, "subtype": hd ? "hd" : "sd", "uid": uid]
        if device.dtls { items["dtls"] = "true" }
        return try Go2RTCSource(parsing: "wyze://\(address)?" + encodedQuery(items))
    }
}
