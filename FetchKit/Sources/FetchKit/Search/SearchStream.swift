import Foundation
import FetchPluginAPI

/// One indexer's contribution to a search, delivered the moment it lands.
public enum SearchEvent: Sendable {
    case started(providerCount: Int)
    case succeeded(id: SearchProviderID, results: [SearchResult], latency: TimeInterval)
    /// Latency is reported for failures too — a timeout is exactly the kind of
    /// slowness the per-indexer column in Settings exists to expose.
    case failed(id: SearchProviderID, error: any Error, latency: TimeInterval)
    case finished
}

extension SearchAggregator {
    /// Streams each provider's results as they arrive, instead of blocking on
    /// the slowest one.
    ///
    /// `search(_:)` is the same fan-out collected into a single `Outcome`, and
    /// the two are required to agree — see
    /// `StreamedResultAccumulator` for why that is not automatic.
    /// `offsets` is how far into *each* provider's own results the next page
    /// starts, keyed by provider.
    ///
    /// One shared offset was wrong, and quietly: providers clamp a requested
    /// page to what they will actually serve — a Torznab indexer to its
    /// advertised `maxLimit`, Internet Archive to a self-imposed 100,
    /// Gutenberg to whole 32-book pages — so "I asked for 500, therefore the
    /// next page starts at 500" skips everything between what a provider gave
    /// and what it was asked for. The only honest next offset is how many that
    /// provider has actually delivered, which the accumulator has been
    /// tracking all along.
    public func stream(
        _ query: SearchQuery, offsets: [SearchProviderID: Int] = [:]
    ) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let task = Task {
                let asked = await participants(for: query.categories)
                continuation.yield(.started(providerCount: asked.count))

                await withTaskGroup(of: SearchEvent.self) { group in
                    for provider in asked {
                        let timeout = perProviderTimeout
                        let providerQuery = offsets[provider.id].map {
                            SearchQuery(
                                text: query.text, mode: query.mode,
                                categories: query.categories,
                                limit: query.limit, offset: $0)
                        } ?? query
                        group.addTask {
                            let started = ContinuousClock.now
                            do {
                                let results = try await Self.withTimeout(seconds: timeout) {
                                    try await provider.search(providerQuery)
                                }
                                return .succeeded(
                                    id: provider.id, results: results,
                                    latency: started.secondsElapsed)
                            } catch {
                                return .failed(
                                    id: provider.id, error: error,
                                    latency: started.secondsElapsed)
                            }
                        }
                    }
                    for await event in group { continuation.yield(event) }
                }

                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension ContinuousClock.Instant {
    var secondsElapsed: TimeInterval {
        let elapsed = ContinuousClock.now - self
        return TimeInterval(elapsed.components.seconds)
            + TimeInterval(elapsed.components.attoseconds) / 1e18
    }
}

/// Folds `SearchEvent`s into the list the UI displays, plus progress.
///
/// **Why this is not just `results.append(contentsOf:)`.** `SearchAggregator`'s
/// dedupe is a running fold whose merge rule is order-sensitive: for one hash
/// seen on three indexers, the winning title is the longest and the base fields
/// come from the highest seeder count, so folding in a different order can
/// produce a different row. The batch path sorts per-provider buckets by
/// provider id before flattening precisely to pin that down. Appending in
/// arrival order would make the displayed list depend on network weather.
///
/// So this keeps buckets and re-folds the sorted whole on each event. That is
/// O(total results) per event — a few thousand operations for a seven-indexer
/// query, which is not worth optimising away.
public struct StreamedResultAccumulator: Sendable {
    public private(set) var results: [SearchResult] = []
    /// Releases the active profile refused, so the UI can offer to show them.
    public private(set) var filtered: [SearchResult] = []
    public private(set) var failures: [SearchProviderID: any Error] = [:]
    public private(set) var total = 0
    public private(set) var completed = 0
    public private(set) var isFinished = false

    /// Buckets, keyed by provider, sorted by id at fold time.
    private var buckets: [SearchProviderID: [SearchResult]] = [:]
    private var seenHashes: Set<String> = []

    private let profile: QualityProfile
    /// What the user typed. 7d ranks on name match first, so the streaming
    /// path needs it as much as the batch path — `SearchStreamTests` asserts
    /// the two produce identical lists, and that only holds if both have it.
    private let query: String
    private let excludeAdult: Bool

    public init(
        profile: QualityProfile = .default, query: String = "",
        excludeAdult: Bool = true
    ) {
        self.profile = profile
        self.query = query
        self.excludeAdult = excludeAdult
    }

    /// How many results this accumulator holds before the page being applied.
    /// A page that adds nothing new is how paging knows it has reached the end
    /// — no source reliably says "that was the last one".
    public var resultCount: Int { results.count }

    /// How many results each provider has actually handed over, which is
    /// where its next page starts. See `stream(_:offsets:)` for why the
    /// number asked for is the wrong answer.
    ///
    /// Counted before dedupe on purpose: a provider that returned twenty
    /// results of which eighteen were already on screen has still moved
    /// twenty results into the past, and asking it to start from two would
    /// serve those eighteen again forever.
    public var deliveredCounts: [SearchProviderID: Int] {
        buckets.mapValues(\.count)
    }

    /// Applies one event and returns the hashes seen for the **first** time,
    /// so a caller can start a cache check on each arriving batch rather than
    /// waiting for the whole set.
    ///
    /// `appending` is what makes paging possible. Without it `.succeeded`
    /// **replaces** a provider's contribution, which is right for a fresh
    /// search — a second answer from one indexer supersedes its first — and
    /// discards page 1 entirely the moment page 2 lands. With it, the pages
    /// stack and `refold` dedupes across them, so a release an indexer returns
    /// on page 1 and another returns on page 2 still collapses to one row.
    ///
    /// The progress counters reset per page rather than accumulating: "3 of 7
    /// indexers" is a statement about the request in flight, and summing it
    /// across pages would climb past the number of indexers there are.
    @discardableResult
    public mutating func apply(_ event: SearchEvent, appending: Bool = false) -> [String] {
        switch event {
        case .started(let count):
            total = count
            completed = 0
            isFinished = false
            return []

        case .succeeded(let id, let providerResults, _):
            completed += 1
            // Filtered on the way in, not only at fold time: an adult result
            // held in a bucket would still have its infohash sent for a cache
            // check below — a request about a result the user will never see.
            let permitted = excludeAdult
                ? AdultContentFilter.excludingAdult(providerResults) : providerResults
            if appending {
                buckets[id, default: []].append(contentsOf: permitted)
            } else {
                buckets[id] = permitted
            }
            // An indexer that answers is not a failing indexer, whatever it
            // did on an earlier page. Left in place, one flaky page would keep
            // "1 of 7 indexers failed" on screen for the rest of the search.
            failures[id] = nil
            refold()
            // Cache checking is a torrent-and-debrid concept, so results with
            // no infohash contribute nothing here. They are not dropped from
            // the list — they simply have no cache state to fetch, which is
            // what §4's `directReady` badge says instead.
            var fresh: [String] = []
            for hash in permitted.compactMap(\.infoHashHex)
            where seenHashes.insert(hash).inserted {
                fresh.append(hash)
            }
            return fresh

        case .failed(let id, let error, _):
            completed += 1
            failures[id] = error
            return []

        case .finished:
            isFinished = true
            return []
        }
    }

    private mutating func refold() {
        let ordered = buckets.keys
            .sorted { $0.rawValue < $1.rawValue }
            .flatMap { buckets[$0] ?? [] }
        let outcome = SearchAggregator.pipeline(
            ordered, profile: profile, matching: query, excludeAdult: excludeAdult)
        results = outcome.accepted
        filtered = outcome.rejected
    }
}
