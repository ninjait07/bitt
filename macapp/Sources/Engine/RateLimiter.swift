import Foundation

/// A token bucket shared by every torrent.
///
/// Trackers are told what moved this session, so limiting has to happen where
/// the bytes actually flow: before a block is sent, and before a block is asked
/// for. A zero limit means unlimited and costs nothing.
actor RateLimiter {
    /// Bytes per second; 0 means no limit.
    private(set) var limit = 0
    private var tokens: Double = 0
    private var lastRefill = Date().timeIntervalSinceReferenceDate

    /// Allow a short burst so a 16 KiB block is never starved by rounding.
    private var burst: Double { Double(max(limit, blockSize)) }

    init(bytesPerSecond: Int = 0) {
        limit = max(0, bytesPerSecond)
        tokens = Double(limit)
    }

    func setLimit(bytesPerSecond: Int) {
        limit = max(0, bytesPerSecond)
        tokens = min(tokens, burst)
    }

    var isLimited: Bool { limit > 0 }

    /// Wait until `count` bytes are within budget.
    func consume(_ count: Int) async {
        guard limit > 0 else { return }
        var remaining = Double(count)
        while remaining > 0 {
            refill()
            if tokens >= remaining {
                tokens -= remaining
                return
            }
            remaining -= max(tokens, 0)
            tokens = 0
            // Sleep for what the outstanding bytes are worth, with a floor so
            // this never becomes a spin loop.
            let seconds = max(remaining / Double(limit), 0.02)
            try? await Task.sleep(nanoseconds: UInt64(min(seconds, 1.0) * 1_000_000_000))
            if limit == 0 { return }   // the limit was lifted while we waited
        }
    }

    private func refill() {
        let now = Date().timeIntervalSinceReferenceDate
        let elapsed = now - lastRefill
        lastRefill = now
        guard limit > 0 else { return }
        tokens = min(burst, tokens + elapsed * Double(limit))
    }
}

/// The pair of buckets a session is given.
struct RateLimits: Sendable {
    let download: RateLimiter
    let upload: RateLimiter

    init(download: RateLimiter = RateLimiter(), upload: RateLimiter = RateLimiter()) {
        self.download = download
        self.upload = upload
    }
}
