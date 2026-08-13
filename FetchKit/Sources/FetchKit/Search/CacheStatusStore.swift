import Foundation
import FetchPluginAPI

/// Per-hash cache badge state (design spec §12.1). Colour is never the only
/// signal — the view layer pairs each case with a distinct SF Symbol and a
/// VoiceOver label; this type is only the state machine.
public enum CacheCheckState: Sendable, Equatable {
    case unchecked
    case checking
    case cached(CacheEntry)
    case notCached
    case error(String)
}

/// Bulk-checks and memoizes debrid cache status per info hash, backing the
/// search results table's cache badges (§12.1).
///
/// Two things make this more than "call `checkCached` and cache the
/// result":
///
/// - **TTL memoization (5 minutes, §12.1).** Re-running a search or
///   switching categories must not re-hit the API for hashes already known.
///   Only *resolved* states (`.cached`/`.notCached`) are memoized —
///   `.error` never is, so the next bulk check naturally retries it without
///   the user having to click anything, and a transient blip can't wedge a
///   badge in `.error` for a full five minutes.
/// - **A `.checking` state emitted immediately**, before the network call
///   resolves, so the UI has something to show besides a blank cell.
///
/// This always calls `checkCached(listFiles: false)` — badge checks run
/// over hundreds of hashes and want the cheap response (§6). The file
/// picker's preview is a separate, single-hash `listFiles: true` call made
/// directly against the provider, not through this store.
///
/// Consumers observe `updates` (one `Snapshot` per hash whose state
/// changed) rather than polling — the same shape as `DownloadEngine.events`.
public actor CacheStatusStore {
    public struct Snapshot: Sendable, Equatable {
        public let hash: String
        public let state: CacheCheckState
    }

    private struct Entry {
        var state: CacheCheckState
        /// Set only when `state` is a resolved, memoizable outcome
        /// (`.cached`/`.notCached`) — `nil` means "always stale".
        var resolvedAt: Date?
    }

    /// Every configured debrid. Only those that can actually answer are
    /// queried — see `cacheCapableProviders`.
    private let providers: [any DebridProvider]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    /// Real-Debrid cannot report cache status, and asking it anyway would
    /// contribute a fabricated miss to every hash.
    private var cacheCapableProviders: [any DebridProvider] {
        providers.filter(\.canReportCacheStatus)
    }

    private var entries: [String: Entry] = [:]

    /// Which providers confirmed each hash. The badge merges this away, but
    /// `DebridRouter` needs it to send a download to a debrid that already has
    /// the torrent rather than one that would have to fetch it.
    private var cachedBy: [String: [DebridProviderID]] = [:]
    private var continuation: AsyncStream<Snapshot>.Continuation?
    public nonisolated let updates: AsyncStream<Snapshot>

    public init(
        provider: any DebridProvider,
        ttl: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(providers: [provider], ttl: ttl, now: now)
    }

    public init(
        providers: [any DebridProvider],
        ttl: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.providers = providers
        self.ttl = ttl
        self.now = now
        var captured: AsyncStream<Snapshot>.Continuation?
        self.updates = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    public func state(for hash: String) -> CacheCheckState {
        entries[hash.lowercased()]?.state ?? .unchecked
    }

    /// Providers that confirmed they hold `hash`, in no particular order —
    /// preference is the caller's, applied by `DebridRouter`. A provider that
    /// errored is absent rather than assumed either way.
    public func cachedProviders(for hash: String) -> [DebridProviderID] {
        cachedBy[hash.lowercased()] ?? []
    }

    /// Snapshot for every known hash, for a caller routing in bulk.
    public func cachedProviderMap() -> [String: [DebridProviderID]] { cachedBy }

    /// Bulk cache check for badges. Only hashes that are unknown, errored,
    /// or past the TTL are actually sent to the provider; everything else
    /// is served from memory.
    public func check(hashes: [String]) async {
        let normalized = orderedUnique(hashes.map { $0.lowercased() })
        let stale = normalized.filter { !isFresh($0) }
        guard !stale.isEmpty else { return }

        for hash in stale { set(hash, .checking) }
        await resolve(stale)
    }

    /// Re-runs the check for exactly one hash, ignoring the TTL — this is
    /// what an `.error` badge's click-to-retry calls (§12.1).
    public func retry(hash: String) async {
        let normalized = hash.lowercased()
        set(normalized, .checking)
        await resolve([normalized])
    }

    /// Asks every cache-capable provider concurrently and merges their
    /// answers into one badge state per hash (`DebridRouter.mergeCacheStates`).
    ///
    /// A provider that throws contributes an `.error` for its own column only,
    /// so one debrid being down cannot erase another's confirmed hit.
    private func resolve(_ hashes: [String]) async {
        let capable = cacheCapableProviders
        guard !capable.isEmpty else {
            // Nothing can answer. Leaving these `.unchecked` rather than
            // resolving them to `.notCached` is what lets the UI hide the badge
            // column instead of asserting a miss nobody confirmed.
            for hash in hashes { set(hash, .unchecked) }
            return
        }

        var perProvider: [DebridProviderID: [String: CacheCheckState]] = [:]

        await withTaskGroup(
            of: (DebridProviderID, Swift.Result<[String: CacheEntry], any Error>).self
        ) { group in
            for provider in capable {
                group.addTask {
                    do {
                        return (provider.id, .success(
                            try await provider.checkCached(hashes: hashes, listFiles: false)))
                    } catch {
                        return (provider.id, .failure(error))
                    }
                }
            }
            for await (id, outcome) in group {
                switch outcome {
                case .success(let results):
                    var states: [String: CacheCheckState] = [:]
                    for hash in hashes {
                        // `checkCached` is documented as total over its input —
                        // a hash absent from `results` would be a provider bug,
                        // not an expected case — but treating it as "not
                        // cached" defensively is strictly better than wedging
                        // the badge in `.checking` forever.
                        let entry = results[hash]
                            ?? CacheEntry(infoHashHex: hash, name: "", size: 0, files: nil)
                        states[hash] = entry.size > 0 ? .cached(entry) : .notCached
                    }
                    perProvider[id] = states
                case .failure(let error):
                    let message = String(describing: error)
                    perProvider[id] = Dictionary(
                        uniqueKeysWithValues: hashes.map { ($0, .error(message)) })
                }
            }
        }

        for hash in hashes {
            let states = perProvider.compactMapValues { $0[hash] }

            let holders = states.compactMap { id, state -> DebridProviderID? in
                if case .cached = state { return id }
                return nil
            }
            // Assigned rather than merged: a re-check is authoritative, so a
            // provider that has since evicted the torrent must drop out.
            cachedBy[hash] = holders.isEmpty ? nil : holders

            let merged = DebridRouter.mergeCacheStates(states)
            // `.error` is deliberately not memoized — see the type doc — so the
            // next bulk check retries it without the user clicking anything.
            let resolvedAt: Date? = {
                if case .error = merged { return nil }
                return now()
            }()
            set(hash, merged, resolvedAt: resolvedAt)
        }
    }

    private func isFresh(_ hash: String) -> Bool {
        guard let resolvedAt = entries[hash]?.resolvedAt else { return false }
        return now().timeIntervalSince(resolvedAt) < ttl
    }

    private func set(_ hash: String, _ state: CacheCheckState, resolvedAt: Date? = nil) {
        entries[hash] = Entry(state: state, resolvedAt: resolvedAt)
        continuation?.yield(Snapshot(hash: hash, state: state))
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
