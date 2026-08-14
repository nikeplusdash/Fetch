import Foundation

/// Injectable clock so backoff tests run instantly instead of sleeping.
public protocol RetryClock: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

public struct SystemRetryClock: RetryClock {
    public init() {}
    public func sleep(for duration: TimeInterval) async throws {
        // max(0,...) is load-bearing: UInt64(negative) traps, and a delay
        // ultimately derived from a server header must never crash us.
        try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
    }
}

public enum RetryOutcome: Sendable {
    case status(Int, retryAfter: TimeInterval?)
    case transport(URLError)
    /// No producer yet — `HTTPClient` only ever builds `.status` and
    /// `.transport`. Kept because it states the policy a decode failure
    /// should get when one is wired: a malformed body will not become
    /// well-formed on a second try. `RetryPolicyTests` pins that.
    case decoding
}

public struct RetryDecision: Sendable {
    public let shouldRetry: Bool
    public let delay: TimeInterval
}

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let base: TimeInterval
    public let cap: TimeInterval

    public init(maxAttempts: Int = 3, base: TimeInterval = 0.5, cap: TimeInterval = 8.0) {
        self.maxAttempts = maxAttempts
        self.base = base
        self.cap = cap
    }

    private static let retriableCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost,
        .dnsLookupFailed, .notConnectedToInternet,
    ]

    public func decide(_ outcome: RetryOutcome, attempt: Int) -> RetryDecision {
        guard attempt < maxAttempts else { return .init(shouldRetry: false, delay: 0) }

        switch outcome {
        case .decoding:
            return .init(shouldRetry: false, delay: 0)

        case .transport(let error):
            guard Self.retriableCodes.contains(error.code) else {
                return .init(shouldRetry: false, delay: 0)
            }
            return .init(shouldRetry: true, delay: backoff(attempt))

        case .status(let status, let retryAfter):
            if status == 429 {
                // An explicit Retry-After always wins over computed backoff.
                return .init(shouldRetry: true, delay: retryAfter ?? backoff(attempt))
            }
            guard (500...599).contains(status) else {
                return .init(shouldRetry: false, delay: 0)
            }
            return .init(shouldRetry: true, delay: backoff(attempt))
        }
    }

    /// Full jitter: random(0, min(cap, base * 2^attempt)). Jitter prevents a
    /// fleet of retries from synchronizing into a thundering herd.
    private func backoff(_ attempt: Int) -> TimeInterval {
        let ceiling = min(cap, base * pow(2.0, Double(attempt)))
        return Double.random(in: 0...ceiling)
    }
}
