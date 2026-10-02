import Foundation

enum RateLimiterTests {
    static func run() async {
        Check.section("Rate limiter")

        await Check.that("an unlimited bucket never waits") {
            let limiter = RateLimiter(bytesPerSecond: 0)
            let start = Date()
            for _ in 0..<50 { await limiter.consume(1_000_000) }
            return Date().timeIntervalSince(start) < 0.2
        }

        await Check.that("a limited bucket paces the bytes") {
            // 200 KiB/s, then spend 400 KiB: the burst covers the first second,
            // so the rest has to wait about another second.
            let limiter = RateLimiter(bytesPerSecond: 200 * 1024)
            let start = Date()
            for _ in 0..<25 { await limiter.consume(blockSize) }
            let elapsed = Date().timeIntervalSince(start)
            return elapsed > 0.7 && elapsed < 3.0
        }

        await Check.that("lifting the limit releases the waiters") {
            let limiter = RateLimiter(bytesPerSecond: 16 * 1024)
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await limiter.setLimit(bytesPerSecond: 0)
            }
            let start = Date()
            await limiter.consume(10 * 1024 * 1024)      // ten minutes at that limit
            return Date().timeIntervalSince(start) < 2.0
        }

        await Check.that("reports whether it is limiting") {
            let limiter = RateLimiter(bytesPerSecond: 1024)
            let limited = await limiter.isLimited
            await limiter.setLimit(bytesPerSecond: 0)
            let lifted = await limiter.isLimited
            return limited && !lifted
        }
    }
}
