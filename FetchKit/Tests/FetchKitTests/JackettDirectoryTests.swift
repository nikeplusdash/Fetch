import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct JackettDirectoryTests {
    private static let roster = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <indexers>
      <indexer id="nyaasi" configured="true">
        <title>Nyaa.si</title>
        <description>Nyaa.si is a Public site.</description>
        <language>en-US</language>
        <type>public</type>
        <caps>
          <server title="Jackett" />
          <limits default="100" max="1000" />
          <searching>
            <search available="yes" supportedParams="q" />
            <tv-search available="yes" supportedParams="q,season,ep" />
          </searching>
          <categories>
            <category id="5000" name="TV">
              <subcat id="5070" name="TV/Anime" />
            </category>
            <category id="7000" name="Books" />
            <category id="140679" name="Anime" />
          </categories>
        </caps>
      </indexer>
      <indexer id="yts" configured="true">
        <title>YTS</title>
        <caps>
          <server title="Jackett" />
          <categories>
            <category id="2000" name="Movies">
              <subcat id="2040" name="Movies/HD" />
              <subcat id="2045" name="Movies/UHD" />
            </category>
          </categories>
        </caps>
      </indexer>
    </indexers>
    """.utf8)


    @Test func everyConfiguredIndexerBecomesARowWithItsOwnName() throws {
        let indexers = try JackettIndexersParser.parse(Self.roster)
        #expect(indexers.map(\.id) == ["nyaasi", "yts"])
        #expect(indexers.map(\.name) == ["Nyaa.si", "YTS"])
    }

    @Test func theServerTitleInsideCapsIsNotTheIndexersName() throws {
        let indexers = try JackettIndexersParser.parse(Self.roster)
        #expect(!indexers.contains { $0.name == "Jackett" })
    }

    @Test func categoriesStayWithTheIndexerThatDeclaredThem() throws {
        let indexers = try JackettIndexersParser.parse(Self.roster)
        #expect(Set(indexers[0].categories.map(\.id)) == [5000, 5070, 7000, 140679])
        #expect(Set(indexers[1].categories.map(\.id)) == [2000, 2040, 2045])
    }

    @Test func nestedSubcategoriesAreFlattenedAlongsideTheirParent() throws {
        let indexers = try JackettIndexersParser.parse(Self.roster)
        let yts = indexers[1].categories.map(\.name).sorted()
        #expect(yts == ["Movies", "Movies/HD", "Movies/UHD"])
    }

    @Test func malformedXMLIsAnErrorRatherThanAnEmptyRoster() {
        #expect(throws: SearchError.self) {
            try JackettIndexersParser.parse(Data("<indexers><indexer".utf8))
        }
    }


    private static let rejectedKey = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <error code="100" description="Invalid API Key" />
    """.utf8)

    private func expectUnauthorized(
        _ body: () throws -> Any, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try body()
            Issue.record("expected .unauthorized, nothing was thrown", sourceLocation: sourceLocation)
        } catch SearchError.unauthorized {
        } catch {
            Issue.record("expected .unauthorized, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func arejectedKeyIsAnUnauthorizedErrorRatherThanAnEmptyRoster() {
        expectUnauthorized { try JackettIndexersParser.parse(Self.rejectedKey) }
    }

    @Test func arejectedKeyIsUnauthorizedFromCapsToo() {
        expectUnauthorized { try TorznabCapsParser.parse(Self.rejectedKey) }
    }

    @Test func arejectedKeyIsUnauthorizedFromASearchToo() {
        expectUnauthorized {
            try TorznabFeedParser.parse(
                Self.rejectedKey, providerID: SearchProviderID(rawValue: "x"))
        }
    }

    @Test func aNonCredentialErrorCodeIsNotReportedAsABadKey() {
        let missingParameter = Data("""
        <error code="200" description="Missing parameter" />
        """.utf8)
        #expect(throws: SearchError.self) {
            try TorznabCapsParser.parse(missingParameter)
        }
        do {
            _ = try TorznabCapsParser.parse(missingParameter)
        } catch SearchError.unauthorized {
            Issue.record("a missing parameter is not a rejected key")
        } catch {}
    }

    @Test func anItemIsNotAnErrorDocument() throws {
        let feed = Data("""
        <rss><channel><item><title>error</title>
        <link>magnet:?xt=urn:btih:0000000000000000000000000000000000000000</link>
        </item></channel></rss>
        """.utf8)
        let results = try TorznabFeedParser.parse(
            feed, providerID: SearchProviderID(rawValue: "x"))
        #expect(results.count == 1)
    }


    @Test func theServiceRootIsFoundFromEitherShape() {
        let host = URL(string: "http://10.0.0.181:9117")!
        let aggregate = URL(
            string: "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")!
        #expect(JackettDirectory.serviceRoot(of: host).absoluteString
            == "http://10.0.0.181:9117")
        #expect(JackettDirectory.serviceRoot(of: aggregate).absoluteString
            == "http://10.0.0.181:9117")
    }

    @Test func aTrailingSlashAndAQueryAreNotPartOfTheRoot() {
        let messy = URL(string: "http://10.0.0.181:9117/?apikey=secret#/settings")!
        #expect(JackettDirectory.serviceRoot(of: messy).absoluteString
            == "http://10.0.0.181:9117")
    }

    @Test func onlyPathComponentsAreTrimmedNeverTheHost() {
        let url = URL(string: "https://indexers.example.com/api/v2.0/indexers")!
        #expect(JackettDirectory.serviceRoot(of: url).absoluteString
            == "https://indexers.example.com")
    }

    @Test func aPerIndexerEndpointIsTheAggregateWithTheIdInPlaceOfAll() {
        let root = URL(string: "http://10.0.0.181:9117")!
        let indexer = JackettDirectory.Indexer(id: "thepiratebay", name: "The Pirate Bay")
        #expect(indexer.torznabURL(root: root).absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/thepiratebay/results/torznab/api")
    }

    @Test func aPerIndexerEndpointIsBuiltFromASavedAggregateWithoutDoublingThePath() {
        let saved = URL(
            string: "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")!
        let indexer = JackettDirectory.Indexer(id: "nyaasi", name: "Nyaa.si")
        #expect(indexer.torznabURL(root: saved).absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/nyaasi/results/torznab/api")
    }

    @Test func aSavedAggregateIsRecognisedAsJackettShaped() {
        #expect(JackettDirectory.isJackettShaped(URL(
            string: "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")!))
        #expect(!JackettDirectory.isJackettShaped(URL(string: "http://10.0.0.181:9696/6/api")!))
    }


    @Test func theCapabilitySummaryGroupsByTreeAndDropsTrackerSpecificIDs() throws {
        let indexers = try JackettIndexersParser.parse(Self.roster)
        let subject = SubIndexer(
            id: SearchProviderID(rawValue: "nyaasi"),
            name: "Nyaa.si",
            torznabURL: URL(string: "http://localhost:9117/x/api")!,
            advertisedCategories: indexers[0].categories)

        #expect(subject.advertisedCategorySummary == "TV · TV/Anime\nBooks")
    }

    @Test func anIndexerWithNothingRecordedHasNoSummaryRatherThanAnEmptyOne() {
        let subject = SubIndexer(
            id: SearchProviderID(rawValue: "a"), name: "A",
            torznabURL: URL(string: "http://localhost:9117/x/api")!)
        #expect(subject.advertisedCategorySummary == nil)
    }
}
