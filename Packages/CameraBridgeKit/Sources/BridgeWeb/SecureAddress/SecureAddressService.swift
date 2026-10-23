import BridgeEngine
import BridgeSupport
import Foundation
import Synchronization

/// What the web interface may read at any moment without waiting (the redirect and the Host check run on every request).
final class SecureAddressSnapshot: Sendable {
    struct Value: Sendable {
        var host: String?
        var redirect = true
        var certificateValid = false
    }
    private let value = Mutex(Value())
    var current: Value { value.withLock { $0 } }
    func update(_ change: (inout Value) -> Void) { value.withLock { change(&$0) } }
}

/// The secure address, from the box's side: it registers with the Camera Bridge website once, keeps the website told of its home
/// address, and asks the system (`obtainCertificate`, the `tls-obtain` request) for a certificate when there is none and 30 days before
/// it expires, with growing waits after a failure. The certificate's key is made on the box by the system; the website only writes DNS
/// records. Only a system with a TLS front takes part (`certificateStatus() != nil`).
actor SecureAddressService {
    struct Problem: Encodable, Equatable, Sendable {
        /// `no_internet`, `service_not_ready`, `rate_limited`, `refused`, `certificate`.
        var code: String
        var message: String
    }

    struct Rebind: Encodable, Equatable, Sendable {
        /// `ok`, `blocked` (the router hides names that point into the home), `no_internet`, `wrong_address`.
        var state: String
        var message: String
        var checkedAt: Date
    }

    struct Report: Encodable, Equatable, Sendable {
        var available: Bool
        /// `off` (not registered yet), `waiting` (registered, certificate on its way), `ready`, `error`.
        var state: String
        var host: String?
        var url: String?
        var address: String?
        var expiresOn: Date?
        var renewsOn: Date?
        var redirect: Bool
        var redirectActive: Bool
        var problem: Problem?
        var rebind: Rebind?
    }

    static let interval: Duration = .seconds(60)

    private let backend: any BridgeBackend
    private let system: any SystemControlling
    private let directory: URL
    private let client: BoxClient
    private let resolver: @Sendable (String) async -> [String]
    private let now: @Sendable () -> Date
    private let log = Log(category: "secure-address")
    nonisolated let snapshot = SecureAddressSnapshot()
    private var state: SecureAddressState
    private var identity: BoxIdentity?
    private var status: CertificateStatus?
    private var problem: Problem?
    private var rebind: Rebind?
    private var available = false
    private var loop: Task<Void, Never>?

    init(backend: any BridgeBackend, system: any SystemControlling, directory: URL, client: BoxClient? = nil,
         resolver: @escaping @Sendable (String) async -> [String] = { name in await Task.detached { SecureAddressService.resolve(name) }.value }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.system = system
        self.directory = directory
        let loaded = SecureAddressState.load(from: directory)
        state = loaded
        self.client = client ?? BoxClient()
        self.client.seed(loaded.lastTimestamp)
        self.resolver = resolver
        self.now = now
        snapshot.update { $0.host = loaded.host; $0.redirect = loaded.redirect }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: The work

    /// One round: register if needed, tell the website the home address if it changed, ask for a certificate if one is due.
    func tick() async {
        status = await system.certificateStatus()
        available = status != nil
        guard let status else { return refreshSnapshot() }
        problem = nil
        if let wait = state.websiteWaitUntil, wait > now() { return refreshSnapshot() }   // left alone after the website failed
        do {
            if state.name == nil { try await register() }
            guard let name = state.name, let host = state.host else { return refreshSnapshot() }
            try await sendAddressIfChanged(name: name)
            if status.state == "failed", let message = status.message, !message.isEmpty, state.attempts > 0 {
                problem = Problem(code: "certificate", message: "The certificate could not be obtained: \(message)")
            }
            try await requestCertificateIfDue(status, name: name, host: host)
            state.websiteFailures = nil
            state.websiteWaitUntil = nil
        } catch let error as BoxClientError {
            problem = Self.problem(for: error)
            // Every failed answer (a server error reads as `refused`) waits: never once a minute.
            let failures = (state.websiteFailures ?? 0) + 1
            state.websiteFailures = failures
            state.websiteWaitUntil = SecureAddressRules.websiteWait(after: error.kind, failures: failures, now: now())
            log.warning("secure address: \(error.message)")
        } catch {
            problem = Problem(code: "refused", message: "The secure address could not be set up. The box will try again.")
            log.warning("secure address: \(ErrorText.logDescription(error))")
        }
        persist()
        refreshSnapshot()
    }

    private func register() async throws {
        let identity = try await loadIdentity()
        let registration = try await client.register(publicKey: identity.publicKeyBase64)
        state.name = registration.name
        state.host = registration.host
        state.attempts = 0
        state.nextAttempt = nil
        persist()
        log.notice("registered for the secure address \(registration.host)")
    }

    private func loadIdentity() async throws -> BoxIdentity {
        if let identity { return identity }
        if let stored = try await BoxIdentity.load(from: backend) {
            identity = stored
            return stored
        }
        let made = BoxIdentity()
        try await made.store(in: backend)
        identity = made
        return made
    }

    private func sendAddressIfChanged(name: String) async throws {
        guard let ip = SecureAddressRules.homeAddress(among: await backend.localIPv4Addresses(), previous: state.address), ip != state.address else { return }
        let identity = try await loadIdentity()
        defer { state.lastTimestamp = client.lastSentTimestamp }
        try await client.sendAddress(ip, as: (name, identity.key))
        state.address = ip
        log.notice("told the website the home address changed")
    }

    private func requestCertificateIfDue(_ status: CertificateStatus, name: String, host: String) async throws {
        if SecureAddressRules.isValid(status, host: host, now: now()), status.state == "ready", !SecureAddressRules.needsCertificate(status, host: host, now: now()) {
            state.attempts = 0
            state.nextAttempt = nil
            return
        }
        guard SecureAddressRules.needsCertificate(status, host: host, now: now()), state.address != nil else { return }
        if let next = state.nextAttempt, next > now() { return }
        let identity = try await loadIdentity()
        state.attempts += 1
        state.nextAttempt = now().addingTimeInterval(SecureAddressRules.retryDelay(attempts: state.attempts))
        persist()
        do {
            try await system.obtainCertificate(name: name, host: host, privateKeyPEM: identity.privateKeyPEM)
        } catch {
            throw BoxClientError(kind: .refused, message: "The box’s system did not take the request for a certificate. It will try again.")
        }
    }

    static func problem(for error: BoxClientError) -> Problem {
        switch error.kind {
        case .unreachable: Problem(code: "no_internet", message: error.message)
        case .notReady: Problem(code: "service_not_ready", message: error.message)
        case .rateLimited: Problem(code: "rate_limited", message: error.message)
        case .refused, .unauthorized: Problem(code: "refused", message: error.message)
        }
    }

    // MARK: For the page

    func setRedirect(_ enabled: Bool) {
        state.redirect = enabled
        persist()
        refreshSnapshot()
    }

    /// Forget the waits and try now (the page's "Try again").
    func retryNow() async {
        state.nextAttempt = nil
        state.websiteWaitUntil = nil
        await tick()
    }

    func report() async -> Report {
        status = await system.certificateStatus()
        available = status != nil
        refreshSnapshot()
        let valid = SecureAddressRules.isValid(status, host: state.host, now: now())
        let waiting = state.host != nil && !valid
        let shownState = problem != nil && !valid ? "error" : valid ? "ready" : waiting ? "waiting" : "off"
        let expires = valid ? status?.notAfter : nil
        return Report(available: available, state: available ? shownState : "off", host: state.host, url: state.host.map { "https://\($0)" }, address: state.address,
                      expiresOn: expires, renewsOn: expires.map { $0.addingTimeInterval(-SecureAddressRules.renewBefore) }, redirect: state.redirect,
                      redirectActive: state.redirect && valid, problem: problem, rebind: rebind)
    }

    /// The self-test for routers that hide names pointing into the home (DNS rebind protection): ask this box's own resolver for the
    /// secure address and see whether the home address comes back.
    func checkRebind() async -> Rebind {
        let at = now()
        let result: Rebind
        if let host = state.host, let address = state.address {
            let answers = await resolver(host)
            if answers.contains(address) {
                result = Rebind(state: "ok", message: "Your router gives out the secure address.", checkedAt: at)
            } else if !answers.isEmpty {
                result = Rebind(state: "wrong_address", message: "The name points to another address (\(answers[0])). The box tells the website its address when it changes; try again in a minute.", checkedAt: at)
            } else if await resolver("www.camera-bridge.app").isEmpty {
                result = Rebind(state: "no_internet", message: "The box can’t look up names on the internet right now, so this can’t be tested.", checkedAt: at)
            } else {
                result = Rebind(state: "blocked", message: "Your router doesn’t give out names that point inside your home (DNS rebind protection).", checkedAt: at)
            }
        } else {
            result = Rebind(state: "no_internet", message: "The secure address isn’t set up yet, so there is nothing to test.", checkedAt: at)
        }
        rebind = result
        return result
    }

    private func refreshSnapshot() {
        let valid = SecureAddressRules.isValid(status, host: state.host, now: now())
        let host = state.host, redirect = state.redirect
        snapshot.update { $0.host = host; $0.redirect = redirect; $0.certificateValid = valid }
    }

    private func persist() {
        state.lastTimestamp = max(state.lastTimestamp, client.lastSentTimestamp)
        state.save(to: directory)
    }

    /// Addresses `name` resolves to through the system resolver (IPv4 only); empty when it does not resolve.
    static func resolve(_ name: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    var sin = pointer.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &sin, &buffer, socklen_t(buffer.count))
                }
                let text = String(cString: buffer)
                if !found.contains(text) { found.append(text) }
            }
            cursor = entry.pointee.ai_next
        }
        return found
    }
}
