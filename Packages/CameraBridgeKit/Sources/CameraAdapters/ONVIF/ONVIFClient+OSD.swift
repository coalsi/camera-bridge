import BridgeSupport
import Foundation

/// One on-screen display element of an ONVIF camera (Media service `GetOSDs`), as the camera reported it.
struct ONVIFOSD: Sendable, Equatable {
    var token: String
    /// `Type` of the element: "Text" or "Image".
    var type: String
    /// `TextString/Type`: "Plain", "Date", "Time" or "DateAndTime"; nil for an image.
    var textType: String?
    /// The element's children exactly as the camera sent them (serialized XML), to put it back with `CreateOSD` / `SetOSD`.
    var children: String

    /// An element that shows the camera's own date and/or time.
    var showsClock: Bool {
        guard type.caseInsensitiveCompare("Text") == .orderedSame, let textType else { return false }
        return ["date", "time", "dateandtime"].contains(textType.lowercased())
    }
}

/// ONVIF Media service on-screen display: `GetOSDs`, `DeleteOSD`, `CreateOSD`, `SetOSD`.
extension ONVIFClient {
    func osds() async throws -> [ONVIFOSD] {
        let envelope = try await call(await mediaServiceURL(), body: "<trt:GetOSDs/>", action: "http://www.onvif.org/ver10/media/wsdl/GetOSDs")
        let response = try responseBody(envelope, "GetOSDsResponse")
        return response.children("OSDs").compactMap(Self.parseOSD)
    }

    static func parseOSD(_ node: XMLTree) -> ONVIFOSD? {
        guard let token = node.attribute("token"), !token.isEmpty else { return nil }
        return ONVIFOSD(token: token, type: node.string("Type") ?? "", textType: node.child("TextString")?.string("Type"),
                        children: node.children.map { $0.serialized() }.joined())
    }

    func deleteOSD(token: String) async throws {
        _ = try await call(await mediaServiceURL(), body: "<trt:DeleteOSD><trt:OSDToken>\(XMLTree.escape(token))</trt:OSDToken></trt:DeleteOSD>",
                           action: "http://www.onvif.org/ver10/media/wsdl/DeleteOSD")
    }

    /// Puts back an element removed with `deleteOSD` (`children` as `ONVIFOSD.children` kept them).
    func createOSD(children: String) async throws {
        _ = try await call(await mediaServiceURL(), body: "<trt:CreateOSD><trt:OSD token=\"\">\(children)</trt:OSD></trt:CreateOSD>",
                           action: "http://www.onvif.org/ver10/media/wsdl/CreateOSD")
    }

    /// Replaces element `token` with `children` (the whole `OSD` configuration; the camera keeps nothing of the old one).
    func setOSD(token: String, children: String) async throws {
        _ = try await call(await mediaServiceURL(),
                           body: "<trt:SetOSD><trt:OSD token=\"\(XMLTree.escape(token))\">\(children)</trt:OSD></trt:SetOSD>",
                           action: "http://www.onvif.org/ver10/media/wsdl/SetOSD")
    }

    /// `children` with the text element turned into an empty plain text: what `SetOSD` writes to blank a clock element a
    /// camera will not let `DeleteOSD` remove. nil when `children` has no `TextString`.
    static func blanked(children: String) -> String? {
        guard let open = children.range(of: "<tt:TextString", options: .caseInsensitive) ?? children.range(of: "<TextString", options: .caseInsensitive),
              let close = children.range(of: "TextString>", options: .caseInsensitive, range: open.upperBound..<children.endIndex) else { return nil }
        var result = children
        result.replaceSubrange(open.lowerBound..<close.upperBound,
                               with: "<tt:TextString><tt:Type>Plain</tt:Type><tt:PlainText></tt:PlainText></tt:TextString>")
        return result
    }
}
