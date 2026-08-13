import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// A provider that answers after a controllable delay, so completion order can
/// be shuffled deliberately rather than hoped for.
private struct SlowStubProvider: SearchProvider {
    let id: SearchProviderID
    let displayName: String
    let results: [SearchResult]
    let delay: Duration
    let failure: (any Error)?

    init(
        id: String, results: [SearchResult] = [],
        delayMilliseconds: Int = 0, failure: (any Error)? = nil
    ) {
        self.id = SearchProviderID(rawValue: id)
        self.displayName = id
        self.results = results
        self.delay = .milliseconds(delayMilliseconds)
        self.failure = failure
    }

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            categories: [], supportedModes: [.search], supportedAttributes: [], maxLimit: nil)
    }

    func search(_ query: SearchQuery) async throws -> [SearchResult] {
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        return results
    }
}

private func result(
    hash: String, title: String, seeders: Int, source: String
) -> SearchResult {
    // Padded to a real 40-char hash: `SearchResult` now parses it into a
    // torrent candidate, so "aa" would produce a result with no candidates
    // at all rather than one with a short hash.
    let hash = String((hash + String(repeating: "0", count: 40)).prefix(40))
    return SearchResult(
        infoHashHex: hash,
        title: title,
        size: 1_000,
        seeders: seeders,
        peers: 0,
        grabs: nil,
        fileCount: nil,
        category: nil,
        publishDate: nil,
        magnetURI: "magnet:?xt=urn:btih:\(hash)",
        sources: [SearchProviderID(rawValue: source)],
        rawAttributes: [:]
    )
}

@Suite struct SearchStreamTests {
    private func collect(
        _ aggregator: SearchAggregator, _ query: SearchQuery = SearchQuery(text: "q")
    ) async -> [SearchEvent] {
        var events: [SearchEvent] = []
        for await event in aggregator.stream(query) { events.append(event) }
        return events
    }

    // MARK: - Event shape

    @Test func theStreamAnnouncesHowManyProvidersItWillQuery() async {
        let aggregator = SearchAggregator(providers: [
            SlowStubProvider(id: "a"), SlowStubProvider(id: "b"), SlowStubProvider(id: "c"),
        ])
        let events = await collect(aggregator)
        guard case .started(let count)? = events.first else {
            Issue.record("first event was not .started, got \(String(describing: events.first))")
            return
        }
        #expect(count == 3)
    }

    @Test func theStreamFinishesExactlyOnce() async {
        let aggregator = SearchAggregator(providers: [
            SlowStubProvider(id: "a"), SlowStubProvider(id: "b"),
        ])
        let events = await collect(aggregator)
        let finishes = events.filter { if case .finished = $0 { true } else { false } }
        #expect(finishes.count == 1)
        if case .finished = events.last {} else {
            Issue.record("last event was not .finished")
        }
    }

    /// The point of the whole change: a fast indexer's results must be
    /// deliverable before a slow one has answered.
    @Test func aFastProviderIsDeliveredBeforeASlowOneFinishes() async {
        let aggregator = SearchAggregator(providers: [
            SlowStubProvider(
                id: "slow", results: [result(hash: "aa", title: "Slow", seeders: 9, source: "slow")],
                delayMilliseconds: 300),
            SlowStubProvider(
                id: "fast", results: [result(hash: "bb", title: "Fast", seeders: 1, source: "fast")],
                delayMilliseconds: 0),
        ])

        var firstSucceeded: SearchProviderID?
        for await event in aggregator.stream(SearchQuery(text: "q")) {
            if case .succeeded(let id, _, _) = event, firstSucceeded == nil {
                firstSucceeded = id
            }
        }
        #expect(firstSucceeded?.rawValue == "fast")
    }

    @Test func aFailingProviderIsReportedWithoutEndingTheStream() async {
        let aggregator = SearchAggregator(providers: [
            SlowStubProvider(id: "bad", failure: SearchError.unauthorized),
            SlowStubProvider(
                id: "good", results: [result(hash: "aa", title: "T", seeders: 1, source: "good")]),
        ])
        let events = await collect(aggregator)

        let failed = events.compactMap { if case .failed(let id, _, _) = $0 { id } else { nil } }
        let ok = events.compactMap { if case .succeeded(let id, _, _) = $0 { id } else { nil } }
        #expect(failed.map(\.rawValue) == ["bad"])
        #expect(ok.map(\.rawValue) == ["good"])
    }

    /// Latency feeds the edit sheet's per-indexer column, so it must be
    /// reported for failures too — a timeout is exactly what a user wants to
    /// see measured.
    @Test func latencyIsReportedForSuccessAndFailureAlike() async {
        let aggregator = SearchAggregator(providers: [
            SlowStubProvider(id: "ok", delayMilliseconds: 60),
            SlowStubProvider(id: "bad", delayMilliseconds: 60, failure: SearchError.unauthorized),
        ])
        let events = await collect(aggregator)

        let latencies = events.compactMap { event -> TimeInterval? in
            switch event {
            case .succeeded(_, _, let l), .failed(_, _, let l): l
            default: nil
            }
        }
        #expect(latencies.count == 2)
        #expect(latencies.allSatisfy { $0 >= 0.05 })
    }

    // MARK: - Determinism

    /// The property that makes streaming safe to adopt.
    ///
    /// `dedupe` is a running fold whose merge rule is order-sensitive — the
    /// winning title depends on which provider is folded first — which is why
    /// the batch path sorts buckets by provider id before flattening. If
    /// streaming folded in arrival order instead, the displayed list would vary
    /// with network weather. Accumulating per-provider buckets and re-folding
    /// sorted on each event keeps the two paths identical.
    @Test func theFinalStreamedListEqualsTheBatchResultWhateverTheOrder() async {
        // Same hash from three providers with different titles and seeders, so
        // the merge rule is actually exercised rather than trivially agreeing.
        let shared = "ffffffffffffffffffffffffffffffffffffffff"
        let providers: [any SearchProvider] = [
            SlowStubProvider(id: "c-slowest", results: [
                result(hash: shared, title: "A Very Long Descriptive Title", seeders: 5, source: "c-slowest"),
                result(hash: "1111111111111111111111111111111111111111", title: "Only C", seeders: 2, source: "c-slowest"),
            ], delayMilliseconds: 200),
            SlowStubProvider(id: "a-fastest", results: [
                result(hash: shared, title: "Short", seeders: 99, source: "a-fastest"),
            ], delayMilliseconds: 0),
            SlowStubProvider(id: "b-middle", results: [
                result(hash: shared, title: "Medium Title", seeders: 50, source: "b-middle"),
            ], delayMilliseconds: 100),
        ]

        let aggregator = SearchAggregator(providers: providers)
        let batch = await aggregator.search(SearchQuery(text: "q"))

        var accumulator = StreamedResultAccumulator()
        for await event in aggregator.stream(SearchQuery(text: "q")) {
            accumulator.apply(event)
        }

        #expect(accumulator.results.map(\.infoHashHex) == batch.results.map(\.infoHashHex))
        #expect(accumulator.results.map(\.title) == batch.results.map(\.title))
        #expect(accumulator.results.map(\.seeders) == batch.results.map(\.seeders))
        #expect(accumulator.results.first?.sources.count == 3)
    }

    @Test func theAccumulatorTracksProgressAndFailures() async {
        let aggregator = SearchAggregator(providers: [
            SlowStubProvider(id: "a", results: [result(hash: "aa", title: "A", seeders: 1, source: "a")]),
            SlowStubProvider(id: "b", failure: SearchError.unauthorized),
            SlowStubProvider(id: "c", results: [result(hash: "cc", title: "C", seeders: 2, source: "c")]),
        ])

        var accumulator = StreamedResultAccumulator()
        for await event in aggregator.stream(SearchQuery(text: "q")) {
            accumulator.apply(event)
        }

        #expect(accumulator.total == 3)
        #expect(accumulator.completed == 3)
        #expect(accumulator.failures.count == 1)
        #expect(accumulator.results.count == 2)
        #expect(accumulator.isFinished)
    }

    /// Each event carries only that provider's new hashes, so the cache check
    /// can start on the first batch instead of waiting for the whole set.
    @Test func theAccumulatorReportsOnlyNewlySeenHashes() async {
        let shared = "ffffffffffffffffffffffffffffffffffffffff"
        let aggregator = SearchAggregator(providers: [
            SlowStubProvider(id: "a", results: [
                result(hash: shared, title: "A", seeders: 1, source: "a")], delayMilliseconds: 0),
            SlowStubProvider(id: "b", results: [
                result(hash: shared, title: "B", seeders: 2, source: "b"),
                result(hash: "2222222222222222222222222222222222222222", title: "B2", seeders: 1, source: "b"),
            ], delayMilliseconds: 120),
        ])

        var accumulator = StreamedResultAccumulator()
        var batches: [[String]] = []
        for await event in aggregator.stream(SearchQuery(text: "q")) {
            let fresh = accumulator.apply(event)
            if !fresh.isEmpty { batches.append(fresh) }
        }

        #expect(batches == [[shared], ["2222222222222222222222222222222222222222"]])
    }

    @Test func noProvidersFinishesImmediatelyWithNothing() async {
        var accumulator = StreamedResultAccumulator()
        for await event in SearchAggregator(providers: []).stream(SearchQuery(text: "q")) {
            accumulator.apply(event)
        }
        #expect(accumulator.total == 0)
        #expect(accumulator.isFinished)
        #expect(accumulator.results.isEmpty)
    }
}
