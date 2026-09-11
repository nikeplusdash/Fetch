import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct ResultSortingTests {
    private func result(
        _ title: String, size: Int64? = nil, seeders: Int? = nil,
        kind: MediaKind = .other, hash: String? = nil, date: Date? = nil
    ) -> SearchResult {
        let h = hash ?? String(format: "%040x", abs(title.hashValue % 1_000_000))
        return SearchResult(
            candidates: [.torrent(
                infoHash: InfoHash(h)!, magnet: MagnetLink("magnet:?xt=urn:btih:\(h)")!,
                targetPath: nil)],
            title: title, size: size, seeders: seeders, peers: nil,
            category: nil, publishDate: date, sources: [SearchProviderID(rawValue: "x")],
            rawAttributes: [:],
            metadata: ReleaseMetadata(mediaKind: kind))
    }


    @Test func nameSortsNumericallyAndIgnoringCase() {
        let sorted = ResultSorting.sort(
            [result("episode 10"), result("Episode 2"), result("Épisode 1")],
            by: .name, descending: false)

        #expect(sorted.map(\.title) == ["Épisode 1", "Episode 2", "episode 10"])
    }

    @Test func nameReversesWhenDescending() {
        let sorted = ResultSorting.sort(
            [result("A"), result("B"), result("C")], by: .name, descending: true)
        #expect(sorted.map(\.title) == ["C", "B", "A"])
    }


    @Test func anUnknownSizeSortsLastInBothDirections() {
        let items = [result("known", size: 500), result("unknown"), result("big", size: 9_000)]

        let ascending = ResultSorting.sort(items, by: .size, descending: false)
        #expect(ascending.map(\.title).last == "unknown")

        let descending = ResultSorting.sort(items, by: .size, descending: true)
        #expect(descending.map(\.title).last == "unknown")
    }

    @Test func anUnknownSeederCountSortsLastToo() {
        let items = [result("book"), result("torrent", seeders: 40)]
        for descending in [true, false] {
            let sorted = ResultSorting.sort(items, by: .seeders, descending: descending)
            #expect(sorted.map(\.title).last == "book")
        }
    }


    @Test func cacheRanksReadyThenUnknownThenMissing() {
        let cached = result("cached", hash: String(repeating: "a", count: 40))
        let missing = result("missing", hash: String(repeating: "b", count: 40))
        let unknown = result("unknown", hash: String(repeating: "c", count: 40))
        let states: [String: CacheCheckState] = [
            String(repeating: "a", count: 40): .cached(
                CacheEntry(infoHashHex: "a", name: "", size: 0, files: nil)),
            String(repeating: "b", count: 40): .notCached,
        ]

        let sorted = ResultSorting.sort(
            [missing, unknown, cached], by: .cache, descending: true, cacheStates: states)

        #expect(sorted.map(\.title) == ["cached", "unknown", "missing"])
    }


    @Test func equalValuesKeepAStableOrder() {
        let items = (1...20).map { result("row \($0)", size: 100) }
        let first = ResultSorting.sort(items, by: .size, descending: true)
        let second = ResultSorting.sort(items.reversed(), by: .size, descending: true)

        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test func bestMatchIsLeftUntouchedInEitherDirection() {
        let items = [result("z"), result("a"), result("m")]
        for descending in [true, false] {
            #expect(ResultSorting.sort(items, by: .bestMatch, descending: descending)
                    .map(\.title) == ["z", "a", "m"])
        }
    }

    @Test func everyColumnHasASensibleFirstDirection() {
        #expect(ResultSort.size.defaultsToDescending)
        #expect(ResultSort.seeders.defaultsToDescending)
        #expect(!ResultSort.name.defaultsToDescending)
        #expect(!ResultSort.kind.defaultsToDescending)
    }

    @Test func persistedRawValuesAreUnchanged() {
        #expect(ResultSort(rawValue: "bestMatch") == .bestMatch)
        #expect(ResultSort(rawValue: "seeders") == .seeders)
        #expect(ResultSort(rawValue: "size") == .size)
        #expect(ResultSort(rawValue: "date") == .date)
    }
}
