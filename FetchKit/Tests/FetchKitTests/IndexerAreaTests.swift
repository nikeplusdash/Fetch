import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Reserving an indexer for the pills it is actually good for.
///
/// A general fan-out asks every indexer everything, and for a specialised
/// tracker most of that is a round trip the user waits through for an answer
/// that was never coming.
@Suite struct IndexerAreaTests {
    private func indexer(
        _ name: String, areas: Set<SearchCategory>? = nil, isEnabled: Bool = true
    ) -> SubIndexer {
        SubIndexer(
            id: SearchProviderID(rawValue: name),
            name: name,
            torznabURL: URL(string: "http://localhost:9117/\(name)/api")!,
            isEnabled: isEnabled,
            areas: areas)
    }

    private func server(_ indexers: [SubIndexer], isEnabled: Bool = true) -> IndexerServerConfig {
        IndexerServerConfig(
            id: IndexerServerID(rawValue: "jackett"),
            displayName: "Jackett",
            rootURL: URL(string: "http://localhost:9117")!,
            isEnabled: isEnabled,
            indexers: indexers)
    }

    // MARK: - Which pills reach an indexer

    @Test func anUnreservedIndexerServesEveryPill() {
        let subject = indexer("knaben")
        #expect(subject.servesEveryArea)
        for category in SearchCategory.allCases {
            #expect(subject.serves(category), "\(category)")
        }
    }

    @Test func areservedIndexerServesOnlyWhatItWasReservedFor() {
        let subject = indexer("nyaa", areas: [.anime])
        #expect(!subject.servesEveryArea)
        #expect(subject.serves(.anime))
        #expect(!subject.serves(.tv))
        #expect(!subject.serves(.movies))
    }

    /// **All has no area to match against.** It sends no categories at all, and
    /// a user who reserved a tracker for Books still wants its books when
    /// searching everything. Taking an indexer out of every search is what its
    /// own toggle is for.
    @Test func allStillAsksAReservedIndexer() {
        #expect(indexer("ebookbay", areas: [.books]).serves(.all))
    }

    /// Empty is not a third state. It would mean an indexer reserved for
    /// nothing, which is an indexer that is never asked anything — and that is
    /// what the enable toggle says, in a place the user can see.
    @Test func anEmptyReservationReadsAsEveryArea() {
        let subject = indexer("knaben", areas: [])
        #expect(subject.servesEveryArea)
        #expect(subject.serves(.software))
        #expect(subject.areaSummary == "Every area")
    }

    // MARK: - What the menu says

    @Test func theSummaryNamesUpToTwoAreasAndCountsBeyondThat() {
        #expect(indexer("a").areaSummary == "Every area")
        #expect(indexer("a", areas: [.anime]).areaSummary == "Anime")
        #expect(indexer("a", areas: [.movies, .tv]).areaSummary == "Movies, TV")
        #expect(indexer("a", areas: [.movies, .tv, .anime]).areaSummary == "3 areas")
    }

    /// Pill order, not set order, so two indexers reserved for the same areas
    /// read identically rather than however their sets happened to hash.
    @Test func theSummaryIsInPillOrder() {
        #expect(indexer("a", areas: [.tv, .movies]).areaSummary == "Movies, TV")
        #expect(indexer("b", areas: [.movies, .tv]).areaSummary == "Movies, TV")
    }

    // MARK: - What a search fans out over

    @Test func aServerOnlyOffersTheIndexersReservedForThePill() {
        let subject = server([
            indexer("nyaa", areas: [.anime]),
            indexer("knaben"),
            indexer("ebookbay", areas: [.books, .music]),
        ])
        #expect(subject.activeIndexers(for: .anime).map(\.name) == ["nyaa", "knaben"])
        #expect(subject.activeIndexers(for: .music).map(\.name) == ["knaben", "ebookbay"])
        #expect(subject.activeIndexers(for: .software).map(\.name) == ["knaben"])
        #expect(subject.activeIndexers(for: .all).map(\.name)
            == ["nyaa", "knaben", "ebookbay"])
    }

    /// Reservation narrows what is already active; it does not revive an
    /// indexer that is switched off, or one on a server that is.
    @Test func reservationNeverOverridesAToggle() {
        #expect(server([indexer("nyaa", areas: [.anime], isEnabled: false)])
            .activeIndexers(for: .anime).isEmpty)
        #expect(server([indexer("nyaa", areas: [.anime])], isEnabled: false)
            .activeIndexers(for: .anime).isEmpty)
    }

    // MARK: - Persistence

    /// **Every indexer configured before this property existed must decode.**
    /// Synthesised `Codable` fills a missing key only for an optional; a
    /// non-optional would have thrown, and the decode failure that
    /// `loadIndexerServers` swallows would have silently emptied the user's
    /// server list.
    @Test func aStoredIndexerFromBeforeAreasExistedDecodesAsEveryArea() throws {
        let legacy = """
        [{"id":"jackett","displayName":"Jackett","rootURL":"http://localhost:9117",
          "isEnabled":true,
          "indexers":[{"id":"knaben","name":"Knaben",
                       "torznabURL":"http://localhost:9117/knaben/api",
                       "isEnabled":true,"isMissingFromServer":false}]}]
        """
        let decoded = try JSONDecoder().decode(
            [IndexerServerConfig].self, from: Data(legacy.utf8))
        let subject = try #require(decoded.first?.indexers.first)
        #expect(subject.areas == nil)
        #expect(subject.servesEveryArea)
    }

    @Test func areservationSurvivesARoundTrip() throws {
        let original = server([indexer("nyaa", areas: [.anime, .movies])])
        let decoded = try JSONDecoder().decode(
            IndexerServerConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded.indexers.first?.areas == [.anime, .movies])
    }
}
