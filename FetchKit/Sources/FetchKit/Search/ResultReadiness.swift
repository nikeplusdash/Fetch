import Foundation
import FetchPluginAPI

/// Can this result be downloaded **now**, or does something have to fetch it
/// first?
///
/// **This replaces "is it cached", which was the wrong question.** Cache is one
/// way of being ready and only applies to torrents, so every Internet Archive
/// file and every Gutenberg book — which need no debrid at all and start
/// downloading the instant you ask — had an empty badge and no answer. They
/// are the *most* direct thing in the list and the column said nothing about
/// them.
///
/// The question the user is actually asking a search result is "if I click
/// this, does it start?". A cached torrent and a public HTTPS file answer that
/// identically, so they share a case.
public enum ResultReadiness: Sendable, Equatable {
    /// Starts immediately: a public file, or a torrent a debrid already holds.
    case direct
    /// A debrid would have to fetch the torrent first — minutes to hours.
    case needsFetching
    /// Being asked right now.
    case checking
    /// No answer, and that is not the same as "no". Real-Debrid's
    /// availability endpoint is disabled, so an RD-only user gets this for
    /// everything and must not be told their whole list is unavailable — the
    /// rule `CacheReadiness` and `CachedOnlyFilter` already follow.
    case unknown

    /// Highest sorts first under "Direct".
    public var rank: Int {
        switch self {
        case .direct: 3
        case .checking, .unknown: 2
        case .needsFetching: 1
        }
    }
}

extension ResultReadiness {
    /// `states` is keyed by lowercase infohash, matching `AppModel.cacheStates`.
    public static func of(
        _ result: SearchResult, cacheStates states: [String: CacheCheckState]
    ) -> ResultReadiness {
        // No torrent to look up means nothing to wait for: whatever this is,
        // it is fetched straight from its source. This is the case that used
        // to render a blank column.
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
