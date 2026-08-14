import Testing
import FetchPluginAPI
@testable import FetchKit

/// The category bar's source of truth: one pill, three source mappings.
@Suite struct SearchCategoryTests {
    @Test func allSendsNoCategories() {
        #expect(SearchCategory.all.torznabCategories.isEmpty)
    }

    /// Anime asks for 5070 and for the standard IDs Jackett maps the rest of an
    /// anime tracker's shelves onto — but never 5000, which would hand it every
    /// live-action series the indexer has.
    @Test func animeReachesTheWholeAnimeTrackerWithoutClaimingAllOfTV() {
        let ids = Set(SearchCategory.anime.torznabCategories.map(\.id))
        #expect(ids == [5070, 2020, 3000, 4020, 4050, 7000])
        #expect(!ids.contains(5000))
    }

    @Test func everyCategoryHasATitleAndASymbol() {
        for category in SearchCategory.allCases {
            #expect(!category.title.isEmpty, "\(category)")
            #expect(!category.symbolName.isEmpty, "\(category)")
        }
    }

    /// The bar renders these in order, so the order is part of the API.
    ///
    /// Two orders now, because Adult is offered only when safe search is off —
    /// a pill whose every result would be filtered out is worse than no pill.
    @Test func barOrderIsFixed() {
        #expect(SearchCategory.offered(safeSearch: true).map(\.rawValue)
            == ["all", "movies", "tv", "anime", "music", "books", "software", "games"])
        #expect(SearchCategory.offered(safeSearch: false).map(\.rawValue)
            == ["all", "movies", "tv", "anime", "music", "books", "software",
                "games", "adult"])
    }

    /// **Software and Games are the one pair that stays split.**
    /// `CategoryIntersection` treats a top-level ID as covering its whole tree,
    /// so naming 4000 in either would hand it the other's results — measured:
    /// 4000 returned Console. Everywhere else a parent is named deliberately
    /// and the overlap is the point.
    @Test func softwareAndGamesDoNotAnswerEachOthersQuestion() {
        func ids(_ c: SearchCategory) -> Set<Int> { Set(c.torznabCategories.map(\.id)) }
        #expect(ids(.software).isDisjoint(with: ids(.games)))
        for category in SearchCategory.allCases {
            #expect(!ids(category).contains(4000), "\(category)")
        }
    }

    /// TV owns its whole tree, 5070 included, so an anime series answers to
    /// both pills. A pill that returns a superset still found the thing; a
    /// pill that returns nothing is the failure this table exists to fix.
    @Test func tvTakesTheWholeTreeAndOverlapsAnimeOnPurpose() {
        let ids = Set(SearchCategory.tv.torznabCategories.map(\.id))
        #expect(ids == [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080])
        #expect(ids.contains(5070))
    }

    /// The parent is the fix, not a redundancy. A sibling-only Audio request
    /// returned one result for "3 Body Problem" where the provider's own
    /// `cat=3000` returned ten: three sources had filed on the bare parent.
    @Test func audioAsksForTheParentBecauseThatIsWhereTheResultsWere() {
        #expect(SearchCategory.music.torznabCategories.map(\.id).contains(3000))
    }

    /// An audiobook is a book and Torznab files it under Audio, so Books has to
    /// cross trees to find it. Measured: 7000 alone missed every one.
    @Test func booksReachAcrossToAudiobooks() {
        let ids = SearchCategory.books.torznabCategories.map(\.id)
        #expect(ids.contains(7000))
        #expect(ids.contains(3030))
    }

    /// Console is Software's, and the enumeration exists for the indexer that
    /// advertises no caps at all — there the request is sent verbatim and only
    /// an exact ID matches, so the parent alone would find nothing.
    @Test func softwareCarriesTheConsoleTreeAndNoneOfGames() {
        let ids = Set(SearchCategory.software.torznabCategories.map(\.id))
        #expect(ids.contains(1000))
        #expect(ids.isSuperset(of: [1010, 1080, 1140, 1180]))
        #expect(ids.isDisjoint(with: [4040, 4050, 4060, 4070]))
    }
}
