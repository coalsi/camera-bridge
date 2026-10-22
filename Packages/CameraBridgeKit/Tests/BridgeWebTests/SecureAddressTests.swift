import BridgeEngine
import BridgeSupport
import Crypto
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// A website that answers from a script and remembers what it was sent.
final class FakeBoxServer: BoxTransport {
    struct Seen: Sendable { var method: String; var path: String; var headers: [String: String]; var body: Data }
    let seen = Box<[Seen]>([])
    /// The answer to every call after `register` (status, body); the default is the success answer.
    let answer = Box<(Int, String)>((200, #"{"ok":true}"#))
    let registerAnswer = Box<(Int, String)>((201, #"{"name":"k7f2q9","host":"k7f2q9.box.camera-bridge.app"}"#))
    let unreachable = Box<Bool>(false)

    func send(method: String, url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        seen.update { $0.append(Seen(method: method, path: url.path, headers: headers, body: body)) }
        if unreachable.value { throw URLError(.notConnectedToInternet) }
        let (status, text) = url.path.hasSuffix("/register") ? registerAnswer.value : answer.value
        return (status, Data(text.utf8))
    }
}

@Suite(.timeLimit(.minutes(1))) struct SecureAddressTests {
    static let base = URL(string: "https://www.example.test/api/v1/box/")!
    static let now = Date(timeIntervalSince1970: 1_792_224_000)

    // MARK: Signing and the client

    @Test func theSignatureCoversMethodPathTimestampAndBodyHash() throws {
        let key = Curve25519.Signing.PrivateKey()
        let body = Data(#"{"ip":"192.168.77.5"}"#.utf8)
        let signature = try BoxClient.signature(key: key, method: "POST", path: "/api/v1/box/address", timestamp: 1_792_224_000_123, body: body)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = Data("POST\n/api/v1/box/address\n1792224000123\n\(digest)".utf8)
        #expect(key.publicKey.isValidSignature(try #require(Data(base64Encoded: signature)), for: message))
        let other = Data("POST\n/api/v1/box/address\n1792224000124\n\(digest)".utf8)
        #expect(!key.publicKey.isValidSignature(try #require(Data(base64Encoded: signature)), for: other))
        let empty = String(format: "%02x", 0) // the hash of an empty body is the well-known one
        _ = empty
        #expect(String(decoding: BoxClient.signedMessage(method: "DELETE", path: "/api/v1/box/acme", timestamp: 5, body: Data()), as: UTF8.self)
                == "DELETE\n/api/v1/box/acme\n5\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func aSignedCallCarriesTheHeadersAndTheTimestampsOnlyRise() async throws {
        let server = FakeBoxServer()
        let key = Curve25519.Signing.PrivateKey()
        // The clock stands still, then goes back: the timestamp still rises by one.
        let client = BoxClient(base: Self.base, transport: server, now: { Self.now })
        try await client.sendAddress("192.168.77.5", as: ("k7f2q9", key))
        try await client.setChallenge("abc_DEF-123456789012345", as: ("k7f2q9", key))
        try await client.clearChallenge(as: ("k7f2q9", key))
        let seen = server.seen.value
        #expect(seen.map(\.method) == ["POST", "POST", "DELETE"] && seen.map(\.path) == ["/api/v1/box/address", "/api/v1/box/acme", "/api/v1/box/acme"])
        let stamps = try seen.map { try #require(Int64($0.headers["X-CB-Timestamp"] ?? "")) }
        #expect(stamps[0] == 1_792_224_000_000 && stamps[1] == stamps[0] + 1 && stamps[2] == stamps[1] + 1)
        #expect(seen.allSatisfy { $0.headers["X-CB-Name"] == "k7f2q9" })
        #expect(String(decoding: seen[0].body, as: UTF8.self) == #"{"ip":"192.168.77.5"}"#)
        #expect(seen[2].body.isEmpty)
        for call in seen {
            let message = BoxClient.signedMessage(method: call.method, path: call.path, timestamp: try #require(Int64(call.headers["X-CB-Timestamp"] ?? "")), body: call.body)
            #expect(key.publicKey.isValidSignature(try #require(Data(base64Encoded: call.headers["X-CB-Signature"] ?? "")), for: message))
        }
        #expect(client.lastSentTimestamp == stamps[2])
    }

    @Test func registerIsUnsignedAndFailuresAreSaidInPlainWords() async throws {
        let server = FakeBoxServer()
        let client = BoxClient(base: Self.base, transport: server)
        let registration = try await client.register(publicKey: "AAAA")
        #expect(registration == BoxClient.Registration(name: "k7f2q9", host: "k7f2q9.box.camera-bridge.app"))
        #expect(server.seen.value[0].headers["X-CB-Signature"] == nil && String(decoding: server.seen.value[0].body, as: UTF8.self) == #"{"publicKey":"AAAA"}"#)
        let key = Curve25519.Signing.PrivateKey()
        for (status, kind) in [(503, BoxClientError.Kind.notReady), (429, .rateLimited), (401, .unauthorized), (400, .refused)] {
            server.answer.set((status, #"{"error":"nope"}"#))
            do { try await client.sendAddress("192.168.77.5", as: ("k7f2q9", key)); Issue.record("status \(status) was taken") } catch let error as BoxClientError {
                #expect(error.kind == kind)
                if status == 503 { #expect(error.message.hasPrefix("The secure address service isn’t ready yet")) }
            }
        }
        server.unreachable.set(true)
        do { try await client.sendAddress("192.168.77.5", as: ("k7f2q9", key)); Issue.record("taken") } catch let error as BoxClientError { #expect(error.kind == .unreachable) }
    }

    @Test func thePrivateKeyPEMIsPKCS8OfTheSameKey() throws {
        let identity = BoxIdentity()
        let pem = identity.privateKeyPEM
        #expect(pem.hasPrefix("-----BEGIN PRIVATE KEY-----\n") && pem.hasSuffix("-----END PRIVATE KEY-----\n"))
        let body = pem.split(separator: "\n")[1]
        let der = try #require(Data(base64Encoded: String(body)))
        #expect(der.count == 48 && der.suffix(32) == identity.key.rawRepresentation && der.prefix(16) == Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]))
    }

    // MARK: The service

    struct Rig {
        let directory: TemporaryDirectory
        let backend: FakeBackend
        let system: FakeSystem
        let server: FakeBoxServer
        let service: SecureAddressService
        let clock: Box<Date>
    }

    func rig(addresses: [String] = ["192.168.77.5"], resolver: @escaping @Sendable (String) async -> [String] = { _ in [] }) throws -> Rig {
        let directory = try TemporaryDirectory(prefix: "cb-secure")
        let backend = FakeBackend()
        let system = FakeSystem()
        let server = FakeBoxServer()
        let clock = Box(Self.now)
        backend.write { $0.localAddresses = addresses }
        let service = SecureAddressService(backend: backend, system: system, directory: directory.url,
                                           client: BoxClient(base: Self.base, transport: server, now: { clock.value }), resolver: resolver, now: { clock.value })
        return Rig(directory: directory, backend: backend, system: system, server: server, service: service, clock: clock)
    }

    @Test func aSystemWithoutATLSFrontDoesNothing() async throws {
        let rig = try rig()
        defer { rig.directory.remove() }
        await rig.service.tick()
        #expect(rig.server.seen.value.isEmpty)
        #expect(await rig.service.report().available == false)
    }

    @Test func itRegistersOnceKeepsTheNameAndSendsTheAddressWhenItChanges() async throws {
        let rig = try rig()
        defer { rig.directory.remove() }
        rig.system.certificate.set(CertificateStatus(state: "none"))
        await rig.service.tick()
        await rig.service.tick()
        var calls = rig.server.seen.value.map { "\($0.method) \($0.path)" }
        #expect(calls.filter { $0.hasSuffix("/register") }.count == 1, "registered once")
        #expect(calls.filter { $0.hasSuffix("/address") }.count == 1, "the same address is sent once")
        // The key is in the secret store; the state file holds no key.
        let stored = try #require(rig.backend.read { $0.pluginSecrets["box-identity"] })
        #expect(stored.count == 32)
        let file = try String(contentsOf: rig.directory.url.appending(path: "secure-address.json"), encoding: .utf8)
        #expect(file.contains("k7f2q9.box.camera-bridge.app") && !file.contains(stored.base64EncodedString()))
        // A new service on the same folder remembers the name and does not register again.
        rig.backend.write { $0.localAddresses = ["192.168.77.9"] }
        let again = SecureAddressService(backend: rig.backend, system: rig.system, directory: rig.directory.url,
                                         client: BoxClient(base: Self.base, transport: rig.server, now: { rig.clock.value }), now: { rig.clock.value })
        await again.tick()
        calls = rig.server.seen.value.map { "\($0.method) \($0.path)" }
        #expect(calls.filter { $0.hasSuffix("/register") }.count == 1 && calls.filter { $0.hasSuffix("/address") }.count == 2)
        let bodies = rig.server.seen.value.filter { $0.path.hasSuffix("/address") }.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies == [#"{"ip":"192.168.77.5"}"#, #"{"ip":"192.168.77.9"}"#])
        let stamps = rig.server.seen.value.compactMap { Int64($0.headers["X-CB-Timestamp"] ?? "") }
        #expect(stamps == stamps.sorted() && Set(stamps).count == stamps.count, "the timestamps rise across a restart")
    }

    @Test func itAsksForACertificateAndWaitsBetweenTries() async throws {
        let rig = try rig()
        defer { rig.directory.remove() }
        rig.system.certificate.set(CertificateStatus(state: "none"))
        await rig.service.tick()
        #expect(rig.system.obtained.value == ["k7f2q9.box.camera-bridge.app"])
        await rig.service.tick()
        #expect(rig.system.obtained.value.count == 1, "not again within the wait")
        rig.clock.set(Self.now.addingTimeInterval(601))
        rig.system.certificate.set(CertificateStatus(state: "failed", message: "The website said no."))
        await rig.service.tick()
        #expect(rig.system.obtained.value.count == 2)
        let report = await rig.service.report()
        #expect(report.state == "error" && report.problem?.code == "certificate" && report.redirectActive == false)
    }

    @Test func aCertificateIsRenewedThirtyDaysBeforeItExpires() async throws {
        let rig = try rig()
        defer { rig.directory.remove() }
        let host = "k7f2q9.box.camera-bridge.app"
        rig.system.certificate.set(CertificateStatus(state: "ready", host: host, notAfter: Self.now.addingTimeInterval(31 * 86_400)))
        await rig.service.tick()
        #expect(rig.system.obtained.value.isEmpty)
        var report = await rig.service.report()
        #expect(report.state == "ready" && report.redirectActive && report.url == "https://\(host)")
        #expect(report.renewsOn == Self.now.addingTimeInterval(86_400) && report.expiresOn == Self.now.addingTimeInterval(31 * 86_400))
        rig.clock.set(Self.now.addingTimeInterval(2 * 86_400))
        await rig.service.tick()
        #expect(rig.system.obtained.value == [host], "29 days left: renew")
        report = await rig.service.report()
        #expect(report.state == "ready", "the old certificate still serves while the new one is made")
    }

    @Test func websiteTroubleBecomesAPlainSentenceAndTheRetryComesLater() async throws {
        let rig = try rig()
        defer { rig.directory.remove() }
        rig.system.certificate.set(CertificateStatus(state: "none"))
        rig.server.registerAnswer.set((503, #"{"error":"dns token"}"#))
        await rig.service.tick()
        var report = await rig.service.report()
        #expect(report.state == "error" && report.problem?.code == "service_not_ready" && report.problem?.message.contains("isn’t ready yet") == true)
        rig.server.registerAnswer.set((201, #"{"name":"k7f2q9","host":"k7f2q9.box.camera-bridge.app"}"#))
        rig.server.unreachable.set(true)
        await rig.service.tick()
        report = await rig.service.report()
        #expect(report.problem?.code == "no_internet")
    }

    @Test func theRedirectSwitchIsKept() async throws {
        let rig = try rig()
        defer { rig.directory.remove() }
        await rig.service.setRedirect(false)
        #expect(rig.service.snapshot.current.redirect == false)
        #expect(SecureAddressState.load(from: rig.directory.url).redirect == false)
    }

    @Test func theRebindTestTellsARouterThatHidesTheNameFromAnOpenOne() async throws {
        let host = "k7f2q9.box.camera-bridge.app"
        for (answers, expected) in [([host: ["192.168.77.5"]], "ok"), ([host: ["192.168.77.6"]], "wrong_address"),
                                    (["www.camera-bridge.app": ["203.0.113.5"]], "blocked"), ([:], "no_internet")] as [([String: [String]], String)] {
            let rig = try rig(resolver: { answers[$0] ?? [] })
            defer { rig.directory.remove() }
            rig.system.certificate.set(CertificateStatus(state: "none"))
            await rig.service.tick()
            #expect(await rig.service.checkRebind().state == expected)
            #expect(await rig.service.report().rebind?.state == expected)
        }
    }

    // MARK: Rules

    @Test func theHomeAddressIsAPrivateOneAndStaysPut() {
        #expect(SecureAddressRules.homeAddress(among: ["203.0.113.4", "10.0.0.8", "192.168.77.5"], previous: nil) == "10.0.0.8")
        #expect(SecureAddressRules.homeAddress(among: ["10.0.0.8", "192.168.77.5"], previous: "192.168.77.5") == "192.168.77.5")
        #expect(SecureAddressRules.homeAddress(among: ["203.0.113.4", "172.32.0.1", "169.254.1.1"], previous: nil) == nil)
        #expect(SecureAddressRules.isPrivateIPv4("172.16.0.1") && !SecureAddressRules.isPrivateIPv4("172.15.0.1") && !SecureAddressRules.isPrivateIPv4("192.168.1"))
    }

    private func page(_ path: String = "/", host: String = "camera-bridge.local", from: String = "192.168.77.20", method: String = "GET",
                      accept: String = "text/html,application/xhtml+xml", secure: Bool = false) -> HTTPRequest {
        var request = HTTPRequest(method: method, target: path, headers: HTTPHeaders([("Host", host), ("Accept", accept)]), remoteAddress: from)
        request.isSecure = secure
        return request
    }

    private func target(_ request: HTTPRequest, enabled: Bool = true, valid: Bool = true, hotspot: Bool = false, host: String? = "k7f2q9.box.camera-bridge.app") -> String? {
        SecureAddressRules.redirectTarget(for: request, host: host, enabled: enabled, certificateValid: valid, hotspotOpen: hotspot)
    }

    @Test func theRedirectSendsOnlyBrowsersOpeningAPageAtTheLocalName() {
        #expect(target(page("/#/settings")) == "https://k7f2q9.box.camera-bridge.app/#/settings")
        #expect(target(page("/cameras?x=1", method: "HEAD")) == "https://k7f2q9.box.camera-bridge.app/cameras?x=1")
        #expect(target(page(host: "camera-bridge.local:80")) != nil)
        // Never: the API (Apple Home's helpers, cbctl, health checks), the box itself, non-pages, IP addresses, other methods.
        #expect(target(page("/api/v1/health")) == nil && target(page("/api/v1/status", accept: "text/html")) == nil && target(page("/api")) == nil)
        #expect(target(page("/api/v1/health", from: "127.0.0.1")) == nil && target(page("/", from: "127.0.0.1")) == nil)
        #expect(target(page(accept: "application/json")) == nil && target(page(accept: "*/*")) == nil)
        #expect(target(page(host: "192.168.77.5")) == nil && target(page(host: "localhost")) == nil)
        #expect(target(page(method: "POST")) == nil)
        #expect(target(page(secure: true)) == nil)
        // Never without a switch, a valid certificate or a host; not while the setup hotspot is open.
        #expect(target(page(), enabled: false) == nil && target(page(), valid: false) == nil && target(page(), host: nil) == nil && target(page(), hotspot: true) == nil)
    }

    @Test func onlyALoopbackPeerIsTrustedToSpeakForTheTLSFront() {
        var request = page("/", host: "k7f2q9.box.camera-bridge.app", from: "127.0.0.1")
        request.headers["X-Forwarded-Proto"] = "https"
        request.headers["X-Forwarded-For"] = "192.168.77.20"
        let front = SecureAddressRules.normalized(request)
        #expect(front.isSecure && front.remoteAddress == "192.168.77.20")
        var forged = page("/", from: "192.168.77.20")
        forged.headers["X-Forwarded-Proto"] = "https"
        forged.headers["X-Forwarded-For"] = "192.168.77.99"
        let plain = SecureAddressRules.normalized(forged)
        #expect(!plain.isSecure && plain.remoteAddress == "192.168.77.20", "anyone else on the network could write those headers")
        #expect(!SecureAddressRules.normalized(page(from: "127.0.0.1")).isSecure, "the box's own tools stay plain")
    }

    @Test func retriesGrowAndRenewalStartsEarly() {
        #expect((1...7).map { SecureAddressRules.retryDelay(attempts: $0) } == [600, 1800, 3600, 10_800, 21_600, 21_600, 21_600])
        let host = "h.box.camera-bridge.app"
        #expect(SecureAddressRules.needsCertificate(CertificateStatus(state: "none"), host: host, now: Self.now))
        #expect(!SecureAddressRules.needsCertificate(CertificateStatus(state: "working"), host: host, now: Self.now))
        #expect(SecureAddressRules.needsCertificate(CertificateStatus(state: "ready", host: "other.box.camera-bridge.app", notAfter: Self.now.addingTimeInterval(80 * 86_400)), host: host, now: Self.now))
        #expect(!SecureAddressRules.isValid(CertificateStatus(state: "ready", host: host, notAfter: Self.now.addingTimeInterval(-1)), host: host, now: Self.now))
    }

    // MARK: Through the web interface

    @Test func theWebInterfaceRedirectsPagesAndTheSecureNameIsAllowedOnlyAsItself() async throws {
        let harness = try Harness()
        defer { harness.directory.remove() }
        harness.system.certificate.set(CertificateStatus(state: "ready", host: "k7f2q9.box.camera-bridge.app", notAfter: Date().addingTimeInterval(40 * 86_400)))
        let state = SecureAddressState(name: "k7f2q9", host: "k7f2q9.box.camera-bridge.app", address: "192.168.77.5")
        state.save(to: harness.directory.url)
        // A new app reads the saved state; the first report fills the snapshot from the system's certificate.
        let app = WebApp(configuration: WebConfiguration(dataDirectory: harness.directory.url, port: 0, loopbackOnly: true, passwordIterations: 1_000),
                         backend: harness.backend, system: harness.system, logs: harness.logs)
        _ = await app.secureAddress.report()
        func ask(_ host: String, _ path: String = "/", accept: String = "text/html", from: String = "192.168.77.20", forwarded: Bool = false) async -> HTTPResponse {
            var headers = HTTPHeaders([("Host", host), ("Accept", accept)])
            if forwarded { headers.add("X-Forwarded-Proto", "https"); headers.add("X-Forwarded-For", "192.168.77.20") }
            return await app.handle(HTTPRequest(method: "GET", target: path, headers: headers, remoteAddress: from))
        }
        let moved = await ask("camera-bridge.local")
        #expect(moved.status == 302 && moved.headers["Location"] == "https://k7f2q9.box.camera-bridge.app/")
        #expect(await ask("camera-bridge.local", "/api/v1/health", accept: "application/json").status == 200, "the API is never redirected")
        #expect(await ask("192.168.77.5").status != 302)
        #expect(await ask("k7f2q9.box.camera-bridge.app", from: "127.0.0.1", forwarded: true).status != 421, "its own name is allowed")
        #expect(await ask("k7f2q9.box.camera-bridge.app").status != 421)
        #expect(await ask("other.box.camera-bridge.app").status == 421, "no other name under it is")
        await app.secureAddress.setRedirect(false)
        #expect(await ask("camera-bridge.local").status != 302)
    }

    @Test func theSecureCookieComesOnlyThroughTheTLSFront() async throws {
        let harness = try Harness()
        defer { harness.directory.remove() }
        func setup(secure: Bool) async -> String {
            var headers = HTTPHeaders([("Host", "camera-bridge.local"), ("Content-Type", "application/json")])
            var from = "192.168.77.20"
            if secure { headers.add("X-Forwarded-Proto", "https"); headers.add("X-Forwarded-For", "192.168.77.20"); headers["Origin"] = "https://camera-bridge.local"; from = "127.0.0.1" }
            let body = Data(#"{"password":"correct horse","bridgeName":"B"}"#.utf8)
            let response = await harness.app.handle(HTTPRequest(method: "POST", target: "/api/v1/auth/setup", headers: headers, body: body, remoteAddress: from))
            return response.headers.values(for: "Set-Cookie").first ?? "none"
        }
        #expect(await setup(secure: true).hasSuffix("; Secure"))
    }

    @Test func theRoutesAnswerForASignedInPerson() async throws {
        let harness = try Harness()
        defer { harness.directory.remove() }
        let session = try await harness.signIn()
        var report = await session.get("/api/v1/system/secure-address")
        #expect(report.status == 200 && report.json["available"] as? Bool == false)
        report = await session.send("POST", "/api/v1/system/secure-address/redirect", json: ["enabled": false])
        #expect(report.status == 200 && report.json["redirect"] as? Bool == false)
        let check = await session.send("POST", "/api/v1/system/secure-address/check", json: [:])
        #expect(check.status == 200 && (check.json["rebind"] as? [String: Any])?["state"] as? String == "no_internet")
        #expect(await harness.send("GET", "/api/v1/system/secure-address").status == 401)
    }
}
