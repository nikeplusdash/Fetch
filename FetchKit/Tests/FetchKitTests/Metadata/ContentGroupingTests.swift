import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Collapsing releases to one row per piece of content (§8, Grouping).
///
/// The problem this solves, measured on a real Prowlarr: a query for "dune"
/// returned 209 rows, most of them the same handful of films at different
/// qualities. A flat seeder-sorted list buries the REMUX under three webrips
/// of the same title.
@Suite struct ContentGroupingTests {
    private func result(
        title: String,
        hash: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        seeders: Int = 10,
        size: Int64 = 1_000_000_000,
        metadata: ReleaseMetadata = .unparsed
    ) -> SearchResult {
        SearchResult(
            infoHashHex: String(hash.prefix(40)),
            title: title, size: size, seeders: seeders, peers: 0,
            grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash.prefix(40))",
            sources: [SearchProviderID(rawValue: "ix")],
            rawAttributes: [:],
            metadata: metadata)
    }

    private func meta(
        title: String? = nil, year: Int? = nil, season: Int? = nil,
        episodes: [Int] = [], imdb: String? = nil, tvdb: Int? = nil,
        kind: MediaKind = .movie
    ) -> ReleaseMetadata {
        var m = ReleaseMetadata.unparsed
        m.title = title
        m.year = year
        m.season = season
        m.episodes = episodes
        m.imdbID = imdb
        m.tvdbID = tvdb
        m.mediaKind = kind
        return m
    }

    // MARK: - Key resolution order

    /// An indexer-supplied id is authoritative, so two releases carrying the
    /// same one group even when their titles disagree wildly.
    @Test func imdbIDBeatsEverythingElse() {
        let a = ContentGrouping.key(for: meta(title: "Dune", year: 2021, imdb: "tt1160419"),
                                    fallbackTitle: "Dune.2021.1080p")
        let b = ContentGrouping.key(for: meta(title: "Dune Part One", year: 2020, imdb: "tt1160419"),
                                    fallbackTitle: "Dune.Part.One.2160p")
        #expect(a == b)
    }

    @Test func tvdbNeedsSeasonAndEpisodeToBeDistinct() {
        let e1 = ContentGrouping.key(for: meta(season: 3, episodes: [5], tvdb: 121361, kind: .tv),
                                     fallbackTitle: "x")
        let e2 = ContentGrouping.key(for: meta(season: 3, episodes: [6], tvdb: 121361, kind: .tv),
                                     fallbackTitle: "y")
        #expect(e1 != e2)
    }

    /// The case the spec calls out: separators and article placement must not
    /// split one series into two groups.
    @Test func titleNormalizationJoinsSeparatorAndArticleVariants() {
        let a = ContentGrouping.key(for: meta(title: "The Expanse", season: 3, episodes: [5], kind: .tv),
                                    fallbackTitle: "a")
        let b = ContentGrouping.key(for: meta(title: "Expanse, The", season: 3, episodes: [5], kind: .tv),
                                    fallbackTitle: "b")
        #expect(a == b)
    }

    @Test func punctuationAndCaseAreIgnored() {
        let a = ContentGrouping.key(for: meta(title: "Spider-Man: No Way Home", year: 2021),
                                    fallbackTitle: "a")
        let b = ContentGrouping.key(for: meta(title: "spider man no way home", year: 2021),
                                    fallbackTitle: "b")
        #expect(a == b)
    }

    /// Different films that share a title must not merge.
    @Test func theSameTitleInDifferentYearsStaysApart() {
        let a = ContentGrouping.key(for: meta(title: "Dune", year: 1984), fallbackTitle: "a")
        let b = ContentGrouping.key(for: meta(title: "Dune", year: 2021), fallbackTitle: "b")
        #expect(a != b)
    }

    @Test func aSeasonPackIsNotTheSameContentAsAnEpisode() {
        let pack = ContentGrouping.key(
            for: meta(title: "The Expanse", season: 3, episodes: [], kind: .tv), fallbackTitle: "a")
        let episode = ContentGrouping.key(
            for: meta(title: "The Expanse", season: 3, episodes: [5], kind: .tv), fallbackTitle: "b")
        #expect(pack != episode)
    }

    /// With nothing parsed, the raw title is the last resort — two identical
    /// raw titles group, and unrelated ones do not.
    @Test func anUnparsedReleaseFallsBackToItsRawTitle() {
        let a = ContentGrouping.key(for: .unparsed, fallbackTitle: "Some.Weird.Release.mkv")
        let b = ContentGrouping.key(for: .unparsed, fallbackTitle: "some weird release mkv")
        let c = ContentGrouping.key(for: .unparsed, fallbackTitle: "Totally.Different")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Grouping

    @Test func releasesOfOneFilmCollapseToOneGroup() {
        let dune = meta(title: "Dune", year: 2021)
        let groups = ContentGrouping.group([
            result(title: "Dune.2021.2160p.WEB-DL", seeders: 220, metadata: dune),
            result(title: "Dune.2021.1080p.BluRay.REMUX", seeders: 167, metadata: dune),
            result(title: "Dune.2021.1080p.HDRip", seeders: 122, metadata: dune),
        ])

        #expect(groups.count == 1)
        #expect(groups[0].releases.count == 3)
        #expect(groups[0].displayTitle == "Dune")
    }

    @Test func distinctFilmsStayDistinct() {
        let groups = ContentGrouping.group([
            result(title: "Dune.2021.2160p", metadata: meta(title: "Dune", year: 2021)),
            result(title: "Dune.Part.Two.2024.2160p", metadata: meta(title: "Dune Part Two", year: 2024)),
        ])
        #expect(groups.count == 2)
    }

    /// A group's headline figure is the best of its members, not a sum — the
    /// user is going to pick one release, so an aggregate seeder count would
    /// describe a download nobody performs.
    @Test func aGroupReportsItsHighestSeederCount() {
        let dune = meta(title: "Dune", year: 2021)
        let groups = ContentGrouping.group([
            result(title: "a", seeders: 12, metadata: dune),
            result(title: "b", seeders: 340, metadata: dune),
            result(title: "c", seeders: 7, metadata: dune),
        ])
        #expect(groups[0].maxSeeders == 340)
    }

    /// Group order follows the strongest member, so the most-seeded content
    /// leads — the flat list's one genuinely useful property is preserved.
    @Test func groupsAreOrderedByTheirStrongestMember() {
        let groups = ContentGrouping.group([
            result(title: "quiet", seeders: 5, metadata: meta(title: "Quiet Film", year: 2020)),
            result(title: "loud", seeders: 900, metadata: meta(title: "Loud Film", year: 2020)),
        ])
        #expect(groups.map(\.displayTitle) == ["Loud Film", "Quiet Film"])
    }

    /// Within a group the order must be stable, so the table does not reshuffle
    /// between identical searches.
    @Test func releasesWithinAGroupAreDeterministicallyOrdered() {
        let dune = meta(title: "Dune", year: 2021)
        let input = [
            result(title: "a", hash: "1111111111111111111111111111111111111111", seeders: 50, metadata: dune),
            result(title: "b", hash: "2222222222222222222222222222222222222222", seeders: 50, metadata: dune),
            result(title: "c", hash: "3333333333333333333333333333333333333333", seeders: 50, metadata: dune),
        ]
        let first = ContentGrouping.group(input)[0].releases.map(\.infoHashHex)
        for _ in 0..<10 {
            #expect(ContentGrouping.group(input)[0].releases.map(\.infoHashHex) == first)
        }
    }

    @Test func aGroupPrefersAParsedTitleOverARawOne() {
        let groups = ContentGrouping.group([
            result(title: "Dune.2021.2160p.WEB-DL.DDP5.1-FLUX", metadata: meta(title: "Dune", year: 2021))
        ])
        #expect(groups[0].displayTitle == "Dune")
    }

    @Test func groupingNothingYieldsNothing() {
        #expect(ContentGrouping.group([]).isEmpty)
    }

    /// Every input must appear exactly once — grouping reorganizes, it never
    /// drops a result.
    @Test func groupingLosesNoReleases() {
        let input = (0..<25).map { index in
            result(
                title: "r\(index)",
                hash: String(repeating: String(index % 10), count: 40),
                seeders: index,
                metadata: meta(title: "Film \(index % 4)", year: 2020))
        }
        let regrouped = ContentGrouping.group(input).flatMap(\.releases)
        #expect(Set(regrouped.map(\.infoHashHex)) == Set(input.map(\.infoHashHex)))
    }
}
