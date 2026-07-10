import Foundation
import Testing

@testable import TorrentKit

@Suite struct RateLimiterTests {
    /// A controllable clock so token accrual is deterministic (no wall-clock sleeps in the math).
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ start: Date) { t = start }
        func advance(_ seconds: TimeInterval) { lock.lock(); t += seconds; lock.unlock() }
        var date: Date { lock.lock(); defer { lock.unlock() }; return t }
    }

    @Test func unlimitedNeverWaits() async {
        let limiter = RateLimiter(bytesPerSecond: 0)
        #expect(await limiter.waitTime(for: 1_000_000) == 0)
        await limiter.consume(1_000_000)  // returns immediately
    }

    @Test func spendsInitialTokensThenRequiresRefill() async {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let limiter = RateLimiter(bytesPerSecond: 1000, now: { clock.date })
        // Starts with one second of tokens (1000).
        await limiter.consume(1000)
        // Now empty: 500 more bytes need half a second.
        #expect(abs(await limiter.waitTime(for: 500) - 0.5) < 0.001)
        // Advancing the clock accrues tokens.
        clock.advance(0.5)
        #expect(await limiter.waitTime(for: 500) == 0)
    }

    @Test func burstIsCappedAtOneSecond() async {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let limiter = RateLimiter(bytesPerSecond: 1000, now: { clock.date })
        await limiter.consume(1000)  // drain
        clock.advance(10)  // idle 10s, but the bucket caps at 1s worth
        #expect(await limiter.waitTime(for: 1000) == 0)  // exactly 1000 available
        #expect(abs(await limiter.waitTime(for: 2000) - 1.0) < 0.001)  // not 10000
    }

    @Test func setRateChangesLimit() async {
        let limiter = RateLimiter(bytesPerSecond: 1000)
        await limiter.setRate(bytesPerSecond: 0)
        #expect(await limiter.rate == 0)
        #expect(await limiter.waitTime(for: 10_000_000) == 0)  // now unlimited
    }
}
