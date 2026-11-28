import Foundation
import RemoteSources

/// Retries an operation the provider rate-limited (`RemoteSourceError.rateLimited`, which adapters raise for
/// `429`, `503`, and provider rate-limit errors), with exponential backoff and jitter. A `Retry-After` the
/// provider sends is honoured. See docs/REMOTE_SOURCES.md#robustness.
public struct RetryPolicy: Sendable {
    /// Attempts in total, the first included.
    public var maxAttempts: Int
    /// Seconds before the first retry; doubled for each later one.
    public var baseDelay: Double
    /// No wait is longer than this. A `Retry-After` beyond it isn't waited for: the error is rethrown.
    public var maxDelay: Double
    let sleep: @Sendable (Double) async throws -> Void
    /// A factor in 0.5…1 that spreads retries out, so many clients don't retry in step.
    let jitter: @Sendable () -> Double

    public init(
        maxAttempts: Int = 4,
        baseDelay: Double = 1,
        maxDelay: Double = 60,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1) }
    ) {
        self.maxAttempts = max(maxAttempts, 1)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.sleep = sleep
        self.jitter = jitter
    }

    public static let standard = RetryPolicy()

    /// Seconds to wait before retry number `retry` (1 for the first), or nil to give up.
    public func delay(beforeRetry retry: Int, retryAfter: Double?) -> Double? {
        guard retry < maxAttempts else { return nil }
        if let retryAfter {
            return retryAfter <= maxDelay ? max(retryAfter, 0) : nil
        }
        let exponential = baseDelay * pow(2, Double(retry - 1))
        return min(exponential, maxDelay) * min(max(jitter(), 0), 1)
    }

    /// Runs `operation`, retrying it while it throws `rateLimited` and attempts remain.
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var retry = 1
        while true {
            do {
                return try await operation()
            } catch RemoteSourceError.rateLimited(let retryAfter) {
                guard let seconds = delay(beforeRetry: retry, retryAfter: retryAfter) else {
                    throw RemoteSourceError.rateLimited(retryAfter: retryAfter)
                }
                try await sleep(seconds)
                retry += 1
            }
        }
    }
}
