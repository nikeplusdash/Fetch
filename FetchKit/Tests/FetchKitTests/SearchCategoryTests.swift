import Testing
import FetchPluginAPI
@testable import FetchKit

@Suite struct SearchCategoryTests {
    @Test func allSendsNoCategories() {
        #expect(SearchCategory.all.torznabCategories.isEmpty)
    }

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

    @Test func barOrderIsFixed() {
        #expect(SearchCategory.offered(safeSearch: true).map(\.rawValue)
            == ["all", "movies", "tv", "anime", "music", "books", "software", "games"])
        #expect(SearchCategory.offered(safeSearch: false).map(\.rawValue)
            == ["all", "movies", "tv", "anime", "music", "books", "software",
                "games", "adult"])
    }

    @Test func softwareAndGamesDoNotAnswerEachOthersQuestion() {
        func ids(_ c: SearchCategory) -> Set<Int> { Set(c.torznabCategories.map(\.id)) }
        #expect(ids(.software).isDisjoint(with: ids(.games)))
        for category in SearchCategory.allCases {
            #expect(!ids(category).contains(4000), "\(category)")
        }
    }

    @Test func tvTakesTheWholeTreeAndOverlapsAnimeOnPurpose() {
        let ids = Set(SearchCategory.tv.torznabCategories.map(\.id))
        #expect(ids == [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080])
        #expect(ids.contains(5070))
    }

    @Test func audioAsksForTheParentBecauseThatIsWhereTheResultsWere() {
        #expect(SearchCategory.music.torznabCategories.map(\.id).contains(3000))
    }

    @Test func booksReachAcrossToAudiobooks() {
        let ids = SearchCategory.books.torznabCategories.map(\.id)
        #expect(ids.contains(7000))
        #expect(ids.contains(3030))
    }

    @Test func softwareCarriesTheConsoleTreeAndNoneOfGames() {
        let ids = Set(SearchCategory.software.torznabCategories.map(\.id))
        #expect(ids.contains(1000))
        #expect(ids.isSuperset(of: [1010, 1080, 1140, 1180]))
        #expect(ids.isDisjoint(with: [4040, 4050, 4060, 4070]))
    }
}
