import Foundation
import FetchPluginAPI

/// Whether a torrent a user is about to add is already on one of their
/// debrids, and which one would serve it.
///
/// **Why this exists as its own type.** `AppModel.route(_:)` picked the debrid
/// by reading `CacheStatusStore.cachedProviderMap()`, and its doc comment
/// promised that "a provider that already has the torrent cached beats a
/// more-preferred one that would have to fetch it". That map is populated by
/// `check(hashes:)`, which runs for **search results**, to draw their badges.
///
/// A pasted magnet was never searched. Its hash was not in the map, so nothing
/// was ever cached as far as the router could tell, and it fell through to
/// `providers.first` — waiting on a fetch another debrid had already done, with
/// nothing anywhere saying so.
///
/// Resolving *asks* rather than reads, and the answer is a value the sheet can
/// render, so the choice stops being invisible.
public enum LinkAvailability: Sendable, Equatable {
    /// On this debrid now — downloads immediately.
    case cached(DebridProviderID)
    /// Nobody has it. This is the debrid that would fetch it first.
    case notCached(DebridProviderID)
    /// No configured debrid can answer the question.
    ///
    /// Distinct from `notCached`, and the distinction is not pedantic:
    /// Real-Debrid's `instantAvailability` is a disabled endpoint, so an
    /// RD-only user would otherwise be told "not cached" about every torrent
    /// they ever add — asserting something no provider confirmed.
    /// `CacheReadiness` already carries this reasoning for search badges.
    case unknowable(DebridProviderID)
    case noProviders

    /// The debrid that would serve this download.
    public var provider: DebridProviderID? {
        switch self {
        case .cached(let id), .notCached(let id), .unknowable(let id): id
        case .noProviders: nil
        }
    }

    /// Whether adding this should be confirmed rather than done.
    ///
    /// Only the known miss. Queueing an uncached torrent spends an account
    /// slot and quota on an open-ended wait, which is a decision.
    ///
    /// `unknowable` deliberately does **not** confirm: nobody said there would
    /// be a wait, and warning about one would nag every Real-Debrid user on
    /// every add — the same over-reporting `CacheReadiness` exists to prevent.
    public var needsConfirmation: Bool {
        if case .notCached = self { return true }
        return false
    }

    /// Asks every capable debrid whether it holds `hash`, then picks.
    ///
    /// The check is **read-only**: it asks whether a hash is held, and adds
    /// nothing to any account. No swarm is touched — that is the debrid's
    /// business, and the whole point of the no-P2P constraint.
    ///
    /// `CacheStatusStore` dedupes by TTL, so a hash that was just checked for
    /// a search badge costs nothing here.
    public static func resolve(
        hash: String,
        providers: [any DebridProvider],
        store: CacheStatusStore
    ) async -> LinkAvailability {
        guard let first = providers.first else { return .noProviders }

        // Nothing can answer, so do not ask and do not pretend.
        guard providers.contains(where: \.canReportCacheStatus) else {
            return .unknowable(first.id)
        }

        await store.check(hashes: [hash])
        let cachedOn = await store.cachedProviders(for: hash)

        // Preference order decides among the providers that have it — the
        // caller's array order is the user's preference, and `DebridRouter`
        // applies it the same way for search results.
        if let winner = providers.first(where: { cachedOn.contains($0.id) }) {
            return .cached(winner.id)
        }
        return .notCached(first.id)
    }
}
