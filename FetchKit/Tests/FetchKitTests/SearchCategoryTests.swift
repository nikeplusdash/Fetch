import Testing
import FetchPluginAPI
@testable import FetchKit

/// The category bar's source of truth: one pill, three source mappings.
@Suite struct SearchCategoryTests {
    @Test func allSendsNoCategories() {
        #expect(SearchCategory.all.torznabCategories.isEmpty)
    }

    /// 5070 is sent alone. Widening to 5000 would make the Anime pill return
    /// every TV release the indexer has, which looks broken rather than empty.
    @Test func animeSendsOnlyTheAnimeSubCategory() {
        #expect(SearchCategory.anime.torznabCategories.map(\.id) == [5070])
    }

    @Test func everyCategoryHasATitleAndASymbol() {
        for category in SearchCategory.allCases {
            #expect(!category.title.isEmpty, "\(category)")
            #expect(!category.symbolName.isEmpty, "\(category)")
        }
    }

    /// The bar renders `allCases` in order, so the order is part of the API.
    @Test func barOrderIsFixed() {
        #expect(SearchCategory.allCases.map(\.rawValue)
            == ["all", "movies", "tv", "anime", "music", "books", "software", "games"])
    }
}
