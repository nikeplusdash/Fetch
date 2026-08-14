import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct TorznabProviderTests {
    static let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"

    static let fullCapsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps>
      <limits max="100"/>
      <searching>
        <search available="yes" supportedParams="q"/>
        <tv-search available="yes" supportedParams="q,season,ep,tvdbid,rid"/>
        <movie-search available="yes" supportedParams="q,imdbid,genre"/>
      </searching>
      <categories>
        <category id="5000" name="TV"/>
        <category id="2000" name="Movies"/>
      </categories>
    </caps>
    """

    static let searchOnlyCapsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps>
      <searching>
        <search available="yes" supportedParams="q"/>
      </searching>
      <categories/>
    </caps>
    """

    static func searchRSS(title: String, hash: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
          <channel>
            <item>
              <title>\(title)</title>
              <torznab:attr name="infohash" value="\(hash)"/>
              <torznab:attr name="seeders" value="12"/>
              <torznab:attr name="category" value="5000"/>
            </item>
          </channel>
        </rss>
        """
    }

    private func makeProvider() -> TorznabProvider {
        TorznabProvider(
            id: SearchProviderID(rawValue: "jackett-local"),
            displayName: "Jackett",
            baseURL: URL(string: "http://localhost:9117/api/v2.0/indexers/all/results/torznab/api")!,
            apiKey: Redacted("test-key"),
            client: HTTPClient(
                session: StubURLProtocol.makeSession(),
                policy: RetryPolicy(maxAttempts: 1),
                clock: TestClock()
            )
        )
    }

    @Test func capabilitiesParsesCapsAndSendsCorrectQuery() async throws {
        StubURLProtocol.reset([.json(Self.fullCapsXML)])
        let caps = try await makeProvider().capabilities()
        #expect(caps.supportedModes.contains(.tvsearch))

        let query = try #require(StubURLProtocol.recordedRequests().first?.url?.query)
        #expect(query.contains("t=caps"))
        #expect(query.contains("apikey=test-key"))
    }

    @Test func searchAlwaysSendsExtended1() async throws {
        StubURLProtocol.reset([
            .json(Self.fullCapsXML),
            .json(Self.searchRSS(title: "Some Movie", hash: Self.hashA)),
        ])
        _ = try await makeProvider().search(SearchQuery(text: "Some Movie"))

        let requests = StubURLProtocol.recordedRequests()
        #expect(requests.count == 2)
        let searchRequest = try #require(requests.last?.url?.query)
        #expect(searchRequest.contains("extended=1"))
    }

    @Test func generalQueryWithSeasonEpisodeUpgradesToTVSearchWhenSupported() async throws {
        StubURLProtocol.reset([
            .json(Self.fullCapsXML),
            .json(Self.searchRSS(title: "The Expanse S03E05", hash: Self.hashA)),
        ])
        _ = try await makeProvider().search(SearchQuery(text: "The Expanse S03E05"))

        let query = try #require(StubURLProtocol.recordedRequests().last?.url?.query)
        #expect(query.contains("t=tvsearch"))
        #expect(query.contains("season=3"))
        #expect(query.contains("ep=5"))
        #expect(query.contains("q=The%20Expanse") || query.contains("q=The+Expanse"))
    }

    @Test func fallsBackToPlainSearchWhenIndexerOnlyAdvertisesSearch() async throws {
        StubURLProtocol.reset([
            .json(Self.searchOnlyCapsXML),
            .json(Self.searchRSS(title: "The Expanse S03E05", hash: Self.hashA)),
        ])
        _ = try await makeProvider().search(SearchQuery(text: "The Expanse S03E05"))

        let query = try #require(StubURLProtocol.recordedRequests().last?.url?.query)
        #expect(query.contains("t=search"))
        #expect(!query.contains("t=tvsearch"))
        // Original, unstripped text — the indexer only understands free text.
        #expect(query.contains("q=The%20Expanse%20S03E05") || query.contains("q=The+Expanse+S03E05"))
    }

    @Test func explicitTVModeSendsStructuredParamsWhenSupported() async throws {
        StubURLProtocol.reset([
            .json(Self.fullCapsXML),
            .json(Self.searchRSS(title: "The Expanse", hash: Self.hashA)),
        ])
        _ = try await makeProvider().search(
            SearchQuery(text: "The Expanse", mode: .tv(season: 3, episode: 5, tvdbID: 154_507))
        )

        let query = try #require(StubURLProtocol.recordedRequests().last?.url?.query)
        #expect(query.contains("t=tvsearch"))
        #expect(query.contains("season=3"))
        #expect(query.contains("ep=5"))
        #expect(query.contains("tvdbid=154507"))
    }

    @Test func explicitMovieModeSendsImdbIDWhenSupported() async throws {
        StubURLProtocol.reset([
            .json(Self.fullCapsXML),
            .json(Self.searchRSS(title: "Blade Runner 2049", hash: Self.hashA)),
        ])
        _ = try await makeProvider().search(
            SearchQuery(text: "Blade Runner 2049", mode: .movie(imdbID: "tt1856101"))
        )

        let query = try #require(StubURLProtocol.recordedRequests().last?.url?.query)
        #expect(query.contains("t=movie"))
        #expect(query.contains("imdbid=tt1856101"))
    }

    @Test func categoriesJoinedAsCommaSeparatedIDs() async throws {
        StubURLProtocol.reset([
            .json(Self.fullCapsXML),
            .json(Self.searchRSS(title: "x", hash: Self.hashA)),
        ])
        _ = try await makeProvider().search(
            SearchQuery(text: "x", categories: [
                TorznabCategory(id: 2000, name: "Movies"), TorznabCategory(id: 5000, name: "TV"),
            ])
        )

        let query = try #require(StubURLProtocol.recordedRequests().last?.url?.query)
        #expect(query.contains("cat=2000%2C5000") || query.contains("cat=2000,5000"))
    }

    @Test func limitAndOffsetAreSent() async throws {
        StubURLProtocol.reset([
            .json(Self.fullCapsXML),
            .json(Self.searchRSS(title: "x", hash: Self.hashA)),
        ])
        _ = try await makeProvider().search(SearchQuery(text: "x", limit: 25, offset: 50))

        let query = try #require(StubURLProtocol.recordedRequests().last?.url?.query)
        #expect(query.contains("limit=25"))
        #expect(query.contains("offset=50"))
    }

    @Test func resultsCarryResolvedCategoryNames() async throws {
        StubURLProtocol.reset([
            .json(Self.fullCapsXML),
            .json(Self.searchRSS(title: "Categorized", hash: Self.hashA)),
        ])
        let results = try await makeProvider().search(SearchQuery(text: "Categorized"))
        #expect(results.first?.category == TorznabCategory(id: 5000, name: "TV"))
    }

    @Test func apiKeyNeverAppearsInAnyLoggableErrorDescription() async {
        StubURLProtocol.reset([.init(status: 401, body: Data())])
        await #expect(throws: SearchError.self) {
            _ = try await makeProvider().capabilities()
        }
    }

    @Test func http401MapsToUnauthorized() async throws {
        StubURLProtocol.reset([.init(status: 401, body: Data())])
        do {
            _ = try await makeProvider().capabilities()
            Issue.record("expected SearchError.unauthorized")
        } catch SearchError.unauthorized {
            // expected
        } catch {
            Issue.record("expected .unauthorized, got \(error)")
        }
    }

    /// A config saved before endpoint resolution existed can still point at a
    /// web UI. Searching with it must say so, not surface `XMLParser`'s
    /// `NSXMLParserErrorDomain Code=76` as if the indexer had sent bad XML.
    @Test func anHTMLBodyIsReportedAsAWebUINotAMalformedFeed() async throws {
        StubURLProtocol.reset([.init(
            status: 200,
            headers: ["Content-Type": "text/html"],
            body: Data("<!DOCTYPE html>\n<html><body>Prowlarr</body></html>".utf8))])

        do {
            _ = try await makeProvider().capabilities()
            Issue.record("expected SearchError.notATorznabEndpoint")
        } catch SearchError.notATorznabEndpoint {
            // expected
        } catch {
            Issue.record("expected .notATorznabEndpoint, got \(error)")
        }
    }
}
