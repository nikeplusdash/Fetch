import Testing
import Foundation
@testable import FetchKit

@Suite struct RetryPolicyTests {
    let policy = RetryPolicy(maxAttempts: 3, base: 0.5, cap: 8.0)

    @Test(arguments: [500, 502, 503])
    func retriesServerErrors(_ status: Int) {
        #expect(policy.decide(.status(status, retryAfter: nil), attempt: 1).shouldRetry)
    }

    @Test(arguments: [400, 401, 403, 404, 422])
    func doesNotRetryClientErrors(_ status: Int) {
        #expect(!policy.decide(.status(status, retryAfter: nil), attempt: 1).shouldRetry)
    }

    @Test func retriesRateLimitAndHonorsRetryAfter() {
        let decision = policy.decide(.status(429, retryAfter: 12), attempt: 1)
        #expect(decision.shouldRetry)
        #expect(decision.delay == 12)
    }

    @Test func rateLimitWithoutRetryAfterUsesBackoff() {
        let decision = policy.decide(.status(429, retryAfter: nil), attempt: 1)
        #expect(decision.shouldRetry)
        #expect(decision.delay <= 8.0)
    }

    @Test(arguments: [
        URLError.Code.timedOut, .networkConnectionLost,
        .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
    ]) func retriesTransientTransportErrors(_ code: URLError.Code) {
        #expect(policy.decide(.transport(URLError(code)), attempt: 1).shouldRetry)
    }

    @Test func doesNotRetryCancellation() {
        #expect(!policy.decide(.transport(URLError(.cancelled)), attempt: 1).shouldRetry)
    }

    @Test func doesNotRetryDecodingFailures() {
        #expect(!policy.decide(.decoding, attempt: 1).shouldRetry)
    }

    @Test func stopsAtMaxAttempts() {
        #expect(!policy.decide(.status(500, retryAfter: nil), attempt: 3).shouldRetry)
    }

    @Test func backoffIsBoundedByCap() {
        for attempt in 1...10 {
            let decision = policy.decide(.status(500, retryAfter: nil), attempt: attempt)
            #expect(decision.delay <= 8.0)
            #expect(decision.delay >= 0)
        }
    }
}
