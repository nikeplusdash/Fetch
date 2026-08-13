import Foundation
import FetchPluginAPI

/// How the results list is ordered (§12.1).
///
/// Raw values are the persisted ones, so `bestMatch`/`seeders`/`size`/`date`
/// keep whatever the user had selected before the list grew clickable column
/// headers and the three new keys under them.
public enum ResultSort: String, CaseIterable, Identifiable, Sendable {
    /// The pipeline's own order — name-match bucket, then per-kind quality,
    /// then popularity (7d). Not a column, and deliberately the default:
    /// every single-axis order below reliably surfaces the wrong thing on its
    /// own, which is the whole reason that ladder exists.
    case bestMatch
    case name
    case size
    case seeders
    case cache
    case kind
    case date

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bestMatch: "Best match"
        case .name: "Name"
        case .size: "Size"
        case .seeders: "Seeders"
        case .cache: "Direct"
        case .kind: "Type"
        case .date: "Date"
        }
    }

    /// Which way round a first click should sort.
    ///
    /// Descending for the three where "more" is what anyone is looking for —
    /// clicking Size to see the smallest file first is not a thing people do.
    /// Ascending for name and type, where alphabetical is the expectation.
    public var defaultsToDescending: Bool {
        switch self {
        case .name, .kind: false
        case .bestMatch, .size, .seeders, .cache, .date: true
        }
    }
}

/// Orders search results by one column.
///
/// **In FetchKit because it is a decision.** This lived as a private
/// `sorted(_:)` on `AppModel`, in a target with no test bundle — the third
/// time this repo has had to move ordering logic out of a view model. Sorting
/// has more edge cases than it looks: an unknown size is not zero, an
/// unrankable cache state is not "not cached", and every key needs a
/// tiebreak or the list reshuffles under the user on every re-render.
public enum ResultSorting {
    /// `cacheStates` is keyed by lowercase infohash, matching
    /// `AppModel.cacheStates`. Only `.cache` reads it.
    public static func sort(
        _ results: [SearchResult],
        by sort: ResultSort,
        descending: Bool,
        cacheStates: [String: CacheCheckState] = [:]
    ) -> [SearchResult] {
        // Already ordered by the pipeline, and it is not a single axis, so
        // there is nothing coherent to reverse.
        guard sort != .bestMatch else { return results }

        // Partitioned before sorting, not folded into the comparison.
        // Returning "equal" for an unknown — the obvious way to write it —
        // drops those results onto the id tiebreak, which scatters them
        // through the list rather than parking them at the end. A test caught
        // it: an ascending sort by size put a 9 GB file last and the unknown
        // one in the middle.
        var known: [SearchResult] = []
        var unknown: [SearchResult] = []
        for result in results {
            if hasValue(result, for: sort, cacheStates: cacheStates) {
                known.append(result)
            } else {
                unknown.append(result)
            }
        }

        let ordered = known.sorted { a, b in
            let ordered = compare(a, b, by: sort, cacheStates: cacheStates)
            switch ordered {
            case .orderedSame:
                // Every comparison ends here eventually, and without a stable
                // final key the list reorders itself on each re-render — which
                // reads as the list twitching while you look at it.
                return a.id.rawValue < b.id.rawValue
            case .orderedAscending: return !descending
            case .orderedDescending: return descending
            }
        }
        // Always last, whichever way the column points. "Unknown" is not a
        // value on the scale, so it does not belong at either end of it — a
        // source that did not say is not a source that said "empty", and
        // Gutenberg never says.
        return ordered + unknown.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Whether this result has anything to be sorted by on this column.
    private static func hasValue(
        _ result: SearchResult, for sort: ResultSort,
        cacheStates: [String: CacheCheckState]
    ) -> Bool {
        switch sort {
        case .size: result.size != nil
        case .seeders: result.seeders != nil
        case .date: result.publishDate != nil
        // Every result has a title, a kind and a readiness — the last by way
        // of `cacheRank`, which answers for a result with no infohash too.
        case .bestMatch, .name, .kind, .cache: true
        }
    }

    private static func compare(
        _ a: SearchResult, _ b: SearchResult,
        by sort: ResultSort, cacheStates: [String: CacheCheckState]
    ) -> ComparisonResult {
        switch sort {
        case .bestMatch:
            return .orderedSame

        case .name:
            // Case- and diacritic-insensitive, and numeric: "Episode 2" before
            // "Episode 10", which a plain string compare gets backwards.
            return a.title.compare(
                b.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric])

        case .size:
            // An unknown size sorts *last* in either direction rather than as
            // zero: a source that did not say is not a source that said
            // "empty", and Gutenberg never says.
            return rank(a.size, b.size)

        case .seeders:
            // Same rule. A book has no seeders; reporting 0 would bury every
            // one of them under the worst torrent in the list.
            return rank(a.seeders, b.seeders)

        case .date:
            return rank(a.publishDate, b.publishDate)

        case .kind:
            return a.metadata.mediaKind.name.compare(
                b.metadata.mediaKind.name, options: .caseInsensitive)

        case .cache:
            return rank(cacheRank(a, cacheStates), cacheRank(b, cacheStates))
        }
    }

    /// Only ever reached for results that have both values — the ones that
    /// do not were partitioned out in `sort`.
    private static func rank<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        guard let a, let b else { return .orderedSame }
        return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    /// One axis for "does this start when I click it" — see `ResultReadiness`,
    /// which is where that question is answered for the badge as well, so the
    /// column and the badge cannot disagree about the same row.
    static func cacheRank(
        _ result: SearchResult, _ states: [String: CacheCheckState]
    ) -> Int {
        ResultReadiness.of(result, cacheStates: states).rank
    }
}
