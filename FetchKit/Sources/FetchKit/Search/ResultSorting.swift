import Foundation
import FetchPluginAPI

/**
 How the results list is ordered (§12.1).

 Raw values are the persisted ones, so `bestMatch`/`seeders`/`size`/`date`
 keep whatever the user had selected before the list grew clickable column
 headers and the three new keys under them.
 */
public enum ResultSort: String, CaseIterable, Identifiable, Sendable {
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

    public var defaultsToDescending: Bool {
        switch self {
        case .name, .kind: false
        case .bestMatch, .size, .seeders, .cache, .date: true
        }
    }
}

/**
 Orders search results by one column.

 **In FetchKit because it is a decision.** This lived as a private
 `sorted(_:)` on `AppModel`, in a target with no test bundle — the third
 time this repo has had to move ordering logic out of a view model. Sorting
 has more edge cases than it looks: an unknown size is not zero, an
 unrankable cache state is not "not cached", and every key needs a
 tiebreak or the list reshuffles under the user on every re-render.
 */
public enum ResultSorting {
    /**
     `cacheStates` is keyed by lowercase infohash, matching
     `AppModel.cacheStates`. Only `.cache` reads it.
     */
    public static func sort(
        _ results: [SearchResult],
        by sort: ResultSort,
        descending: Bool,
        cacheStates: [String: CacheCheckState] = [:]
    ) -> [SearchResult] {
        guard sort != .bestMatch else { return results }

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
                return a.id.rawValue < b.id.rawValue
            case .orderedAscending: return !descending
            case .orderedDescending: return descending
            }
        }
        return ordered + unknown.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func hasValue(
        _ result: SearchResult, for sort: ResultSort,
        cacheStates: [String: CacheCheckState]
    ) -> Bool {
        switch sort {
        case .size: result.size != nil
        case .seeders: result.seeders != nil
        case .date: result.publishDate != nil
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
            return a.title.compare(
                b.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric])

        case .size:
            return rank(a.size, b.size)

        case .seeders:
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

    private static func rank<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        guard let a, let b else { return .orderedSame }
        return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    static func cacheRank(
        _ result: SearchResult, _ states: [String: CacheCheckState]
    ) -> Int {
        ResultReadiness.of(result, cacheStates: states).rank
    }
}
