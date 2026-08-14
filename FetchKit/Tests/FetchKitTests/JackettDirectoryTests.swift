import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Splitting a Jackett server into the indexers it actually has.
///
/// The fixture is trimmed from a real `t=indexers` response: two indexers, one
/// with nested `<subcat>`s and a tracker-specific category, one with neither.
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

    // MARK: - Parsing

    @Test func everyConfiguredIndexerBecomesARowWithItsOwnName() throws {
        let indexers = try JackettIndexersParser.parse(Self.roster)
        #expect(indexers.map(\.id) == ["nyaasi", "yts"])
        #expect(indexers.map(\.name) == ["Nyaa.si", "YTS"])
    }

    /// **The failure this pins.** `<caps>` carries `<server title="Jackett" />`
    /// on every single indexer. A parser that took any `title` it found would
    /// name all eleven rows "Jackett" — which is precisely the one-row-called-
    /// Jackett problem this whole thing exists to fix, reproduced in miniature.
    @Test func theServerTitleInsideCapsIsNotTheIndexersName() throws {
        let indexers = try JackettIndexersParser.parse(Self.roster)
        #expect(!indexers.contains { $0.name == "Jackett" })
    }

    /// Categories belong to the indexer that declared them. A single flat
    /// accumulator would hand each one the union of all of them — the
    /// aggregate's answer, and the thing being taken apart here.
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

    // MARK: - The 200 that means no

    /// **The bug that made all of this look broken.** A wrong API key answers
    /// with HTTP 200 and this 89-byte document — well-formed XML with no
    /// indexers in it. Read as an empty roster, `IndexerSetup.plan` concluded
    /// "not a Jackett", fell back to the single aggregate, and saved a server
    /// showing one row called Jackett with no error anywhere on screen.
    private static let rejectedKey = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <error code="100" description="Invalid API Key" />
    """.utf8)

    /// `SearchError` is not `Equatable`, so the expectation is written out
    /// rather than passed to `#expect(throws:)`.
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

    /// The same document reaches caps resolution, where it parsed into a
    /// capability set with nothing in it — and `TorznabEndpointResolver`
    /// reported that as a connected server.
    @Test func arejectedKeyIsUnauthorizedFromCapsToo() {
        expectUnauthorized { try TorznabCapsParser.parse(Self.rejectedKey) }
    }

    /// And a search, where an indexer with a bad key looked like one that
    /// simply found nothing, on every query.
    @Test func arejectedKeyIsUnauthorizedFromASearchToo() {
        expectUnauthorized {
            try TorznabFeedParser.parse(
                Self.rejectedKey, providerID: SearchProviderID(rawValue: "x"))
        }
    }

    /// Non-credential codes stay distinguishable — sending the user to
    /// re-copy a key that is fine is its own kind of wrong.
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

    /// A real feed must not be derailed by the word appearing inside an item.
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

    // MARK: - Endpoints

    /// Every Jackett configured before discovery existed stores the **aggregate
    /// endpoint** as its root, so both shapes have to reach the same place.
    /// Appending to the untrimmed one produced `…/torznab/api/api/v2.0/…`.
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

    /// A host whose *name* contains a trimmed word must survive: the trim is on
    /// path components, not on the URL as a string.
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

    /// Built from the saved aggregate too, since that is what a configured
    /// server hands in.
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
        // A Prowlarr per-indexer endpoint is not, and must keep being taken at
        // its word rather than sent to a Jackett roster it has no answer for.
        #expect(!JackettDirectory.isJackettShaped(URL(string: "http://10.0.0.181:9696/6/api")!))
    }

    // MARK: - What the info icon says

    @Test func theCapabilitySummaryGroupsByTreeAndDropsTrackerSpecificIDs() throws {
        let indexers = try JackettIndexersParser.parse(Self.roster)
        let subject = SubIndexer(
            id: SearchProviderID(rawValue: "nyaasi"),
            name: "Nyaa.si",
            torznabURL: URL(string: "http://localhost:9117/x/api")!,
            advertisedCategories: indexers[0].categories)

        // 140679 is Jackett's own id for Nyaa's Anime shelf: real, stored, and
        // meaningless to anyone reading a tooltip.
        #expect(subject.advertisedCategorySummary == "TV · TV/Anime\nBooks")
    }

    @Test func anIndexerWithNothingRecordedHasNoSummaryRatherThanAnEmptyOne() {
        let subject = SubIndexer(
            id: SearchProviderID(rawValue: "a"), name: "A",
            torznabURL: URL(string: "http://localhost:9117/x/api")!)
        #expect(subject.advertisedCategorySummary == nil)
    }
}
