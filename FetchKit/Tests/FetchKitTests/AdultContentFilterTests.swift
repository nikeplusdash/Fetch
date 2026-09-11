import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct AdultContentFilterTests {
    private static let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    private static let hashB = "aa1155ecdc7ca55fb0bbf81323d87062db1f6d99"
    private static let indexer = SearchProviderID(rawValue: "jackett")

    private func result(
        hash: String = hashA,
        title: String = "Something",
        categoryID: Int?,
        declared: String? = nil
    ) -> SearchResult {
        SearchResult(
            infoHashHex: hash,
            title: title,
            size: 1000,
            seeders: 10,
            peers: 0,
            grabs: nil,
            fileCount: nil,
            category: categoryID.map { TorznabCategory(id: $0, name: "c\($0)") },
            publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [Self.indexer],
            rawAttributes: declared.map { ["category": $0] } ?? [:])
    }

    @Test func theXXXCategoryIsAdult() {
        #expect(AdultContentFilter.isAdult(result(categoryID: 6000)))
    }

    @Test func everyXXXSubcategoryIsAdult() {
        for id in [6010, 6020, 6030, 6045, 6060, 6070, 6080, 6090, 6999] {
            #expect(AdultContentFilter.isAdult(result(categoryID: id)), "category \(id)")
        }
    }

    @Test func ordinaryCategoriesAreNot() {
        for id in [1000, 2000, 2040, 3000, 4000, 5000, 5040, 7000, 7020, 8000] {
            #expect(!AdultContentFilter.isAdult(result(categoryID: id)), "category \(id)")
        }
    }

    @Test func theBlockBoundsAreExact() {
        #expect(!AdultContentFilter.isAdult(result(categoryID: 5999)))
        #expect(AdultContentFilter.isAdult(result(categoryID: 6000)))
        #expect(AdultContentFilter.isAdult(result(categoryID: 6999)))
        #expect(!AdultContentFilter.isAdult(result(categoryID: 7000)))
    }

    @Test func aSecondaryXXXCategoryIsStillCaught() {
        let sneaky = result(categoryID: 2000, declared: "2000,6010")
        #expect(AdultContentFilter.isAdult(sneaky))
    }

    @Test func whitespaceBetweenDeclaredCategoriesIsTolerated() {
        #expect(AdultContentFilter.isAdult(result(categoryID: 2000, declared: "2000, 6010")))
    }

    @Test func anUncategorizedResultIsKept() {
        #expect(!AdultContentFilter.isAdult(result(categoryID: nil)))
    }

    @Test func unparseableCategoriesAreIgnoredNotAssumedAdult() {
        #expect(!AdultContentFilter.isAdult(result(categoryID: nil, declared: "xxx,adult")))
    }

    @Test func filteringRemovesOnlyTheAdultResults() {
        let clean = result(hash: Self.hashA, title: "Dune 2021", categoryID: 2000)
        let adult = result(hash: Self.hashB, title: "Something", categoryID: 6010)

        let kept = AdultContentFilter.excludingAdult([clean, adult])
        #expect(kept.map(\.title) == ["Dune 2021"])
    }


    @Test func thePipelineDropsAdultResultsWhenSafeSearchIsOn() {
        let clean = result(hash: Self.hashA, title: "Dune 2021", categoryID: 2000)
        let adult = result(hash: Self.hashB, title: "Something", categoryID: 6010)

        let on = SearchAggregator.pipeline([clean, adult], matching: "", excludeAdult: true)
        #expect(on.accepted.count + on.rejected.count == 1)
        #expect(!(on.accepted + on.rejected).contains { $0.id == adult.id })

        let off = SearchAggregator.pipeline([clean, adult], matching: "", excludeAdult: false)
        #expect(off.accepted.count + off.rejected.count == 2)
    }

    @Test func adultResultsAreDroppedNotOfferedAsFiltered() {
        let adult = result(hash: Self.hashB, title: "Something", categoryID: 6010)
        let outcome = SearchAggregator.pipeline([adult], matching: "", excludeAdult: true)

        #expect(outcome.accepted.isEmpty)
        #expect(outcome.rejected.isEmpty)
    }

    @Test func theStreamingPathDropsThemToo() {
        let clean = result(hash: Self.hashA, title: "Dune 2021", categoryID: 2000)
        let adult = result(hash: Self.hashB, title: "Something", categoryID: 6010)

        var accumulator = StreamedResultAccumulator()
        accumulator.apply(.started(providers: [Self.indexer]))
        let fresh = accumulator.apply(
            .succeeded(id: Self.indexer, results: [clean, adult], latency: 0))

        #expect(accumulator.results.map(\.title) == ["Dune 2021"])
        #expect(accumulator.filtered.isEmpty)
        #expect(fresh == [Self.hashA])
    }

    @Test func theStreamingPathKeepsThemWhenSafeSearchIsOff() {
        let clean = result(hash: Self.hashA, title: "Dune 2021", categoryID: 2000)
        let adult = result(hash: Self.hashB, title: "Something", categoryID: 6010)

        var accumulator = StreamedResultAccumulator(excludeAdult: false)
        accumulator.apply(.started(providers: [Self.indexer]))
        accumulator.apply(.succeeded(id: Self.indexer, results: [clean, adult], latency: 0))

        #expect(accumulator.results.count + accumulator.filtered.count == 2)
    }
}
