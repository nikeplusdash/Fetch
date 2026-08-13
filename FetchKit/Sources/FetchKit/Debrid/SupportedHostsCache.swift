import Foundation
import FetchPluginAPI

/// Which hosts each configured debrid covers, remembered for a while
/// (amendment §5, 7e §3.6).
///
/// Host lists change rarely. Asking on every pasted link would be absurd, and
/// asking per search result — once 7f produces hosted candidates — ruinous:
/// fifty results would be fifty round trips per provider for an answer that is
/// the same all day.
///
/// An actor rather than a struct with a dictionary because several results can
/// ask at once, which is exactly when a cache is worth having.
public actor SupportedHostsCache {
    private struct Entry {
        let hosts: [DebridHost]
        let fetchedAt: Date
    }

    private var entries: [DebridProviderID: Entry] = [:]
    private let ttl: TimeInterval

    /// §5's six hours.
    public init(ttl: TimeInterval = 6 * 60 * 60) {
        self.ttl = ttl
    }

    /// Coverage for every provider given, fetching only what has expired.
    ///
    /// `now` is a parameter so the TTL can be tested without sleeping; the app
    /// never passes it.
    ///
    /// A provider that throws is **omitted rather than cached as empty**. The
    /// difference matters: caching a failure as `[]` would silently strip that
    /// debrid's coverage for six hours because its API blipped once, and the
    /// user would see "no configured debrid handles this host" with no way to
    /// tell that one had simply not answered.
    public func hosts(
        for providers: [any DebridProvider], now: Date = Date()
    ) async -> [DebridProviderID: [DebridHost]] {
        var result: [DebridProviderID: [DebridHost]] = [:]

        for provider in providers {
            if let entry = entries[provider.id],
               now.timeIntervalSince(entry.fetchedAt) < ttl {
                result[provider.id] = entry.hosts
                continue
            }
            guard let fetched = try? await provider.supportedHosts() else { continue }
            entries[provider.id] = Entry(hosts: fetched, fetchedAt: now)
            result[provider.id] = fetched
        }
        return result
    }

    /// Forgets everything, so the next ask goes to the network.
    ///
    /// This is Settings' Refresh button. A refresh that returned the cached
    /// answer would be a button that does nothing.
    public func invalidate() {
        entries.removeAll()
    }
}
