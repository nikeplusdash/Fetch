import Testing
import Foundation
@testable import FetchKit

private struct Payload: Codable, Equatable { let value: Int }

@Suite(.serialized, .usesStubURLProtocol) struct HTTPClientTests {
    private func makeClient(clock: TestClock = TestClock()) -> HTTPClient {
        HTTPClient(
            session: StubURLProtocol.makeSession(),
            policy: RetryPolicy(maxAttempts: 3, base: 0.01, cap: 0.02),
            clock: clock
        )
    }

    private var endpoint: Endpoint {
        Endpoint(baseURL: URL(string: "https://api.example.com")!, path: "/thing")
    }

    @Test func decodesSuccessfulResponse() async throws {
        StubURLProtocol.reset([.json(#"{"value":42}"#)])
        let result = try await makeClient().send(endpoint, as: Payload.self)
        #expect(result == Payload(value: 42))
    }

    @Test func retriesServerErrorThenSucceeds() async throws {
        StubURLProtocol.reset([
            .json("{}", status: 500),
            .json(#"{"value":7}"#),
        ])
        let result = try await makeClient().send(endpoint, as: Payload.self)
        #expect(result == Payload(value: 7))
        #expect(StubURLProtocol.recordedRequests().count == 2)
    }

    @Test func doesNotRetryClientError() async {
        StubURLProtocol.reset([.json(#"{"detail":"nope"}"#, status: 401)])
        await #expect(throws: NetworkError.self) {
            _ = try await makeClient().send(endpoint, as: Payload.self)
        }
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func honorsRetryAfterHeaderOn429() async throws {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 429, headers: ["Retry-After": "5"]),
            .json(#"{"value":1}"#),
        ])
        let clock = TestClock()
        _ = try await makeClient(clock: clock).send(endpoint, as: Payload.self)
        #expect(await clock.recordedSleeps() == [5.0])
    }

    @Test func decodingFailureIsNotRetried() async {
        StubURLProtocol.reset([.json("not json at all")])
        await #expect(throws: NetworkError.self) {
            _ = try await makeClient().send(endpoint, as: Payload.self)
        }
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func appliesHeadersAndQueryItems() async throws {
        StubURLProtocol.reset([.json(#"{"value":1}"#)])
        let endpoint = Endpoint(
            baseURL: URL(string: "https://api.example.com")!,
            path: "/thing",
            queryItems: [URLQueryItem(name: "hash", value: "abc")],
            headers: ["Authorization": "Bearer secret"]
        )
        _ = try await makeClient().send(endpoint, as: Payload.self)

        let request = try #require(StubURLProtocol.recordedRequests().first)
        #expect(request.url?.query?.contains("hash=abc") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func transientTransportErrorIsRetried() async throws {
        StubURLProtocol.reset([
            StubURLProtocol.Response(error: URLError(.timedOut)),
            .json(#"{"value":3}"#),
        ])
        let result = try await makeClient().send(endpoint, as: Payload.self)
        #expect(result == Payload(value: 3))
        #expect(StubURLProtocol.recordedRequests().count == 2)
    }

    @Test func cancellationIsNotRetriedAndMapsToCancelled() async {
        StubURLProtocol.reset([StubURLProtocol.Response(error: URLError(.cancelled))])
        await #expect(throws: NetworkError.self) {
            _ = try await makeClient().send(endpoint, as: Payload.self)
        }
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func persistent500ExhaustsRetriesThenThrows() async {
        StubURLProtocol.reset([.json("{}", status: 500)])
        await #expect(throws: NetworkError.self) {
            _ = try await makeClient().send(endpoint, as: Payload.self)
        }
        #expect(StubURLProtocol.recordedRequests().count == 3)   // maxAttempts
    }

    @Test func persistent429ThrowsRateLimited() async {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 429, headers: ["Retry-After": "0"])
        ])
        await #expect(throws: NetworkError.self) {
            _ = try await makeClient().send(endpoint, as: Payload.self)
        }
        #expect(StubURLProtocol.recordedRequests().count == 3)
    }

    /// A hostile Retry-After must never reach the clock as a negative value —
    /// UInt64(negative) traps and takes the process down.
    @Test func negativeRetryAfterIsClampedNotCrashed() async throws {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 429, headers: ["Retry-After": "-1"]),
            .json(#"{"value":9}"#),
        ])
        let clock = TestClock()
        let result = try await makeClient(clock: clock).send(endpoint, as: Payload.self)
        #expect(result == Payload(value: 9))
        #expect(await clock.recordedSleeps().allSatisfy { $0 >= 0 })
    }

    /// The User-Agent is load-bearing: TorBox is behind Cloudflare and 403s
    /// some default agents. Tests use a stub session, so without this check a
    /// removal would go unnoticed.
    @Test func defaultSessionPinsUserAgent() {
        let headers = HTTPClient.makeDefaultSession().configuration.httpAdditionalHeaders
        #expect(headers?["User-Agent"] as? String == "Fetch/1.0 (macOS)")
    }

    @Test func errorDescriptionNeverContainsTheRequestURL() {
        let secret = "https://api.torbox.app/v1/api/torrents/requestdl?token=SUPERSECRET"
        let err = NetworkError.transport(
            URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: secret)!]))
        #expect(!"\(err)".contains("SUPERSECRET"))
    }

    @Test func repeatedQueryItemsAreAllSent() async throws {
        StubURLProtocol.reset([.json(#"{"value":1}"#)])
        let endpoint = Endpoint(
            baseURL: URL(string: "https://api.example.com")!,
            path: "/thing",
            queryItems: [
                URLQueryItem(name: "hash", value: "a"),
                URLQueryItem(name: "hash", value: "b"),
            ]
        )
        _ = try await makeClient().send(endpoint, as: Payload.self)

        let query = try #require(StubURLProtocol.recordedRequests().first?.url?.query)
        #expect(query.contains("hash=a"))
        #expect(query.contains("hash=b"))
    }
}
