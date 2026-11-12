import Foundation

/// The devices (Apple TVs, iPhones) that are asking to be added, held in memory only. Modeled on how TV apps sign in (RFC 8628's device flow),
/// local only: the device asks and shows the code it is given, the owner types that code into the page while signed in, and the device, asking
/// again every couple of seconds, is handed its key once.
///
/// - A code is 8 letters from an alphabet without vowels, so it spells no word, shown as `BCDF-GHJK`. Typed codes match ignoring case,
///   spaces and the dash, and no two open requests share one.
/// - A request lasts 10 minutes. At most 3 are open from one address (an IPv6 address counts by its /64, as for wrong passwords) and 20 in
///   all; the next is told how many seconds to wait.
/// - The TV asks again with `id` and `secret`, and a wrong secret changes nothing. The key is handed out once, with the answer that ends
///   the request. An approval waits a minute for its TV, even when it came in the last seconds of the ten; one nobody collects is reported
///   by `expire`, so the TV that was added with it can be removed again.
///
/// A value with no clock of its own, like `LoginLimiter`: every time is passed in, and `AuthStore` keeps the one copy. A request that has
/// ended is gone for every call here, but only `expire` takes it out, so the caller runs `expire` first and acts on what it returns.
struct ViewerPairing: Sendable {
    struct Policy: Sendable {
        /// How long a request is open.
        var lifetime: TimeInterval = 600
        /// An approval keeps its request open at least this long, for the TV's next question.
        var collectWindow: TimeInterval = 60
        var maximumPerAddress = 3
        var maximumOpen = 20
        /// Seconds the TV is told to wait between questions.
        var interval = 2
    }

    /// A request. The TV holds `id` and `secret`; the owner types `code`.
    struct Request: Sendable, Equatable {
        var id: String
        var secret: String
        /// Eight letters, without the dash.
        var code: String
        /// The TV's name and model, kept as they came.
        var name: String
        var device: String?
        /// Where the TV asked from.
        var address: String
        var expires: Date
        /// Set when the owner approved: kept until the TV asks for it.
        var approval: Approval?
    }

    /// The TV that approving added, and its key in plain: the only copy, kept only until the TV asks for it.
    struct Approval: Sendable, Equatable {
        var token: String
        var viewer: AuthStore.ViewerInfo
    }

    var policy: Policy
    /// Where a new request's code comes from: `open` asks again while the answer is one a request holds already (tests give it fixed answers).
    var makeCode: @Sendable () -> String = ViewerPairing.randomCode
    private var requests: [Request] = []

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Requests held: the open ones, and ended ones `expire` has not taken out yet.
    var openCount: Int { requests.count }

    // MARK: Codes

    /// Twenty consonants and no vowel, so a code spells no word.
    static let alphabet: [Character] = Array("BCDFGHJKLMNPQRSTVWXZ")
    static let codeLength = 8

    /// A code of `codeLength` letters, each drawn evenly from the system's secure generator.
    static func randomCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<codeLength).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    /// A code as a person reads it: "BCDF-GHJK".
    static func displayed(_ code: String) -> String {
        guard code.count > 4 else { return code }
        return "\(code.prefix(4))-\(code.dropFirst(4))"
    }

    /// What a person typed as a code, in the form a request keeps it: any case, with or without spaces and the dash. Nil when it cannot be a code.
    static func normalized(_ typed: String) -> String? {
        let letters = typed.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard letters.count == codeLength, letters.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return letters
    }

    // MARK: Requests

    /// Takes out the requests that have ended, and returns the ids of the TVs whose approval nobody collected: they were added when the
    /// owner approved, and nobody holds their keys.
    mutating func expire(now: Date) -> [String] {
        let ended = requests.filter { $0.expires <= now }
        requests.removeAll { $0.expires <= now }
        return ended.compactMap { $0.approval?.viewer.id }
    }

    /// A new request from a TV that asked from `address`, open for `policy.lifetime`. Throws `busy` when that address has
    /// `maximumPerAddress` requests open already, or `maximumOpen` are open in all, with the seconds until the first of them ends.
    mutating func open(name: String, device: String?, address: String, now: Date) throws -> Request {
        let live = requests.filter { $0.expires > now }
        let key = LoginLimiter.key(for: address)
        let theirs = live.filter { LoginLimiter.key(for: $0.address) == key }
        if theirs.count >= policy.maximumPerAddress { throw AuthStore.PairingFailure.busy(retryAfter: Self.wait(for: theirs, now: now)) }
        if live.count >= policy.maximumOpen { throw AuthStore.PairingFailure.busy(retryAfter: Self.wait(for: live, now: now)) }
        var code = makeCode()
        while requests.contains(where: { $0.code == code }) { code = makeCode() }
        let request = Request(id: Secrets.hex(Secrets.randomBytes(16)), secret: Secrets.hex(Secrets.randomBytes(32)), code: code, name: name,
                              device: device, address: address, expires: now.addingTimeInterval(policy.lifetime))
        requests.append(request)
        return request
    }

    /// Whole seconds until the first of `requests` ends: rounded up, and at least 1.
    private static func wait(for requests: [Request], now: Date) -> Int {
        guard let first = requests.map(\.expires).min() else { return 1 }
        return max(1, Int(first.timeIntervalSince(now).rounded(.up)))
    }

    /// The open request with this code (as `normalized` gives it) that nobody has approved.
    func waiting(code: String, now: Date) -> Request? {
        requests.first { $0.code == code && $0.approval == nil && $0.expires > now }
    }

    /// Records the owner's approval of the request `requestID`: `viewer` is the TV it added and `token` its key. The request then stays
    /// open at least `policy.collectWindow` from `now`, whatever is left of its ten minutes. Does nothing for a request that is not
    /// there, has ended, or was approved already.
    mutating func approve(requestID: String, token: String, viewer: AuthStore.ViewerInfo, now: Date) {
        guard let index = requests.firstIndex(where: { $0.id == requestID && $0.approval == nil && $0.expires > now }) else { return }
        requests[index].approval = Approval(token: token, viewer: viewer)
        requests[index].expires = max(requests[index].expires, now.addingTimeInterval(policy.collectWindow))
    }

    /// What the TV asking with `request` and `secret` is told. A request that is not there or has ended is `.gone`, and so is one asked
    /// about with a wrong secret, which leaves it as it was for the TV that has the right one. The answer that hands out the key ends the
    /// request.
    mutating func status(request id: String, secret: String, now: Date) -> AuthStore.PairingStatus {
        guard let index = requests.firstIndex(where: { $0.id == id && $0.expires > now }),
              Secrets.constantTimeEqual(requests[index].secret, secret) else { return .gone }
        guard let approval = requests[index].approval else { return .waiting }
        requests.remove(at: index)
        return .approved(token: approval.token, viewer: approval.viewer)
    }

    /// A TV the owner removed: the key waiting for it is not handed out, and its request is over.
    mutating func forget(viewerID: String) {
        requests.removeAll { $0.approval?.viewer.id == viewerID }
    }
}
