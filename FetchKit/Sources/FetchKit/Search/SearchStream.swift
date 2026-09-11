import Foundation
import FetchPluginAPI

/**
 One indexer's contribution to a search, delivered the moment it lands.
 */
public enum SearchEvent: Sendable {
    case started(providers: [SearchProviderID])
    case succeeded(id: SearchProviderID, results: [SearchResult], latency: TimeInterval)
    case failed(id: SearchProviderID, error: any Error, latency: TimeInterval)
    case finished
}

extension SearchAggregator {
    /**
     Streams each provider's results as they arrive, instead of blocking on
     the slowest one.

     `search(_:)` is the same fan-out collected into a single `Outcome`, and
     the two are required to agree — see
     `StreamedResultAccumulator` for why that is not automatic.
     `offsets` is how far into *each* provider's own results the next page
     starts, keyed by provider.

     One shared offset was wrong, and quietly: providers clamp a requested
     page to what they will actually serve — a Torznab indexer to its
     advertised `maxLimit`, Internet Archive to a self-imposed 100,
     Gutenberg to whole 32-book pages — so "I asked for 500, therefore the
     next page starts at 500" skips everything between what a provider gave
     and what it was asked for. The only honest next offset is how many that
     provider has actually delivered, which the accumulator has been
     tracking all along.
     */
    public func stream(
        _ query: SearchQuery, offsets: [SearchProviderID: Int] = [:]
    ) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let task = Task {
                let asked = await participants(for: query.categories)
                continuation.yield(.started(providers: asked.map(\.id)))

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

/**
 Folds `SearchEvent`s into the list the UI displays, plus progress.

 **Why this is not just `results.append(contentsOf:)`.** `SearchAggregator`'s
 dedupe is a running fold whose merge rule is order-sensitive: for one hash
 seen on three indexers, the winning title is the longest and the base fields
 come from the highest seeder count, so folding in a different order can
 produce a different row. The batch path sorts per-provider buckets by
 provider id before flattening precisely to pin that down. Appending in
 arrival order would make the displayed list depend on network weather.

 So this keeps buckets and re-folds the sorted whole on each event. That is
 O(total results) per event — a few thousand operations for a seven-indexer
 query, which is not worth optimising away.
 */
public struct StreamedResultAccumulator: Sendable {
    public private(set) var results: [SearchResult] = []
    public private(set) var filtered: [SearchResult] = []
    public private(set) var failures: [SearchProviderID: any Error] = [:]
    public private(set) var total = 0
    public private(set) var completed = 0
    public private(set) var isFinished = false

    private var buckets: [SearchProviderID: [SearchResult]] = [:]
    private var seenHashes: Set<String> = []

    private var asked: [SearchProviderID] = []
    private var resolved: Set<SearchProviderID> = []

    private let profile: QualityProfile
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

    public var resultCount: Int { results.count }

    public var deliveredCounts: [SearchProviderID: Int] {
        buckets.mapValues(\.count)
    }

    /**
     Applies one event and returns the hashes seen for the **first** time,
     so a caller can start a cache check on each arriving batch rather than
     waiting for the whole set.

     `appending` is what makes paging possible. Without it `.succeeded`
     **replaces** a provider's contribution, which is right for a fresh
     search — a second answer from one indexer supersedes its first — and
     discards page 1 entirely the moment page 2 lands. With it, the pages
     stack and `refold` dedupes across them, so a release an indexer returns
     on page 1 and another returns on page 2 still collapses to one row.

     The progress counters reset per page rather than accumulating: "3 of 7
     indexers" is a statement about the request in flight, and summing it
     across pages would climb past the number of indexers there are.
     */
    @discardableResult
    public mutating func apply(_ event: SearchEvent, appending: Bool = false) -> [String] {
        switch event {
        case .started(let providers):
            asked = providers
            resolved = []
            total = providers.count
            completed = 0
            isFinished = false
            return []

        case .succeeded(let id, let providerResults, _):
            resolved.insert(id)
            completed += 1
            let permitted = excludeAdult
                ? AdultContentFilter.excludingAdult(providerResults) : providerResults
            if appending {
                buckets[id, default: []].append(contentsOf: permitted)
            } else {
                buckets[id] = permitted
            }
            failures[id] = nil
            refold()
            var fresh: [String] = []
            for hash in permitted.compactMap(\.infoHashHex)
            where seenHashes.insert(hash).inserted {
                fresh.append(hash)
            }
            return fresh

        case .failed(let id, let error, _):
            resolved.insert(id)
            completed += 1
            failures[id] = error
            return []

        case .finished:
            for id in asked where !resolved.contains(id) {
                failures[id] = SearchError.neverAnswered
                resolved.insert(id)
                completed += 1
            }
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
