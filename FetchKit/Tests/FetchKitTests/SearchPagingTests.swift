import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

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

    @Test func withoutAppendingASecondAnswerStillReplaces() {
        var accumulator = accumulator()
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(1), title: "One")], latency: 0))
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(2), title: "Two")], latency: 0))

        #expect(accumulator.results.map(\.title) == ["Two"])
    }

    @Test func aResultSeenOnTwoPagesIsStillOneRow() {
        var accumulator = accumulator()
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(1), title: "Dune")], latency: 0))
        accumulator.apply(
            .succeeded(id: beta, results: [result(hash(1), title: "Dune 2021")], latency: 0),
            appending: true)

        #expect(accumulator.resultCount == 1)
    }


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

    @Test func anIndexerThatRecoversStopsBeingReportedAsFailed() {
        var accumulator = accumulator()
        accumulator.apply(.failed(id: alpha, error: SearchError.unauthorized, latency: 0))
        #expect(accumulator.failures.count == 1)

        accumulator.apply(
            .succeeded(id: alpha, results: [result(hash(1), title: "One")], latency: 0),
            appending: true)
        #expect(accumulator.failures.isEmpty)
    }

    @Test func aPageThatAddsNothingLeavesTheCountUnchanged() {
        var accumulator = accumulator()
        accumulator.apply(.succeeded(id: alpha, results: [result(hash(1), title: "One")], latency: 0))
        let before = accumulator.resultCount

        accumulator.apply(.succeeded(id: alpha, results: [], latency: 0), appending: true)

        #expect(accumulator.resultCount == before)
    }
}

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

    @Test func aProviderThatClampedIsAskedToResumeWhereItStopped() {
        var accumulator = StreamedResultAccumulator(query: "q", excludeAdult: false)
        accumulator.apply(.succeeded(
            id: alpha, results: (1...100).map(result), latency: 0))

        #expect(accumulator.deliveredCounts[alpha] == 100)
    }

    @Test func eachProviderCarriesItsOwnOffset() {
        var accumulator = StreamedResultAccumulator(query: "q", excludeAdult: false)
        accumulator.apply(.succeeded(id: alpha, results: (1...100).map(result), latency: 0))
        accumulator.apply(.succeeded(id: beta, results: (200...249).map(result), latency: 0))

        #expect(accumulator.deliveredCounts[alpha] == 100)
        #expect(accumulator.deliveredCounts[beta] == 50)
    }

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
