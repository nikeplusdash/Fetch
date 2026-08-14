import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Prowlarr exposes one Torznab endpoint per indexer and no aggregate, so the
/// only way to make a pasted Prowlarr root usable is to ask it what indexers
/// it has. `/api/v1/indexer` is that list.
@Suite(.serialized, .usesStubURLProtocol) struct ProwlarrDirectoryTests {

    /// Trimmed to the fields that matter; the live payload carries ~30 more
    /// per indexer, which must be ignored rather than break decoding.
    static let indexerJSON = """
    [
      { "id": 6, "name": "The Pirate Bay", "enable": true, "protocol": "torrent",
        "indexerUrls": ["https://thepiratebay.org/"], "priority": 25 },
      { "id": 1, "name": "dmhy", "enable": true, "protocol": "torrent" },
      { "id": 9, "name": "Retired Tracker", "enable": false, "protocol": "torrent" }
    ]
    """

    private func makeClient() -> HTTPClient {
        HTTPClient(
            session: StubURLProtocol.makeSession(),
            policy: RetryPolicy(maxAttempts: 1),
            clock: TestClock())
    }

    private func discover(_ raw: String) async throws -> [ProwlarrDirectory.Indexer] {
        try await ProwlarrDirectory.discover(
            root: URL(string: raw)!, apiKey: Redacted("test-key"), client: makeClient())
    }

    @Test func listsOnlyEnabledIndexers() async throws {
        StubURLProtocol.reset([.json(Self.indexerJSON)])

        let indexers = try await discover("http://10.0.0.181:9696")

        #expect(indexers.map(\.name) == ["The Pirate Bay", "dmhy"])
    }

    @Test func discoveryHitsTheProwlarrIndexerAPIWithTheKey() async throws {
        StubURLProtocol.reset([.json(Self.indexerJSON)])

        _ = try await discover("http://10.0.0.181:9696")

        let url = try #require(StubURLProtocol.recordedRequests().first?.url)
        #expect(url.path == "/api/v1/indexer")
        #expect(url.query?.contains("apikey=test-key") == true)
    }

    /// The whole point of discovery: each indexer becomes a real, per-indexer
    /// Torznab endpoint — the shape the spec documents as
    /// `http://localhost:9696/{id}/api`.
    @Test func eachIndexerBecomesAPerIndexerTorznabEndpoint() async throws {
        StubURLProtocol.reset([.json(Self.indexerJSON)])

        let indexers = try await discover("http://10.0.0.181:9696")

        #expect(indexers.first?.torznabURL(root: URL(string: "http://10.0.0.181:9696")!)
            .absoluteString == "http://10.0.0.181:9696/6/api")
    }

    @Test func trailingSlashRootDoesNotProduceADoubleSlashEndpoint() async throws {
        StubURLProtocol.reset([.json(Self.indexerJSON)])

        let indexers = try await discover("http://10.0.0.181:9696/")

        #expect(indexers.first?.torznabURL(root: URL(string: "http://10.0.0.181:9696/")!)
            .absoluteString == "http://10.0.0.181:9696/6/api")
    }

    /// Jackett answers 404 here. Discovery must fail cleanly so the caller can
    /// fall back to the Jackett path rather than treating it as a hard error.
    @Test func aNonProwlarrServerFailsDiscovery() async throws {
        StubURLProtocol.reset([.init(status: 404, body: Data())])

        await #expect(throws: (any Error).self) {
            _ = try await self.discover("http://10.0.0.181:9117")
        }
    }

    @Test func aRejectedKeyIsReportedAsUnauthorized() async throws {
        StubURLProtocol.reset([.init(status: 401, body: Data())])

        do {
            _ = try await discover("http://10.0.0.181:9696")
            Issue.record("expected failure")
        } catch let error as SearchError {
            guard case .unauthorized = error else {
                Issue.record("got \(error), want .unauthorized")
                return
            }
        }
    }
}

/// The single entry point Settings uses: given whatever the user typed, work
/// out what to actually configure.
@Suite(.serialized, .usesStubURLProtocol) struct IndexerSetupTests {

    static let capsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps>
      <searching><search available="yes" supportedParams="q"/></searching>
      <categories><category id="2000" name="Movies"/></categories>
    </caps>
    """

    private func makeClient() -> HTTPClient {
        HTTPClient(
            session: StubURLProtocol.makeSession(),
            policy: RetryPolicy(maxAttempts: 1),
            clock: TestClock())
    }

    private func plan(_ raw: String) async throws -> IndexerSetup.Plan {
        try await IndexerSetup.plan(
            url: URL(string: raw)!, apiKey: Redacted("test-key"), client: makeClient())
    }

    @Test func aProwlarrRootPlansOneEndpointPerIndexer() async throws {
        StubURLProtocol.reset([.json(ProwlarrDirectoryTests.indexerJSON)])

        guard case .prowlarr(_, let indexers) = try await plan("http://10.0.0.181:9696") else {
            Issue.record("expected a Prowlarr plan")
            return
        }
        #expect(indexers.count == 2)
    }

    /// A complete endpoint is taken at its word and never sent through
    /// discovery — this is the shape the spec already documented.
    @Test func aCompleteEndpointPlansASingleProvider() async throws {
        StubURLProtocol.reset([.json(Self.capsXML)])

        guard case .single(let url, _) = try await plan("http://10.0.0.181:9696/6/api") else {
            Issue.record("expected a single-provider plan")
            return
        }
        #expect(url.absoluteString == "http://10.0.0.181:9696/6/api")
    }

    /// Jackett: discovery 404s, so planning must fall through to the Torznab
    /// path rather than giving up.
    @Test func aJackettRootFallsBackToTheAggregateTorznabPath() async throws {
        StubURLProtocol.reset([
            .init(status: 404, body: Data()),
            .json(Self.capsXML),
        ])

        guard case .single(let url, _) = try await plan("http://10.0.0.181:9117") else {
            Issue.record("expected a single-provider plan")
            return
        }
        #expect(url.absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")
    }

    @Test func aServerThatIsNeitherReportsANotATorznabEndpointError() async throws {
        StubURLProtocol.reset([.init(
            status: 200,
            headers: ["Content-Type": "text/html"],
            body: Data("<!DOCTYPE html><html><body>nope</body></html>".utf8))])

        do {
            _ = try await plan("http://10.0.0.181:8080")
            Issue.record("expected failure")
        } catch let error as SearchError {
            guard case .notATorznabEndpoint = error else {
                Issue.record("got \(error), want .notATorznabEndpoint")
                return
            }
        }
    }
}
