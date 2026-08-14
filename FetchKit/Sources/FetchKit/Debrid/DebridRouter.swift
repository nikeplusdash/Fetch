import Foundation
import FetchPluginAPI

/// Decides which debrid handles a download, and reconciles what several of
/// them say about one hash.
///
/// Both are pure decisions over already-fetched state, kept out of `AppModel`
/// so they are testable — the app target has no test target.
public enum DebridRouter {
    /// Picks the provider for a download.
    ///
    /// `providers` is the user's preference order, lowest index first. A
    /// provider that already has the torrent cached beats a more-preferred one
    /// that would have to fetch it, because the difference is an instant
    /// download versus a wait. With nothing cached, preference decides.
    ///
    /// A provider that cannot *report* cache status can still download, so
    /// `canReportCacheStatus` is deliberately not consulted here.
    public static func provider(
        for hash: String,
        providers: [any DebridProvider],
        cachedOn: [String: [DebridProviderID]]
    ) -> (any DebridProvider)? {
        let cached = Set((cachedOn[hash.lowercased()] ?? []).map(\.rawValue))
        return providers.first { cached.contains($0.id.rawValue) } ?? providers.first
    }

    // MARK: - Hosted links (7e §3.5)

    /// Picks the provider for a hoster link, and the host it matched.
    ///
    /// The first provider, in the user's preference order, whose coverage
    /// includes the URL's host and reports it up. Deliberately the same shape
    /// as the cached-torrent decision above, with coverage in place of cache.
    ///
    /// **There is no fallback to the first provider**, unlike the torrent
    /// case. An uncovered host is not a slower download, it is one that cannot
    /// happen: handing the link to a debrid that does not support the host
    /// fails at submit, with a message about the wrong thing.
    ///
    /// Returns the matched host as well as the provider, because every caller
    /// needs both — the provider to route to, the host to name in the UI. An
    /// earlier version returned only the provider, so `PastedLink` reimplemented
    /// this loop to get the host and left this function with no callers at all.
    public static func provider(
        forHost url: URL,
        providers: [DebridProviderID],
        supportedBy coverage: [DebridProviderID: [DebridHost]]
    ) -> (provider: DebridProviderID, host: DebridHost)? {
        for provider in providers {
            guard let hosts = coverage[provider],
                  let host = host(for: url, in: hosts, requiringActive: true)
            else { continue }
            return (provider, host)
        }
        return nil
    }

    /// The host serving `url`, from a list one provider reports.
    ///
    /// `.hosted` carries a `HostID`, and it comes from whichever host matched
    /// rather than from parsing the URL — the provider named it, and its name
    /// is the one its own API will accept back.
    ///
    /// `requiringActive` is false by default so a caller can still *identify*
    /// a host that is reported down, which is what lets the UI say "MediaFire,
    /// reported down" instead of "unsupported host".
    public static func host(
        for url: URL, in hosts: [DebridHost], requiringActive: Bool = false
    ) -> DebridHost? {
        hosts.first { $0.matches(url) && (!requiringActive || $0.isActive) }
    }

    /// Merges per-provider cache answers into the single badge state shown for
    /// a result.
    ///
    /// Precedence is cached → error → notCached → unchecked:
    ///
    /// - A hit anywhere wins, including over another provider's error. The
    ///   answer is already known; a failure elsewhere cannot unknow it.
    /// - An error with no hit stays an error rather than collapsing to "not
    ///   cached", which would assert something no provider confirmed.
    public static func mergeCacheStates(
        _ states: [DebridProviderID: CacheCheckState]
    ) -> CacheCheckState {
        guard !states.isEmpty else { return .unchecked }

        for state in states.values {
            if case .cached = state { return state }
        }
        for state in states.values {
            if case .error = state { return state }
        }
        if states.values.contains(where: { $0 == .notCached }) { return .notCached }
        if states.values.contains(where: { $0 == .checking }) { return .checking }
        return .unchecked
    }
}
