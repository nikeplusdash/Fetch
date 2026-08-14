import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Accumulating a second page of results into a search already on screen.
///
/// `StreamedResultAccumulator.apply` **replaces** a provider's bucket, which is
/// right for a fresh search — a second answer from one indexer supersedes its
/// first — and throws away page 1 the instant page 2 arrives. That is why
/// nothing paged: `SearchQuery` has carried `limit`/`offset` since M2 and every
/// provider honours them, but there was nowhere for a second page to go.
@Suite struct SearchPagingTests {
    private let alpha = SearchProviderID(rawValue: "alpha")
    private let beta = SearchProviderID(rawValue: "beta")

    private func result(_ hash: String, title: String, seeders: Int = 10) -> SearchResult {
        SearchResult(
            infoHashHex: hash,
            title: title,
            size: 1_000,
            seeders: seeders,
            peers: 1,
            grabs: nil,
            fileCount: nil,
            category: nil,
            publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [alpha],
            rawAttributes: [:])
    }

    private func hash(_ n: Int) -> String {
        String(format: "%040x", n)
    }

    private func accumulator() -> StreamedResultAccumulator {
        StreamedResultAccumulator(query: "dune", excludeAdult: false)
    }

    // MARK: - Accumulating

    @Test func asecondPageAddsToTheFirstRatherThanReplacingIt() {
        var accumulator = accumulator()
        accumulator.apply(.started(providers: [alpha]))
        accumulator.apply(.succeeded(
            id: alpha, results: [result(hash(1), title: "One"), result(hash(2), title: "Two")],
            latency: 0))
        accumulator.apply(.finished)
        #expect(accumulator.resultCount == 2)

        accumulator.apply(.started(providers: [alpha]))
        accumulator.apply(.succeeded(
            id: alpha, results: [result(hash(3), title: "Three")], latency: 0),
            appending: true)
        accumulator.apply(.finished)

        #expect(accumulator.resultCount == 3)
        #expect(Set(accumulator.results.map(\.title)) == ["One", "Two", "Three"])
    }

    /// Without `appending` the second answer supersedes the first, which is
    /// what a re-run of one indexer should do — the behaviour paging had to
    /// work around rather than change.
    @Test func withoutAppendingASecondAnswerStillReplaces() {
        var accumulator = accumulator()
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(1), title: "One")], latency: 0))
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(2), title: "Two")], latency: 0))

        #expect(accumulator.results.map(\.title) == ["Two"])
    }

    /// The dedupe is the reason a page is folded rather than concatenated: the
    /// same release turning up on page 2 of another indexer is one row, not
    /// two.
    @Test func aResultSeenOnTwoPagesIsStillOneRow() {
        var accumulator = accumulator()
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(1), title: "Dune")], latency: 0))
        accumulator.apply(
            .succeeded(id: beta, results: [result(hash(1), title: "Dune 2021")], latency: 0),
            appending: true)

        #expect(accumulator.resultCount == 1)
    }

    // MARK: - Every indexer resolves

    /// **The bar must not clear on a search that is an indexer short.** The
    /// fan-out is supposed to deliver one event per asked provider; when one
    /// goes missing the run used to end at "1 of 2" and clear anyway, with
    /// nothing on screen saying who never came back.
    @Test func anIndexerThatNeverReportsIsResolvedAsAFailureRatherThanLeftOpen() {
        var accumulator = accumulator()
        accumulator.apply(.started(providers: [alpha, beta]))
        accumulator.apply(.succeeded(id: alpha, results: [], latency: 0))
        accumulator.apply(.finished)

        #expect(accumulator.completed == accumulator.total)
        #expect(accumulator.failures.keys.contains(beta))
        #expect(accumulator.failures[alpha] == nil)
        if case .neverAnswered = accumulator.failures[beta] as? SearchError {} else {
            Issue.record("expected .neverAnswered, got \(String(describing: accumulator.failures[beta]))")
        }
    }

    /// The normal path stays untouched: nothing is invented when everybody
    /// answered, whatever they answered with.
    @Test func afullyReportedRoundInventsNoFailures() {
        var accumulator = accumulator()
        accumulator.apply(.started(providers: [alpha, beta]))
        accumulator.apply(.succeeded(id: alpha, results: [], latency: 0))
        accumulator.apply(.failed(id: beta, error: SearchError.providerTimeout, latency: 0))
        accumulator.apply(.finished)

        #expect(accumulator.completed == 2)
        #expect(accumulator.failures.count == 1)
        if case .providerTimeout = accumulator.failures[beta] as? SearchError {} else {
            Issue.record("a reported timeout must not be overwritten")
        }
    }

    /// Resolution is per round, not cumulative. On page 2 every provider
    /// already owns a bucket from page 1, so "has results" is not the same
    /// question as "answered this request".
    @Test func aProviderThatAnsweredPageOneMustStillAnswerPageTwo() {
        var accumulator = accumulator()
        accumulator.apply(.started(providers: [alpha, beta]))
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(1), title: "One")], latency: 0))
        accumulator.apply(.succeeded(id: beta, results: [result(hash(2), title: "Two")], latency: 0))
        accumulator.apply(.finished)
        #expect(accumulator.failures.isEmpty)

        accumulator.apply(.started(providers: [alpha, beta]))
        accumulator.apply(
            .succeeded(id: alpha, results: [result(hash(3), title: "Three")], latency: 0),
            appending: true)
        accumulator.apply(.finished)

        #expect(accumulator.completed == 2)
        #expect(accumulator.failures.keys.contains(beta))
    }

    // MARK: - Progress across pages

    /// "3 of 7 indexers" is a statement about the request in flight. Summed
    /// across pages it climbs past the number of indexers there are.
    @Test func progressCountersResetPerPage() {
        var accumulator = accumulator()
        accumulator.apply(.started(providers: [alpha, beta]))
        accumulator.apply(.succeeded(id: alpha, results: [], latency: 0))
        accumulator.apply(.succeeded(id: beta, results: [], latency: 0))
        accumulator.apply(.finished)
        #expect(accumulator.completed == 2)
        #expect(accumulator.isFinished)

        accumulator.apply(.started(providers: [alpha, beta]))
        #expect(accumulator.completed == 0)
        #expect(!accumulator.isFinished)
        #expect(accumulator.total == 2)
    }

    /// An indexer that answers is not a failing indexer, whatever it did on an
    /// earlier page — otherwise one flaky page leaves "1 of 7 indexers failed"
    /// on screen for the rest of the search.
    @Test func anIndexerThatRecoversStopsBeingReportedAsFailed() {
        var accumulator = accumulator()
        accumulator.apply(.failed(id: alpha, error: SearchError.unauthorized, latency: 0))
        #expect(accumulator.failures.count == 1)

        accumulator.apply(
            .succeeded(id: alpha, results: [result(hash(1), title: "One")], latency: 0),
            appending: true)
        #expect(accumulator.failures.isEmpty)
    }

    /// The end condition. No source reliably says "that was the last one", so a
    /// page that adds nothing new is what stops the scroll.
    @Test func aPageThatAddsNothingLeavesTheCountUnchanged() {
        var accumulator = accumulator()
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(1), title: "One")], latency: 0))
        let before = accumulator.resultCount

        accumulator.apply(.succeeded(id: alpha, results: [], latency: 0), appending: true)

        #expect(accumulator.resultCount == before)
    }
}

/// Where the next page starts.
///
/// Found by running it: a Jackett `/all/` aggregate does not implement
/// `offset` at all — any offset above zero returns an empty feed in 21ms —
/// while `limit` is honoured to the 1000 its own caps advertise, and a query
/// costs the same ~14s whether it asks for 50 results or 473. So Fetch asked
/// for 50 of 473, showed 20 after dedupe and the profile, and scrolling asked
/// for offset 50 and correctly concluded it had reached the end of a list it
/// had barely started.
@Suite struct DeliveredOffsetTests {
    private let alpha = SearchProviderID(rawValue: "alpha")
    private let beta = SearchProviderID(rawValue: "beta")

    private func result(_ n: Int) -> SearchResult {
        SearchResult(
            infoHashHex: String(format: "%040x", n), title: "R\(n)", size: 1,
            seeders: 1, peers: 0, grabs: nil, fileCount: nil, category: nil,
            publishDate: nil, magnetURI: "magnet:?xt=urn:btih:\(String(format: "%040x", n))",
            sources: [alpha], rawAttributes: [:])
    }

    /// The bug: a provider asked for 500 that serves 100 has delivered 100,
    /// and starting its next page at 500 skips four hundred results nobody
    /// will ever see.
    @Test func aProviderThatClampedIsAskedToResumeWhereItStopped() {
        var accumulator = StreamedResultAccumulator(query: "q", excludeAdult: false)
        accumulator.apply(.succeeded(
            id: alpha, results: (1...100).map(result), latency: 0))

        #expect(accumulator.deliveredCounts[alpha] == 100)
    }

    /// Providers clamp differently, so one shared offset cannot be right for
    /// both of them at once.
    @Test func eachProviderCarriesItsOwnOffset() {
        var accumulator = StreamedResultAccumulator(query: "q", excludeAdult: false)
        accumulator.apply(.succeeded(id: alpha, results: (1...100).map(result), latency: 0))
        accumulator.apply(.succeeded(id: beta, results: (200...249).map(result), latency: 0))

        #expect(accumulator.deliveredCounts[alpha] == 100)
        #expect(accumulator.deliveredCounts[beta] == 50)
    }

    /// Counted before dedupe. A provider that returned twenty of which
    /// eighteen were already on screen has still moved twenty results into
    /// the past; resuming it at two would serve those eighteen forever.
    @Test func theCountIsWhatWasDeliveredNotWhatSurvivedDedupe() {
        var accumulator = StreamedResultAccumulator(query: "q", excludeAdult: false)
        accumulator.apply(.succeeded(id: alpha, results: (1...20).map(result), latency: 0))
        accumulator.apply(
            .succeeded(id: beta, results: (1...20).map(result), latency: 0), appending: true)

        #expect(accumulator.resultCount == 20, "the same twenty releases dedupe to twenty rows")
        #expect(accumulator.deliveredCounts[beta] == 20, "but beta still handed over twenty")
    }

    @Test func aProviderThatHasAnsweredNothingHasNoOffset() {
        var accumulator = StreamedResultAccumulator(query: "q", excludeAdult: false)
        accumulator.apply(.failed(id: alpha, error: SearchError.unauthorized, latency: 0))

        #expect(accumulator.deliveredCounts[alpha] == nil)
    }
}
