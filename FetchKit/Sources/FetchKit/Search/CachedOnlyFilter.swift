import Foundation
import FetchPluginAPI

/// "Cached only" — show me what I can have right now.
///
/// The filter drops exactly one thing: a result the debrid has definitively
/// said it does not hold. Everything else survives, and each exclusion from
/// the exclusion has its own reason.
public enum CachedOnlyFilter {
    public static func apply(
        _ results: [SearchResult],
        states: [String: CacheCheckState],
        readiness: CacheReadiness
    ) -> [SearchResult] {
        // With no provider that can answer, every hash is unknowable — and
        // `unknowable` is not `notCached`. Filtering on a fabricated miss
        // would empty the screen for a Real-Debrid-only user, which is the
        // same conflation that made a missing API key present itself as a
        // broken cache badge.
        guard readiness == .ready else { return results }

        return results.filter { result in
            // No infohash means nothing to check *and* nothing to prepare: a
            // direct or hosted link is already as instant as a cached torrent.
            guard let hash = result.infoHashHex else { return true }

            switch states[hash] {
            case .cached: return true
            case .notCached: return false
            // Unresolved. Dropping these would shrink the list as checks land,
            // which reads as results disappearing rather than as an answer
            // arriving.
            case .unchecked, .checking, .error, .none: return true
            }
        }
    }
}
