import Testing
import FetchPluginAPI
@testable import FetchKit

@Suite struct CategoryIntersectionTests {
    private func cats(_ ids: Int...) -> [TorznabCategory] {
        ids.map { TorznabCategory(id: $0, name: "c\($0)") }
    }

    @Test func noAdvertisedCategoriesSendsVerbatim() {
        #expect(CategoryIntersection.resolve(requested: cats(2000), advertised: [])
            == .sendVerbatim)
    }

    @Test func noRequestedCategoriesSendsVerbatim() {
        #expect(CategoryIntersection.resolve(requested: [], advertised: cats(5000))
            == .sendVerbatim)
    }

    @Test func exactMatchSendsThatID() {
        #expect(CategoryIntersection.resolve(requested: cats(2000), advertised: cats(2000, 5000))
            == .send([2000]))
    }

    @Test func aTopLevelRequestIsCoveredByItsDescendants() {
        #expect(CategoryIntersection.resolve(requested: cats(2000), advertised: cats(2040, 2060))
            == .send([2040, 2060]))
    }

    @Test func aSubCategoryRequestIsNotCoveredByItsParent() {
        #expect(CategoryIntersection.resolve(requested: cats(5070), advertised: cats(5000, 5040))
            == .skip)
    }

    @Test func aSubCategoryRequestIsCoveredByItself() {
        #expect(CategoryIntersection.resolve(requested: cats(5070), advertised: cats(5000, 5070))
            == .send([5070]))
    }

    @Test func anyCoveredRequestParticipates() {
        #expect(CategoryIntersection.resolve(requested: cats(1000, 4050), advertised: cats(4050))
            == .send([4050]))
    }

    @Test func nothingCoveredSkips() {
        #expect(CategoryIntersection.resolve(requested: cats(7000), advertised: cats(2000, 5000))
            == .skip)
    }

    @Test func sentIDsAreSortedAndDeduplicated() {
        #expect(CategoryIntersection.resolve(
            requested: cats(2000, 2040), advertised: cats(2060, 2040))
            == .send([2040, 2060]))
    }
}
