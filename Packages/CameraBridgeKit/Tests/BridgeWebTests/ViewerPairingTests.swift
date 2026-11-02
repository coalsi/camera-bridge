import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

/// The pairing requests of Apple TVs (`ViewerPairing`): the code, the limits, the ten minutes and the key that is handed out once. Every
/// time is passed in, so nothing here waits.
@Suite struct ViewerPairingTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = String(repeating: "b2", count: 32)

    /// `seconds` after `t0`.
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A TV as the list shows it; `id` is one hex digit repeated, so two TVs differ by it.
    private func viewer(_ name: String, id: Character = "a") -> AuthStore.ViewerInfo {
        AuthStore.ViewerInfo(id: String(repeating: String(id), count: 32), name: name, device: "Apple TV 4K (3rd generation)", created: t0)
    }

    @Test func codesAreEightLettersWithoutVowels() {
        var seen = Set<Character>()
        for _ in 0..<2_000 {
            let code = ViewerPairing.randomCode()
            #expect(code.count == 8 && code.allSatisfy { ViewerPairing.alphabet.contains($0) }, "\(code)")
            seen.formUnion(code)
        }
        #expect(String(ViewerPairing.alphabet) == "BCDFGHJKLMNPQRSTVWXZ")
        #expect(seen == Set(ViewerPairing.alphabet), "all 20 letters turn up")
        #expect(ViewerPairing.displayed("BCDFGHJK") == "BCDF-GHJK")
    }

    @Test func typedCodesMatchIgnoringCaseSpacesAndTheDash() {
        for typed in ["bcdf-ghjk", " BCDF GHJK ", "bcdfghjk", "BCDF-GHJK", "\tbcdf\u{A0}ghjk\n"] {
            #expect(ViewerPairing.normalized(typed) == "BCDFGHJK", "\(typed.debugDescription)")
        }
        for typed in ["BCDFGHJ", "BCDFGHJKL", "ABCD-EFGH", "BCDF_GHJK", "", "-", "   "] {
            #expect(ViewerPairing.normalized(typed) == nil, "\(typed.debugDescription)")
        }
    }

    @Test func anOpenRequestsCodeIsNeverHandedOutAgain() throws {
        let answers = Box(["BCDFGHJK", "BCDFGHJK", "LMNPQRST"])
        var pairing = ViewerPairing()
        pairing.makeCode = { answers.update { $0.removeFirst() } }
        let first = try pairing.open(name: "Living Room", device: nil, address: "192.0.2.40", now: t0)
        let second = try pairing.open(name: "Bedroom", device: nil, address: "192.0.2.41", now: t0)
        #expect(first.code == "BCDFGHJK")
        #expect(second.code == "LMNPQRST", "the second TV was dealt the first one's code and drew again")
        #expect(answers.value.isEmpty)
        let hex = Set("0123456789abcdef")
        for request in [first, second] {
            #expect(request.id.count == 32 && request.id.allSatisfy { hex.contains($0) }, "\(request.id)")
            #expect(request.secret.count == 64 && request.secret.allSatisfy { hex.contains($0) }, "\(request.secret)")
        }
        #expect(first.id != second.id && first.secret != second.secret)

        // Its own letters, when nothing is stubbed.
        var real = ViewerPairing()
        let drawn = try (0..<20).map { try real.open(name: "Apple TV", device: nil, address: "192.0.2.\(100 + $0 / 3)", now: t0) }
        #expect(drawn.allSatisfy { ViewerPairing.normalized($0.code) == $0.code })
        #expect(Set(drawn.map(\.code)).count == 20 && Set(drawn.map(\.id)).count == 20 && Set(drawn.map(\.secret)).count == 20)
    }

    @Test func threeOpenPerAddressAndTwentyInAll() throws {
        var pairing = ViewerPairing()
        func open(_ address: String, at seconds: TimeInterval = 0) throws -> ViewerPairing.Request {
            try pairing.open(name: "Apple TV", device: nil, address: address, now: at(seconds))
        }
        for _ in 0..<3 { _ = try open("192.0.2.40") }
        #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 500)) { _ = try open("192.0.2.40", at: 100) }
        #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 2), "whole seconds, rounded up") { _ = try open("192.0.2.40", at: 598.5) }
        #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 1), "never 0") { _ = try open("192.0.2.40", at: 599.5) }
        #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 500), "an IPv4 address written as IPv6 is the same address") {
            _ = try open("::ffff:192.0.2.40", at: 100)
        }

        for last in 1...3 { _ = try open("2001:db8:1:2::\(last)") }
        #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 500), "one network is one address") { _ = try open("2001:db8:1:2::99", at: 100) }
        _ = try open("2001:db8:1:3::1")

        // Requests that came later end later: the wait is until the first of them ends.
        for start in [0.0, 100, 200] { _ = try open("192.0.2.60", at: start) }
        #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 300)) { _ = try open("192.0.2.60", at: 300) }

        for index in 0..<10 { _ = try open("192.0.2.\(50 + index / 3)") }
        #expect(pairing.openCount == 20)
        #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 350), "twenty are open, so a new address waits too") {
            _ = try open("192.0.2.99", at: 250)
        }

        // The first ones end at t0 + 600: their places are free again, and the new ones count from their own start.
        for _ in 0..<3 { _ = try open("192.0.2.40", at: 601) }
        #expect(throws: AuthStore.PairingFailure.busy(retryAfter: 600)) { _ = try open("192.0.2.40", at: 601) }
    }

    @Test func aRequestLastsTenMinutes() throws {
        var pairing = ViewerPairing()
        let request = try pairing.open(name: "Living Room", device: nil, address: "192.0.2.40", now: t0)
        #expect(request.expires == at(600))
        #expect(pairing.waiting(code: request.code, now: at(599))?.id == request.id)
        #expect(pairing.status(request: request.id, secret: request.secret, now: at(599)) == .waiting)
        #expect(pairing.expire(now: at(599)).isEmpty && pairing.openCount == 1, "not over yet")

        #expect(pairing.waiting(code: request.code, now: at(600)) == nil, "ten minutes are up at the tenth")
        #expect(pairing.status(request: request.id, secret: request.secret, now: at(600)) == .gone)
        #expect(pairing.waiting(code: request.code, now: at(601)) == nil)
        #expect(pairing.status(request: request.id, secret: request.secret, now: at(601)) == .gone)
        #expect(pairing.openCount == 1, "an ended request stays until expire takes it out")
        #expect(pairing.expire(now: at(601)).isEmpty, "nobody was approved, so there is no TV to remove")
        #expect(pairing.openCount == 0)
    }

    @Test func theKeyIsHandedOutOnceToTheRightSecret() throws {
        var pairing = ViewerPairing()
        let request = try pairing.open(name: "Living Room", device: nil, address: "192.0.2.40", now: t0)
        let tv = viewer("Living Room")
        pairing.approve(requestID: request.id, token: key, viewer: tv, now: at(30))
        #expect(pairing.waiting(code: request.code, now: at(31)) == nil, "an approved code opens nothing a second time")

        #expect(pairing.status(request: request.id, secret: String(repeating: "0", count: 64), now: at(32)) == .gone, "a wrong secret")
        #expect(pairing.status(request: String(repeating: "0", count: 32), secret: request.secret, now: at(32)) == .gone, "a wrong request")
        #expect(pairing.openCount == 1, "neither takes the request away from the TV")
        let collected = pairing.status(request: request.id, secret: request.secret, now: at(300))
        #expect(collected == .approved(token: key, viewer: tv), "approving early does not shorten the ten minutes")
        #expect(pairing.status(request: request.id, secret: request.secret, now: at(301)) == .gone, "asked again")
        #expect(pairing.openCount == 0)
    }

    @Test func anApprovalWaitsAMinuteForItsTV() throws {
        var pairing = ViewerPairing()
        let late = try pairing.open(name: "Late", device: nil, address: "192.0.2.40", now: t0)
        let early = try pairing.open(name: "Early", device: nil, address: "192.0.2.41", now: t0)
        let tooSlow = try pairing.open(name: "Too slow", device: nil, address: "192.0.2.42", now: t0)
        let lateTV = viewer("Late", id: "a"), earlyTV = viewer("Early", id: "c"), tooSlowTV = viewer("Too slow", id: "d")
        pairing.approve(requestID: late.id, token: key, viewer: lateTV, now: at(590))   // ten seconds before its ten minutes are up
        pairing.approve(requestID: early.id, token: key, viewer: earlyTV, now: at(10))   // nobody asks for this key
        pairing.approve(requestID: tooSlow.id, token: key, viewer: tooSlowTV, now: at(590))
        #expect(pairing.waiting(code: late.code, now: at(591)) == nil)

        // The early one ends with the ten minutes, and its TV, which the approval added, is for the caller to remove.
        #expect(pairing.expire(now: at(599)).isEmpty)
        #expect(pairing.expire(now: at(600)) == [earlyTV.id])
        #expect(pairing.openCount == 2)
        #expect(pairing.expire(now: at(601)).isEmpty, "said once")

        // The late one lasts a minute from its approval: the TV's next question still gets the key.
        #expect(pairing.status(request: late.id, secret: late.secret, now: at(640)) == .approved(token: key, viewer: lateTV))
        // A minute, no more.
        #expect(pairing.status(request: tooSlow.id, secret: tooSlow.secret, now: at(651)) == .gone)
        #expect(pairing.expire(now: at(651)) == [tooSlowTV.id], "asking too late does not forget it: the TV is still to be removed")
        #expect(pairing.openCount == 0)
    }

    @Test func forgettingATVDropsItsWaitingApproval() throws {
        var pairing = ViewerPairing()
        let removed = try pairing.open(name: "Removed", device: nil, address: "192.0.2.40", now: t0)
        let kept = try pairing.open(name: "Kept", device: nil, address: "192.0.2.41", now: t0)
        let removedTV = viewer("Removed", id: "a"), keptTV = viewer("Kept", id: "c")
        pairing.approve(requestID: removed.id, token: key, viewer: removedTV, now: at(10))
        pairing.approve(requestID: kept.id, token: key, viewer: keptTV, now: at(10))

        pairing.forget(viewerID: removedTV.id)
        #expect(pairing.status(request: removed.id, secret: removed.secret, now: at(11)) == .gone)
        #expect(pairing.status(request: kept.id, secret: kept.secret, now: at(11)) == .approved(token: key, viewer: keptTV))
        #expect(pairing.expire(now: at(700)).isEmpty, "a TV the owner removed is not reported to be removed again")
        pairing.forget(viewerID: "nobody")
        #expect(pairing.openCount == 0)
    }

    @Test func anApprovalOnlyLandsOnAnOpenRequestNobodyApprovedYet() throws {
        var pairing = ViewerPairing()
        let request = try pairing.open(name: "Living Room", device: nil, address: "192.0.2.40", now: t0)
        pairing.approve(requestID: "no such request", token: key, viewer: viewer("Nobody"), now: at(1))
        #expect(pairing.status(request: request.id, secret: request.secret, now: at(2)) == .waiting)

        let first = viewer("First", id: "a")
        pairing.approve(requestID: request.id, token: key, viewer: first, now: at(3))
        pairing.approve(requestID: request.id, token: String(repeating: "c3", count: 32), viewer: viewer("Second", id: "c"), now: at(4))
        let collected = pairing.status(request: request.id, secret: request.secret, now: at(5))
        #expect(collected == .approved(token: key, viewer: first), "the first approval stands")

        // Ended is ended, even before `expire` removes it.
        let ended = try pairing.open(name: "Ended", device: nil, address: "192.0.2.41", now: t0)
        pairing.approve(requestID: ended.id, token: key, viewer: viewer("Ended", id: "d"), now: at(601))
        #expect(pairing.status(request: ended.id, secret: ended.secret, now: at(602)) == .gone, "the minute does not bring back a request that ended")
        #expect(pairing.expire(now: at(602)).isEmpty)
    }
}
