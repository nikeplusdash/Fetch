import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Ordering the results list by one column.
///
/// This lived as a private `sorted(_:)` on `AppModel` — a decision in the one
/// target with no test bundle, for the third time in this repo. It has more
/// edge cases than it looks.
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

    // MARK: - Name

    /// "Episode 10" after "Episode 2", which a plain string compare gets
    /// backwards — and case- and accent-insensitively, because a list sorted
    /// by ASCII value puts every lowercase title after every uppercase one.
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

    // MARK: - Unknowns

    /// A source that did not say is not a source that said "empty". Gutenberg
    /// publishes no size at all, and sorting those to the top of an ascending
    /// list would bury every real answer under them.
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

    // MARK: - Cache

    /// The column answers "how ready is this", so a result needing no debrid
    /// at all ranks with a cached torrent rather than above or below it.
    /// `unchecked` beats a known miss, for the reason `CacheReadiness` and
    /// `CachedOnlyFilter` already encode: no answer is not a negative one.
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

    // MARK: - Stability

    /// Without a final tiebreak the order changes on every re-render, which
    /// reads as the list twitching while you look at it.
    @Test func equalValuesKeepAStableOrder() {
        let items = (1...20).map { result("row \($0)", size: 100) }
        let first = ResultSorting.sort(items, by: .size, descending: true)
        let second = ResultSorting.sort(items.reversed(), by: .size, descending: true)

        #expect(first.map(\.id) == second.map(\.id))
    }

    /// Best match is the pipeline's own multi-axis ladder, not a column —
    /// there is nothing coherent to reverse, so it is left exactly as it came.
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

    /// The raw values are persisted, so renaming one silently resets whatever
    /// the user had chosen.
    @Test func persistedRawValuesAreUnchanged() {
        #expect(ResultSort(rawValue: "bestMatch") == .bestMatch)
        #expect(ResultSort(rawValue: "seeders") == .seeders)
        #expect(ResultSort(rawValue: "size") == .size)
        #expect(ResultSort(rawValue: "date") == .date)
    }
}
