import BridgeSupport
import Foundation

/// SOAP 1.2 envelopes and WS-Security UsernameToken (PasswordDigest) for ONVIF (ONVIF Core §5.12, OASIS WSS
/// UsernameToken Profile 1.0).
enum ONVIFSOAP {
    static let soapNamespace = "http://www.w3.org/2003/05/soap-envelope"
    static let namespaceDeclarations = [
        ("s", soapNamespace),
        ("tds", "http://www.onvif.org/ver10/device/wsdl"),
        ("trt", "http://www.onvif.org/ver10/media/wsdl"),
        ("timg", "http://www.onvif.org/ver20/imaging/wsdl"),
        ("tev", "http://www.onvif.org/ver10/events/wsdl"),
        ("tt", "http://www.onvif.org/ver10/schema"),
        ("wsnt", "http://docs.oasis-open.org/wsn/b-2"),
        ("wsa", "http://www.w3.org/2005/08/addressing"),
    ]
    static let wsseNamespace = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
    static let wsuNamespace = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
    static let passwordDigestType = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
    static let base64EncodingType = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary"

    /// A complete SOAP 1.2 envelope. `header` is raw XML placed before the security header.
    static func envelope(body: String, header: String = "", security: String?) -> Data {
        let declarations = namespaceDeclarations.map { " xmlns:\($0.0)=\"\($0.1)\"" }.joined()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<s:Envelope\(declarations)>"
        let headerContent = header + (security ?? "")
        if !headerContent.isEmpty { xml += "<s:Header>\(headerContent)</s:Header>" }
        xml += "<s:Body>\(body)</s:Body></s:Envelope>"
        return Data(xml.utf8)
    }

    /// `Base64(SHA1(nonce + created + password))` (the ONVIF Core spec fixes SHA-1; swift-crypto via BridgeSupport).
    static func passwordDigest(nonce: Data, created: String, password: String) -> String {
        var input = nonce
        input.append(Data(created.utf8))
        input.append(Data(password.utf8))
        return Data(Hashes.sha1(input)).base64EncodedString()
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// `<Security>` header with a UsernameToken PasswordDigest (the password itself never appears).
    static func securityHeader(username: String, password: String, created: Date, nonce: Data) -> String {
        let createdText = timestamp(created)
        let digest = passwordDigest(nonce: nonce, created: createdText, password: password)
        return "<Security s:mustUnderstand=\"1\" xmlns=\"\(wsseNamespace)\"><UsernameToken>"
            + "<Username>\(XMLTree.escape(username))</Username>"
            + "<Password Type=\"\(passwordDigestType)\">\(digest)</Password>"
            + "<Nonce EncodingType=\"\(base64EncodingType)\">\(nonce.base64EncodedString())</Nonce>"
            + "<Created xmlns=\"\(wsuNamespace)\">\(createdText)</Created>"
            + "</UsernameToken></Security>"
    }

    static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    struct Fault: Sendable, Equatable {
        var code: String
        var subcode: String?
        var reason: String

        var isNotAuthorized: Bool {
            [subcode, code].contains { $0?.localizedCaseInsensitiveContains("NotAuthorized") == true }
                || reason.localizedCaseInsensitiveContains("not authorized")
        }

        /// `Subcode: reason` (the code when there is no subcode; either part alone when the other is empty).
        var summary: String {
            let head = subcode ?? code
            if reason.isEmpty { return head }
            return head.isEmpty ? reason : "\(head): \(reason)"
        }
    }

    /// The SOAP fault in an envelope (SOAP 1.2 `Code/Subcode/Reason`, SOAP 1.1 `faultcode/faultstring`), if any. Each
    /// part is the camera's text (up to the HTTP body limit) and goes into errors and logs: cut and without control
    /// characters (`Redact.cameraText`).
    static func fault(in envelope: XMLTree) -> Fault? {
        guard let fault = envelope.child("Body")?.child("Fault") ?? envelope.firstDescendant("Fault") else { return nil }
        let code = Redact.cameraText(XMLTree.localName(fault.element("Code", "Value")?.text ?? fault.string("faultcode") ?? ""))
        let subcode = fault.element("Code", "Subcode", "Value").map { Redact.cameraText(XMLTree.localName($0.text)) }
        let reason = Redact.cameraText(fault.element("Reason", "Text")?.text ?? fault.string("faultstring") ?? "")
        return Fault(code: code, subcode: subcode, reason: reason)
    }
}
