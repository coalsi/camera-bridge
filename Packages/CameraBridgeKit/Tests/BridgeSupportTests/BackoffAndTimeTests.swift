import Foundation
import Testing
@testable import BridgeSupport

@Suite struct BackoffTests {
    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test func growsGeometricallyAndCaps() {
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60), multiplier: 2, jitter: 0)
        let observed = (0..<9).map { _ in seconds(backoff.next()) }
        #expect(observed == [1, 2, 4, 8, 16, 32, 60, 60, 60])
    }

    @Test func resetStartsOver() {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(10), multiplier: 3, jitter: 0)
        _ = backoff.next(); _ = backoff.next(); _ = backoff.next()
        backoff.reset()
        #expect(seconds(backoff.next()) == 0.5)
        #expect(seconds(backoff.next()) == 1.5)
    }

    @Test func jitterStaysWithinBoundsAndNeverExceedsMaximum() {
        for _ in 0..<200 {
            var backoff = Backoff(initial: .seconds(1), maximum: .seconds(5), multiplier: 2, jitter: 0.2)
            let first = seconds(backoff.next())
            #expect(first >= 0.8 && first <= 1.2)
            for _ in 0..<10 { #expect(seconds(backoff.next()) <= 5) }
        }
    }
}

@Suite struct NTPTimeTests {
    @Test func unixEpochIsSeventyYearsAfterNTPEpoch() {
        #expect(NTPTime.timestamp(for: Date(timeIntervalSince1970: 0)) == UInt64(2_208_988_800) << 32)
    }

    @Test func halfSecondFraction() {
        let ntp = NTPTime.timestamp(for: Date(timeIntervalSince1970: 0.5))
        #expect(ntp & 0xFFFF_FFFF == 0x8000_0000)
    }

    @Test func roundTrip() {
        let date = Date(timeIntervalSince1970: 1_790_000_000.123456)
        let back = NTPTime.date(from: NTPTime.timestamp(for: date))
        #expect(abs(back.timeIntervalSince(date)) < 1e-6)
    }

    /// RFC 5905 era 1 starts at 2036-02-07 06:28:16 UTC; only the seconds within the era are carried.
    @Test func wrapsIntoLaterEras() {
        let eraOneStart = 4_294_967_296.0 - 2_208_988_800
        #expect(NTPTime.timestamp(for: Date(timeIntervalSince1970: eraOneStart)) == 0)
        #expect(NTPTime.timestamp(for: Date(timeIntervalSince1970: eraOneStart + 5.5)) == (5 << 32) | 0x8000_0000)
    }

    @Test func extremeDatesNeverTrap() {
        for seconds in [1e19, 1e300, -1e19, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
            _ = NTPTime.timestamp(for: Date(timeIntervalSince1970: seconds))
        }
        #expect(NTPTime.timestamp(for: Date(timeIntervalSince1970: .infinity)) == 0)
        #expect(NTPTime.timestamp(for: Date(timeIntervalSince1970: .nan)) == 0)
        #expect(NTPTime.timestamp(for: Date(timeIntervalSince1970: -3e9)) == 0)   // before 1900
        _ = NTPTime.timestamp(for: .distantFuture)
        _ = NTPTime.timestamp(for: .distantPast)
    }
}

@Suite struct AsyncBroadcasterTests {
    @Test func deliversToEverySubscriber() async {
        let broadcaster = AsyncBroadcaster<Int>()
        let a = broadcaster.subscribe()
        let b = broadcaster.subscribe()
        #expect(broadcaster.subscriberCount == 2)
        for i in 1...3 { broadcaster.yield(i) }
        broadcaster.finish()
        var gotA: [Int] = []; for await v in a { gotA.append(v) }
        var gotB: [Int] = []; for await v in b { gotB.append(v) }
        #expect(gotA == [1, 2, 3])
        #expect(gotB == [1, 2, 3])
        #expect(broadcaster.subscriberCount == 0)
    }

    @Test func subscribeAfterFinishIsImmediatelyFinished() async {
        let broadcaster = AsyncBroadcaster<String>()
        broadcaster.finish()
        var count = 0
        for await _ in broadcaster.subscribe() { count += 1 }
        #expect(count == 0)
    }

    @Test func cancelledSubscriberIsRemoved() async {
        let broadcaster = AsyncBroadcaster<Int>(bufferingNewest: 4)
        let task = Task {
            var n = 0
            for await _ in broadcaster.subscribe() { n += 1 }
            return n
        }
        while broadcaster.subscriberCount == 0 { await Task.yield() }
        task.cancel()
        _ = await task.value
        var spins = 0
        while broadcaster.subscriberCount != 0 && spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(broadcaster.subscriberCount == 0)
    }

    @Test func bufferingNewestDropsOldest() async {
        let broadcaster = AsyncBroadcaster<Int>(bufferingNewest: 2)
        let s = broadcaster.subscribe()
        for i in 1...5 { broadcaster.yield(i) }
        broadcaster.finish()
        var got: [Int] = []; for await v in s { got.append(v) }
        #expect(got == [4, 5])
    }
}
