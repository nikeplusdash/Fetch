import Foundation
import FetchPluginAPI

/**
 "Cached only" — show me what I can have right now.

 The filter drops exactly one thing: a result the debrid has definitively
 said it does not hold. Everything else survives, and each exclusion from
 the exclusion has its own reason.
 */
public enum CachedOnlyFilter {
    public static func apply(
        _ results: [SearchResult],
        states: [String: CacheCheckState],
        readiness: CacheReadiness
    ) -> [SearchResult] {
        guard readiness == .ready else { return results }

        return results.filter { result in
            guard let hash = result.infoHashHex else { return true }

            switch states[hash] {
            case .cached: return true
            case .notCached: return false
            case .unchecked, .checking, .error, .none: return true
            }
        }
    }
}
