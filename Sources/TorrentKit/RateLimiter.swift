import Foundation

/// A token-bucket rate limiter for throttling download requests and upload serving. `consume`
/// waits until enough tokens have accrued, so callers paced through it can't exceed the configured
/// bytes/second (0 means unlimited). Shared across sessions for a global cap. The clock is
/// injectable so the token math can be unit-tested without wall-clock sleeps.
public actor RateLimiter {
    private var bytesPerSecond: Double
    private var tokens: Double
    private var lastRefill: Date
    private let now: @Sendable () -> Date

    public init(bytesPerSecond: Int, now: @escaping @Sendable () -> Date = Date.init) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
        self.tokens = Double(max(0, bytesPerSecond))
        self.now = now
        self.lastRefill = now()
    }

    /// Change the cap (0 = unlimited). Resets accrued tokens to one second's worth.
    public func setRate(bytesPerSecond newRate: Int) {
        bytesPerSecond = Double(max(0, newRate))
        tokens = min(tokens, bytesPerSecond)
        lastRefill = now()
    }

    public var rate: Int { Int(bytesPerSecond) }

    /// Wait until `bytes` tokens are available, then spend them. Returns immediately when unlimited.
    public func consume(_ bytes: Int) async {
        guard bytesPerSecond > 0, bytes > 0 else { return }
        while true {
            refill()
            if tokens >= Double(bytes) {
                tokens -= Double(bytes)
                return
            }
            let waitSeconds = (Double(bytes) - tokens) / bytesPerSecond
            try? await Task.sleep(nanoseconds: UInt64(max(0.001, waitSeconds) * 1_000_000_000))
        }
    }

    /// How long `bytes` would have to wait right now (0 if immediately available). For tests.
    public func waitTime(for bytes: Int) -> TimeInterval {
        guard bytesPerSecond > 0 else { return 0 }
        refill()
        return tokens >= Double(bytes) ? 0 : (Double(bytes) - tokens) / bytesPerSecond
    }

    private func refill() {
        let current = now()
        let elapsed = current.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            // Cap the burst at one second's worth so a long idle period can't release a flood.
            tokens = min(bytesPerSecond, tokens + elapsed * bytesPerSecond)
            lastRefill = current
        }
    }
}
