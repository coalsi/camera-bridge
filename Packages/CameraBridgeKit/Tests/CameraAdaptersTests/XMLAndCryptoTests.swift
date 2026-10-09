import Foundation
import Testing
@testable import CameraAdapters

@Suite struct XMLTreeTests {
    @Test func parsesIgnoringNamespacePrefixesAndCase() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
          <SOAP-ENV:Body>
            <tds:GetDeviceInformationResponse>
              <tds:Manufacturer>Reolink</tds:Manufacturer>
              <tds:Model>Reolink Video Doorbell WiFi</tds:Model>
            </tds:GetDeviceInformationResponse>
          </SOAP-ENV:Body>
        </SOAP-ENV:Envelope>
        """
        let tree = try XMLTree.parse(Data(xml.utf8))
        #expect(tree.name == "Envelope")
        #expect(tree.string("Body", "GetDeviceInformationResponse", "Manufacturer") == "Reolink")
        #expect(tree.string("body", "getdeviceinformationresponse", "model") == "Reolink Video Doorbell WiFi")
        #expect(tree.firstDescendant("Model")?.text == "Reolink Video Doorbell WiFi")
    }

    @Test func attributesAreLocalNamesAndDescendantsAreDepthFirst() throws {
        let xml = #"<a xmlns:tt="urn:x"><tt:Item tt:Name="State" Value="true"/><b><tt:Item Name="Other" Value="1"/></b></a>"#
        let tree = try XMLTree.parse(Data(xml.utf8))
        let items = tree.descendants("Item")
        #expect(items.count == 2)
        #expect(items[0].attribute("Name") == "State")
        #expect(items[0].attribute("value") == "true")
        #expect(items[1].attribute("Name") == "Other")
    }

    @Test func alternatingHikvisionNamespacesParseAlike() throws {
        let v1 = #"<EventNotificationAlert xmlns="http://www.hikvision.com/ver20/XMLSchema"><eventType>VMD</eventType></EventNotificationAlert>"#
        let v2 = #"<EventNotificationAlert xmlns="http://www.isapi.org/ver20/XMLSchema"><eventType>VMD</eventType></EventNotificationAlert>"#
        #expect(try XMLTree.parse(Data(v1.utf8)).string("eventType") == "VMD")
        #expect(try XMLTree.parse(Data(v2.utf8)).string("eventType") == "VMD")
        #expect(try XMLTree.parse(Data(v1.utf8)).namespaceURI == "http://www.hikvision.com/ver20/XMLSchema")
    }

    @Test func malformedInputThrows() {
        #expect(throws: (any Error).self) { try XMLTree.parse(Data("<a><b></a>".utf8)) }
        #expect(throws: (any Error).self) { try XMLTree.parse(Data()) }
        #expect(throws: (any Error).self) { try XMLTree.parse(Data("not xml at all".utf8)) }
    }

    @Test func serializesWithNamespaceDeclarationsForEchoing() throws {
        let xml = """
        <e:Envelope xmlns:e="urn:env" xmlns:dom0="urn:dom"><e:Body><wsa5:ReferenceParameters xmlns:wsa5="urn:wsa">\
        <dom0:SubscriptionId>7</dom0:SubscriptionId></wsa5:ReferenceParameters></e:Body></e:Envelope>
        """
        let tree = try XMLTree.parse(Data(xml.utf8))
        let parameters = try #require(tree.firstDescendant("ReferenceParameters"))
        let echoed = parameters.children.map { $0.serialized() }.joined()
        #expect(echoed == #"<dom0:SubscriptionId xmlns:dom0="urn:dom">7</dom0:SubscriptionId>"#)
        // Round trip: the echoed fragment is well-formed on its own.
        #expect(try XMLTree.parse(Data(echoed.utf8)).text == "7")
    }

    @Test func escapesText() {
        #expect(XMLTree.escape(#"a<b>&"c'"#) == "a&lt;b&gt;&amp;&quot;c&apos;")
    }
}

/// The SHA-1 under the PasswordDigest is BridgeSupport's `Hashes.sha1` (swift-crypto); its vectors are in
/// BridgeSupportTests (`HashesTests`).
@Suite struct WSSecurityTests {
    /// ONVIF Application Programmer's Guide example (cross-checked with Python hashlib).
    @Test func passwordDigestGolden() throws {
        let nonce = try #require(Data(base64Encoded: "LKqI6G/AikKCQrN0zqZFlg=="))
        let digest = ONVIFSOAP.passwordDigest(nonce: nonce, created: "2010-09-16T07:50:45Z", password: "userpassword")
        #expect(digest == "tuOSpGlFlIXsozq4HFNeeGeFLEI=")
    }

    @Test func securityHeaderCarriesUsernameTokenDigest() throws {
        let nonce = Data((0..<16).map { UInt8($0) })
        let created = try #require(ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
        let header = ONVIFSOAP.securityHeader(username: "admin", password: "p&ss", created: created, nonce: nonce)
        let wrapper = try XMLTree.parse(Data("<w xmlns:s=\"\(ONVIFSOAP.soapNamespace)\">\(header)</w>".utf8))
        let tree = try #require(wrapper.child("Security"))
        #expect(tree.attribute("mustUnderstand") == "1")
        #expect(tree.string("UsernameToken", "Username") == "admin")
        let password = try #require(tree.child("UsernameToken")?.child("Password"))
        #expect(password.attribute("Type")?.hasSuffix("#PasswordDigest") == true)
        #expect(tree.string("UsernameToken", "Nonce") == nonce.base64EncodedString())
        let createdText = try #require(tree.string("UsernameToken", "Created"))
        #expect(createdText.hasPrefix("2026-09-30T12:00:00"))
        #expect(password.text == ONVIFSOAP.passwordDigest(nonce: nonce, created: createdText, password: "p&ss"))
        #expect(!header.contains("p&ss"))
    }

    @Test func envelopeIsSOAP12WithBody() throws {
        let data = ONVIFSOAP.envelope(body: "<tds:GetDeviceInformation/>", security: nil)
        let tree = try XMLTree.parse(data)
        #expect(tree.name == "Envelope")
        #expect(tree.namespaceURI == "http://www.w3.org/2003/05/soap-envelope")
        #expect(tree.child("Body")?.child("GetDeviceInformation") != nil)
    }

    @Test func parsesSOAPFault() throws {
        let tree = try XMLTree.parse(try fixture("onvif/Fault-NotAuthorized.xml"))
        let fault = try #require(ONVIFSOAP.fault(in: tree))
        #expect(fault.subcode == "NotAuthorized")
        #expect(fault.isNotAuthorized)
        #expect(fault.reason.contains("not authorized") || fault.reason.contains("Sender not Authorized"))
    }

    /// Review finding (W4 BridgeSupport, round 4): a fault's text (up to the 16 MiB HTTP body limit) went into
    /// `CameraAdapterError.soapFault` whole, line breaks included, and from there into the log and the Add Camera sheet.
    /// Each part is at most 200 characters, without control characters.
    @Test func longSOAPFaultTextIsCut() throws {
        let reason = "RRRR\tR\n" + String(repeating: "R", count: 100_000) + "\nforged log line"
        let subcode = "ter:" + String(repeating: "S", count: 50_000) + "\r\n"
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:ter="http://www.onvif.org/ver10/error">
            <env:Body><env:Fault><env:Code><env:Value>env:Receiver</env:Value><env:Subcode><env:Value>\(subcode)</env:Value>
            </env:Subcode></env:Code><env:Reason><env:Text xml:lang="en">\(reason)</env:Text></env:Reason></env:Fault></env:Body>
            </env:Envelope>
            """
        let fault = try #require(ONVIFSOAP.fault(in: try XMLTree.parse(Data(xml.utf8))))
        #expect(fault.reason.count <= 200 && fault.reason.hasPrefix("RRRR"))
        #expect((fault.subcode ?? "").count <= 200 && (fault.subcode ?? "").hasPrefix("SSSS"))
        #expect(fault.summary.count <= 402)
        #expect(!fault.summary.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }
}
