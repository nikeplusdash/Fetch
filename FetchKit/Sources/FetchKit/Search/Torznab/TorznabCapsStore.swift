import Foundation
import FetchPluginAPI

/// Every indexer's `t=caps`, shared for the app's session rather than one
/// search — the lifetime `TorznabCapsCache` (Task 3) got wrong.
/// `AppModel.torznabProviders()` builds a fresh `TorznabProvider` per
/// indexer on every search, so a cache living on the provider instance
/// caches nothing across searches: this store lives on `AppModel` instead,
/// keyed by the indexer's own id, and is handed to whichever provider
/// instance asks this search.
///
/// TTL matches `SupportedHostsCache`'s six hours: an indexer's advertised
/// categories change when the user adds one in Jackett, and an app that
/// never re-asked would need a relaunch to notice.
public actor TorznabCapsStore {
    private struct Entry {
        let capabilities: ProviderCapabilities
        let fetchedAt: Date
    }

    private var entries: [SearchProviderID: Entry] = [:]
    private var inFlight: [SearchProviderID: Task<ProviderCapabilities, any Error>] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    /// Bumped by every `clear()`. Captured by a fetch before its `await` and
    /// compared after: a fetch that started before a `clear()` landed must
    /// not write its answer back once it finally resolves, or `clear()`
    /// would not actually clear anything against that interleaving — see
    /// `clear()`'s doc comment.
    private var generation = 0

    /// `now` is injected, the same shape as `CacheStatusStore`, so the TTL
    /// can be tested without waiting six hours; the app never passes it.
    public init(ttl: TimeInterval = 6 * 60 * 60, now: @escaping @Sendable () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    /// This indexer's capabilities, fetching only if unknown, expired, or
    /// forgotten by `clear()`.
    ///
    /// Two concurrent callers for the same id join one fetch — an actor
    /// rather than a lock because the fetch is async and two concurrent
    /// searches must not both make it. If that fetch throws, the thrown
    /// error reaches every awaiting caller and nothing is stored: an indexer
    /// that was briefly unreachable must not be treated as capability-less
    /// until the TTL expires, which would silently skip it from every scoped
    /// search.
    public func capabilities(
        for id: SearchProviderID,
        fetch: @Sendable @escaping () async throws -> ProviderCapabilities
    ) async throws -> ProviderCapabilities {
        if let entry = entries[id], now().timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.capabilities
        }
        if let inFlight = inFlight[id] {
            return try await inFlight.value
        }

        // Captured before the fetch's only suspension point, so a `clear()`
        // that lands while this is in flight is visible below without a race
        // — actor isolation means nothing else runs between this read and
        // `inFlight[id] = task`.
        let requestGeneration = generation
        let task = Task { try await fetch() }
        inFlight[id] = task
        defer {
            // Only clear the slot this call itself put there. Without the
            // guard, this fetch resolving *after* a `clear()` (and after a
            // fresh post-clear fetch has already registered its own task in
            // `inFlight[id]`) would nil out that newer, still-relevant entry
            // — the next caller would then start a third redundant fetch
            // instead of joining the second one. If `generation` is
            // unchanged, no `clear()` happened since this call started, so
            // nothing else could have touched this id's slot.
            if requestGeneration == generation { inFlight[id] = nil }
        }
        // The assignment to `entries` below is unreachable when `fetch`
        // throws — `task.value` rethrows first — so a failed fetch is never
        // memoized.
        let value = try await task.value
        // A `clear()` that landed while this fetch was in flight already
        // dropped this call from `inFlight` and bumped `generation` — the
        // stale answer this was chasing must not be written back now that it
        // has finally arrived, or `clear()` would have cleared nothing
        // against this exact interleaving.
        if requestGeneration == generation {
            entries[id] = Entry(capabilities: value, fetchedAt: now())
        }
        return value
    }

    /// Forgets every stored answer, so the next ask for each id goes to the
    /// network. Called whenever an indexer's endpoint, key, or list changes
    /// — six hours is a long time to be wrong about a server the user just
    /// edited.
    ///
    /// Also drops every in-flight fetch: a caller that joined one *before*
    /// this call still receives its (stale) answer once it resolves, but
    /// clearing `inFlight` here means any *new* caller arriving after this
    /// point starts a fresh fetch instead of joining a fetch this call was
    /// meant to discard. `generation` is what stops that stale answer from
    /// being written back to `entries` when it lands.
    public func clear() {
        entries.removeAll()
        inFlight.removeAll()
        generation += 1
    }
}
