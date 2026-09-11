import Foundation
import FetchPluginAPI

/**
 Can this result be downloaded **now**, or does something have to fetch it
 first?

 **This replaces "is it cached", which was the wrong question.** Cache is one
 way of being ready and only applies to torrents, so every Internet Archive
 file and every Gutenberg book — which need no debrid at all and start
 downloading the instant you ask — had an empty badge and no answer. They
 are the *most* direct thing in the list and the column said nothing about
 them.

 The question the user is actually asking a search result is "if I click
 this, does it start?". A cached torrent and a public HTTPS file answer that
 identically, so they share a case.
 */
public enum ResultReadiness: Sendable, Equatable {
    case direct
    case needsFetching
    case checking
    case unknown

    public var rank: Int {
        switch self {
        case .direct: 3
        case .checking, .unknown: 2
        case .needsFetching: 1
        }
    }
}

extension ResultReadiness {
    /**
     `states` is keyed by lowercase infohash, matching `AppModel.cacheStates`.
     */
    public static func of(
        _ result: SearchResult, cacheStates states: [String: CacheCheckState]
    ) -> ResultReadiness {
        guard let hash = result.infoHashHex else {
            return result.isUsable ? .direct : .unknown
        }
        return switch states[hash.lowercased()] {
        case .cached: .direct
        case .notCached: .needsFetching
        case .checking: .checking
        case .unchecked, .error, .none: .unknown
        }
    }
}
