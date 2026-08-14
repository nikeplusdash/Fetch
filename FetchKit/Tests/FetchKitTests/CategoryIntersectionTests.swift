import Testing
import FetchPluginAPI
@testable import FetchKit

@Suite struct CategoryIntersectionTests {
    private func cats(_ ids: Int...) -> [TorznabCategory] {
        ids.map { TorznabCategory(id: $0, name: "c\($0)") }
    }

    /// An indexer that advertises nothing is asked anyway. Absence of caps is
    /// not evidence of absence of coverage.
    @Test func noAdvertisedCategoriesSendsVerbatim() {
        #expect(CategoryIntersection.resolve(requested: cats(2000), advertised: [])
            == .sendVerbatim)
    }

    /// No requested categories is the All pill: nothing to intersect.
    @Test func noRequestedCategoriesSendsVerbatim() {
        #expect(CategoryIntersection.resolve(requested: [], advertised: cats(5000))
            == .sendVerbatim)
    }

    @Test func exactMatchSendsThatID() {
        #expect(CategoryIntersection.resolve(requested: cats(2000), advertised: cats(2000, 5000))
            == .send([2000]))
    }

    /// A movie indexer advertising only sub-categories still carries movies.
    @Test func aTopLevelRequestIsCoveredByItsDescendants() {
        #expect(CategoryIntersection.resolve(requested: cats(2000), advertised: cats(2040, 2060))
            == .send([2040, 2060]))
    }

    /// The anime case, and the reason the rule is not simply "same bucket":
    /// 5000 is TV, not TV/Anime, and returning all TV for the Anime pill is
    /// worse than returning nothing.
    @Test func aSubCategoryRequestIsNotCoveredByItsParent() {
        #expect(CategoryIntersection.resolve(requested: cats(5070), advertised: cats(5000, 5040))
            == .skip)
    }

    @Test func aSubCategoryRequestIsCoveredByItself() {
        #expect(CategoryIntersection.resolve(requested: cats(5070), advertised: cats(5000, 5070))
            == .send([5070]))
    }

    /// Games asks for two buckets; one covered is enough to participate.
    @Test func anyCoveredRequestParticipates() {
        #expect(CategoryIntersection.resolve(requested: cats(1000, 4050), advertised: cats(4050))
            == .send([4050]))
    }

    @Test func nothingCoveredSkips() {
        #expect(CategoryIntersection.resolve(requested: cats(7000), advertised: cats(2000, 5000))
            == .skip)
    }

    /// Sorted so the `cat=` parameter is stable between identical searches —
    /// an unstable query string defeats any HTTP caching in front of Jackett.
    @Test func sentIDsAreSortedAndDeduplicated() {
        #expect(CategoryIntersection.resolve(
            requested: cats(2000, 2040), advertised: cats(2060, 2040))
            == .send([2040, 2060]))
    }
}
