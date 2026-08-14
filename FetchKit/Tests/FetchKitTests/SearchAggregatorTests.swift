import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

private struct StubSearchProvider: SearchProvider {
    let id: SearchProviderID
    let displayName: String
    var results: [SearchResult] = []
    var error: (any Error)?
    var delay: TimeInterval = 0

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(categories: [], supportedModes: [.search], supportedAttributes: [], maxLimit: nil)
    }

    func search(_ query: SearchQuery) async throws -> [SearchResult] {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return results
    }
}

private func makeResult(
    hash: String,
    title: String,
    seeders: Int,
    source: SearchProviderID,
    rawAttributes: [String: String] = [:]
) -> SearchResult {
    SearchResult(
        infoHashHex: hash,
        title: title,
        size: 1000,
        seeders: seeders,
        peers: 0,
        grabs: nil,
        fileCount: nil,
        category: nil,
        publishDate: nil,
        magnetURI: "magnet:?xt=urn:btih:\(hash)",
        sources: [source],
        rawAttributes: rawAttributes
    )
}

@Suite struct SearchAggregatorTests {
    static let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    static let hashB = "aa1155ecdc7ca55fb0bbf81323d87062db1f6d99"
    static let hashC = "bb2266ecdc7ca55fb0bbf81323d87062db1f6d77"
    static let jackett = SearchProviderID(rawValue: "jackett")
    static let prowlarr = SearchProviderID(rawValue: "prowlarr")

    // MARK: - dedupe (unit, no concurrency)

    @Test func dedupeKeepsHighestSeederCount() {
        let low = makeResult(hash: Self.hashA, title: "Low", seeders: 5, source: Self.jackett)
        let high = makeResult(hash: Self.hashA, title: "High", seeders: 40, source: Self.prowlarr)

        let deduped = SearchAggregator.dedupe([low, high])
        #expect(deduped.count == 1)
        #expect(deduped.first?.seeders == 40)
    }

    @Test func dedupeUnionsSources() {
        let a = makeResult(hash: Self.hashA, title: "Release", seeders: 5, source: Self.jackett)
        let b = makeResult(hash: Self.hashA, title: "Release", seeders: 40, source: Self.prowlarr)

        let deduped = SearchAggregator.dedupe([a, b])
        #expect(Set(deduped.first?.sources ?? []) == Set([Self.jackett, Self.prowlarr]))
    }

    @Test func dedupePrefersLongestTitleEvenFromTheLowerSeederEntry() {
        let low = makeResult(
            hash: Self.hashA, title: "The Expanse S03E05 1080p BluRay x265-GROUP",
            seeders: 5, source: Self.jackett
        )
        let high = makeResult(hash: Self.hashA, title: "The Expanse S03E05", seeders: 40, source: Self.prowlarr)

        let deduped = SearchAggregator.dedupe([low, high])
        #expect(deduped.first?.title == "The Expanse S03E05 1080p BluRay x265-GROUP")
        #expect(deduped.first?.seeders == 40)   // base fields still come from the seeder winner
    }

    @Test func dedupeUnionsRawAttributesFillingWhatTheWinnerLacks() {
        let a = makeResult(
            hash: Self.hashA, title: "Release", seeders: 5, source: Self.jackett,
            rawAttributes: ["imdb": "tt1234567"]
        )
        let b = makeResult(
            hash: Self.hashA, title: "Release", seeders: 40, source: Self.prowlarr,
            rawAttributes: ["team": "GROUP"]
        )

        let deduped = SearchAggregator.dedupe([a, b])
        let raw = deduped.first?.rawAttributes ?? [:]
        #expect(raw["imdb"] == "tt1234567")   // filled in from the non-winner
        #expect(raw["team"] == "GROUP")       // the winner's own attribute
    }

    @Test func dedupeDoesNotOverwriteWinnersAttributeOnConflict() {
        let a = makeResult(
            hash: Self.hashA, title: "Release", seeders: 5, source: Self.jackett,
            rawAttributes: ["imdb": "tt_from_loser"]
        )
        let b = makeResult(
            hash: Self.hashA, title: "Release", seeders: 40, source: Self.prowlarr,
            rawAttributes: ["imdb": "tt_from_winner"]
        )

        let deduped = SearchAggregator.dedupe([a, b])
        #expect(deduped.first?.rawAttributes["imdb"] == "tt_from_winner")
    }

    @Test func dedupePrecedesGroupingDistinctHashesStayDistinct() {
        let a = makeResult(hash: Self.hashA, title: "Release A", seeders: 5, source: Self.jackett)
        let b = makeResult(hash: Self.hashB, title: "Release B", seeders: 10, source: Self.jackett)
        let c = makeResult(hash: Self.hashC, title: "Release C", seeders: 15, source: Self.prowlarr)

        let deduped = SearchAggregator.dedupe([a, b, c])
        // Three distinct releases stay three rows — a later "3 releases" count
        // means three distinct releases, not the same one seen thrice (§7).
        #expect(deduped.count == 3)
    }

    // MARK: - search() integration (concurrency, timeout, partial failure)

    private func makeAggregator(
        _ providers: [any SearchProvider], timeout: TimeInterval = 20
    ) -> SearchAggregator {
        SearchAggregator(providers: providers, perProviderTimeout: timeout)
    }

    @Test func partialFailureStillReturnsTheHealthyProvidersResults() async {
        let healthy = StubSearchProvider(
            id: Self.jackett, displayName: "Jackett",
            results: [makeResult(hash: Self.hashA, title: "OK", seeders: 5, source: Self.jackett)]
        )
        let dead = StubSearchProvider(
            id: Self.prowlarr, displayName: "Prowlarr",
            error: SearchError.unauthorized
        )

        let outcome = await makeAggregator([healthy, dead]).search(SearchQuery(text: "x"))
        #expect(outcome.results.count == 1)
        #expect(outcome.results.first?.title == "OK")
        #expect(outcome.failures.keys.contains(Self.prowlarr))
        #expect(outcome.failures.count == 1)
    }

    @Test func allProvidersHealthyProducesNoFailures() async {
        let a = StubSearchProvider(
            id: Self.jackett, displayName: "Jackett",
            results: [makeResult(hash: Self.hashA, title: "A", seeders: 5, source: Self.jackett)]
        )
        let outcome = await makeAggregator([a]).search(SearchQuery(text: "x"))
        #expect(outcome.failures.isEmpty)
        #expect(outcome.results.count == 1)
    }

    @Test func emptyProviderListReturnsEmptyOutcome() async {
        let outcome = await makeAggregator([]).search(SearchQuery(text: "x"))
        #expect(outcome.results.isEmpty)
        #expect(outcome.failures.isEmpty)
    }

    @Test func slowProviderTimesOutAndIsReportedAsAFailureNotAHang() async {
        let slow = StubSearchProvider(id: Self.jackett, displayName: "Slow", delay: 0.3)
        let outcome = await makeAggregator([slow], timeout: 0.05).search(SearchQuery(text: "x"))

        #expect(outcome.results.isEmpty)
        guard case .providerTimeout = outcome.failures[Self.jackett] as? SearchError else {
            Issue.record("expected .providerTimeout, got \(String(describing: outcome.failures[Self.jackett]))")
            return
        }
    }

    @Test func fanOutIsConcurrentNotSerial() async {
        // Three providers each "take" 150ms. If fan-out were serial this
        // would take >= 450ms; concurrent, it should complete well under
        // that — generous margin to avoid CI flakiness.
        let providers = (0..<3).map { i in
            StubSearchProvider(
                id: SearchProviderID(rawValue: "p\(i)"), displayName: "p\(i)",
                results: [makeResult(hash: "aa\(i)155ecdc7ca55fb0bbf81323d87062db1f6d\(i)9",
                                      title: "r\(i)", seeders: i, source: SearchProviderID(rawValue: "p\(i)"))],
                delay: 0.15
            )
        }
        let start = Date()
        _ = await makeAggregator(providers).search(SearchQuery(text: "x"))
        #expect(Date().timeIntervalSince(start) < 0.4)
    }

    @Test func defaultOutputIsFlatAndSeederSorted() async {
        let a = StubSearchProvider(
            id: Self.jackett, displayName: "Jackett",
            results: [
                makeResult(hash: Self.hashA, title: "Low", seeders: 5, source: Self.jackett),
                makeResult(hash: Self.hashB, title: "High", seeders: 50, source: Self.jackett),
                makeResult(hash: Self.hashC, title: "Mid", seeders: 20, source: Self.jackett),
            ]
        )
        let outcome = await makeAggregator([a]).search(SearchQuery(text: "x"))
        #expect(outcome.results.map(\.seeders) == [50, 20, 5])
    }

    // MARK: - parse stage (M3 — no longer identity, §7/§8 staging note)

    @Test func searchPopulatesMetadataFromTheTitleParse() async {
        let provider = StubSearchProvider(
            id: Self.jackett, displayName: "Jackett",
            results: [
                makeResult(
                    hash: Self.hashA, title: "The.Expanse.S03E05.1080p.BluRay.x265-GROUP",
                    seeders: 5, source: Self.jackett
                ),
            ]
        )
        let outcome = await makeAggregator([provider]).search(SearchQuery(text: "x"))
        let metadata = outcome.results.first?.metadata
        #expect(metadata?.mediaKind == .tv)
        #expect(metadata?.title == "The Expanse")
        #expect(metadata?.season == 3)
        #expect(metadata?.episodes == [5])
        #expect(metadata?.resolution == .r1080p)
        #expect(metadata?.provenance[.resolution] == .titleParse)
    }

    @Test func searchOverlaysRawAttributesOntoTheParsedMetadata() async {
        let provider = StubSearchProvider(
            id: Self.jackett, displayName: "Jackett",
            results: [
                makeResult(
                    hash: Self.hashA, title: "Movie.Name.2020.720p.WEB-DL.x264-GROUP",
                    seeders: 5, source: Self.jackett, rawAttributes: ["resolution": "1080p", "imdb": "tt1234567"]
                ),
            ]
        )
        let outcome = await makeAggregator([provider]).search(SearchQuery(text: "x"))
        let metadata = outcome.results.first?.metadata
        // Attribute wins on conflict with the weaker (720p) title parse.
        #expect(metadata?.resolution == .r1080p)
        #expect(metadata?.provenance[.resolution] == .attribute)
        #expect(metadata?.imdbID == "tt1234567")
    }

    // MARK: - provider-stated metadata survives the parse stage

    /// A book carries `mediaKind = .book`, an author and a language because
    /// Gutendex *said so* — not because a release name was guessed at. The
    /// parse stage used to rebuild metadata from the title parse alone, which
    /// threw all of it away: "Frankenstein" parses to `.other`, and
    /// `RoutingRule.defaults` then filed the EPUB under `Other/` instead of
    /// `Books/`. `.attribute` provenance is the existing model of "a source
    /// stated this", so it is what decides.
    @Test func providerStatedMetadataSurvivesTheParseStage() throws {
        var stated = ReleaseMetadata.unparsed
        stated.mediaKind = .book
        stated.title = "Frankenstein; or, the Modern Prometheus"
        stated.author = "Mary Wollstonecraft Shelley"
        stated.languages = ["en"]
        stated.documentFormat = .epub
        stated.provenance = [
            .mediaKind: .attribute, .title: .attribute, .author: .attribute,
            .languages: .attribute, .documentFormat: .attribute,
        ]

        let book = SearchResult(
            candidates: [.direct(url: URL(string: "https://www.gutenberg.org/ebooks/84.epub3.images")!)],
            title: "Frankenstein; or, the Modern Prometheus",
            size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil,
            sources: [SearchProviderID(rawValue: "gutenberg")],
            rawAttributes: ["gutenbergID": "84", "author": "Mary Wollstonecraft Shelley"],
            metadata: stated)

        let parsed = try #require(SearchAggregator.parse([book]).first).metadata

        // The end-to-end claim: this is the value `subfolder(for:)` reads, and
        // `.book` is the only one that reaches the Books routing rule.
        #expect(parsed.mediaKind == .book)
        #expect(parsed.title == "Frankenstein; or, the Modern Prometheus")
        #expect(parsed.author == "Mary Wollstonecraft Shelley")
        #expect(parsed.languages == ["en"])
        #expect(parsed.documentFormat == .epub)
        #expect(parsed.provenance[.mediaKind] == .attribute)
        #expect(parsed.provenance[.author] == .attribute)
        #expect(parsed.provenance[.languages] == .attribute)
    }

    /// Stated fields win; they do not *replace* the parse. Anything the
    /// provider left unstated is still filled from the title, and still
    /// records that it was guessed.
    @Test func theTitleParseStillFillsWhatTheProviderLeftUnstated() throws {
        var stated = ReleaseMetadata.unparsed
        stated.mediaKind = .book
        stated.provenance = [.mediaKind: .attribute]

        let book = SearchResult(
            candidates: [.direct(url: URL(string: "https://example.org/x.epub")!)],
            // The year makes the title parse call this a `.movie`, so the
            // stated `.book` is being asserted against a real disagreement.
            title: "Some Title 1994 1080p",
            size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil,
            sources: [SearchProviderID(rawValue: "gutenberg")],
            rawAttributes: [:], metadata: stated)

        let parsed = try #require(SearchAggregator.parse([book]).first).metadata

        #expect(parsed.mediaKind == .book)
        #expect(parsed.year == 1994)
        #expect(parsed.provenance[.year] == .titleParse)
        #expect(parsed.resolution == .r1080p)
        #expect(parsed.provenance[.resolution] == .titleParse)
    }

    /// A provider can mark a field stated and still have nothing in it:
    /// `InternetArchiveProvider` sets `.title: .attribute` unconditionally
    /// while IA's `title` is optional. Copying that nil would delete the title
    /// the parse recovered from the identifier, and still record `.attribute` —
    /// a claim that a source stated a value that is not there.
    @Test func aStatedFieldWithNoValueDoesNotErasePartTheParseRecovered() throws {
        var stated = ReleaseMetadata.unparsed
        stated.mediaKind = .movie
        stated.title = nil
        stated.languages = []
        // Exactly what IA writes for an item whose `title` field is absent.
        stated.provenance = [
            .mediaKind: .attribute, .title: .attribute, .languages: .attribute,
        ]

        let item = SearchResult(
            candidates: [.direct(url: URL(string: "https://archive.org/details/some-item")!)],
            title: "Some Item 1994",
            size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil,
            sources: [SearchProviderID(rawValue: "internet-archive")],
            rawAttributes: ["identifier": "some-item"], metadata: stated)

        // The control: the same title with nothing stated at all. Comparing
        // against it asserts "the stated nil changed nothing" without pinning
        // this test to whatever the title parser happens to produce.
        let control = SearchResult(
            candidates: [.direct(url: URL(string: "https://archive.org/details/other-item")!)],
            title: "Some Item 1994",
            size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil,
            sources: [SearchProviderID(rawValue: "internet-archive")],
            rawAttributes: [:], metadata: .unparsed)

        let parsed = try #require(SearchAggregator.parse([item]).first).metadata
        let expected = try #require(SearchAggregator.parse([control]).first).metadata

        // The parsed title survives, and provenance still says it was guessed.
        #expect(parsed.title != nil)
        #expect(parsed.title == expected.title)
        #expect(parsed.provenance[.title] == .titleParse)
        // A stated value that *is* there still wins.
        #expect(parsed.mediaKind == .movie)
        #expect(parsed.provenance[.mediaKind] == .attribute)
    }

    /// The Torznab path arrives with `.unparsed` metadata and no provenance,
    /// so nothing is stated and the stage must behave exactly as it did.
    @Test func aResultThatStatesNothingIsParsedExactlyAsBefore() throws {
        let torznab = makeResult(
            hash: Self.hashA, title: "The.Expanse.S03E05.1080p.BluRay.x265-GROUP",
            seeders: 5, source: Self.jackett)
        #expect(torznab.metadata == .unparsed)

        let parsed = try #require(SearchAggregator.parse([torznab]).first).metadata
        #expect(parsed.mediaKind == .tv)
        #expect(parsed.title == "The Expanse")
        #expect(parsed.season == 3)
        #expect(parsed.provenance[.mediaKind] == .titleParse)
    }
}
