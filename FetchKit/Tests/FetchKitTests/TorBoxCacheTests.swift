import Testing
import Foundation
@testable import FetchKit

@Suite(.serialized, .usesStubURLProtocol) struct TorBoxCacheTests {
    static let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    static let hashB = "aa1155ecdc7ca55fb0bbf81323d87062db1f6d99"

    private func makeProvider() -> TorBoxProvider {
        TorBoxProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(
                session: StubURLProtocol.makeSession(),
                policy: RetryPolicy(maxAttempts: 1),
                clock: TestClock()
            )
        )
    }

    @Test func mapsCachedHashesAndFillsInMisses() async throws {
        // Only hashA comes back — hashB is absent, meaning not cached.
        let json = """
        {"success":true,"detail":"ok","data":{"\(Self.hashA)":
        {"hash":"\(Self.hashA)","name":"Big Buck Bunny","size":355856562}}}
        """
        StubURLProtocol.reset([.json(json)])

        let result = try await makeProvider()
            .checkCached(hashes: [Self.hashA, Self.hashB], listFiles: false)

        #expect(result.count == 2)
        #expect(result[Self.hashA]?.name == "Big Buck Bunny")
        #expect(result[Self.hashB]?.size == 0)   // filled-in miss
    }

    @Test func sendsOneHashQueryItemPerHash() async throws {
        StubURLProtocol.reset([.json(#"{"success":true,"data":{}}"#)])
        _ = try await makeProvider()
            .checkCached(hashes: [Self.hashA, Self.hashB], listFiles: false)

        let query = try #require(StubURLProtocol.recordedRequests().first?.url?.query)
        #expect(query.contains("hash=\(Self.hashA)"))
        #expect(query.contains("hash=\(Self.hashB)"))
        #expect(query.contains("format=object"))
    }

    @Test func chunksAtFiftyHashesPerRequest() async throws {
        let hashes = (0..<120).map { String(format: "%040x", $0) }
        StubURLProtocol.reset([.json(#"{"success":true,"data":{}}"#)])

        let result = try await makeProvider().checkCached(hashes: hashes, listFiles: false)

        #expect(StubURLProtocol.recordedRequests().count == 3)   // 50 + 50 + 20
        #expect(result.count == 120)                   // all filled in as misses
    }

    @Test func successFalseOnHTTP200BecomesProviderRejected() async {
        StubURLProtocol.reset([
            .json(#"{"success":false,"detail":"Invalid API key","data":null}"#)
        ])
        await #expect(throws: DebridError.self) {
            _ = try await makeProvider().checkCached(hashes: [Self.hashA], listFiles: false)
        }
    }

    @Test func rejectionPrefersMachineReadableErrorCode() async {
        StubURLProtocol.reset([.json(
            #"{"success":false,"error":"DATABASE_ERROR","detail":"generic prose","data":null}"#)])
        await #expect(throws: DebridError.providerRejected(detail: "DATABASE_ERROR")) {
            _ = try await makeProvider().checkCached(hashes: [Self.hashA], listFiles: false)
        }
    }

    @Test func emptyHashListMakesNoRequest() async throws {
        StubURLProtocol.reset([.json(#"{"success":true,"data":{}}"#)])
        let result = try await makeProvider().checkCached(hashes: [], listFiles: false)
        #expect(result.isEmpty)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    @Test func apiKeyIsSentAsBearerAndNotInQuery() async throws {
        StubURLProtocol.reset([.json(#"{"success":true,"data":{}}"#)])
        _ = try await makeProvider().checkCached(hashes: [Self.hashA], listFiles: false)

        let request = try #require(StubURLProtocol.recordedRequests().first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.url?.query?.contains("test-key") != true)
    }
}
