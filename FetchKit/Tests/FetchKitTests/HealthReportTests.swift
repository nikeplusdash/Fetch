import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// The Health pane's judgement: what counts as a problem, and what order the
/// problems are read in.
@Suite struct HealthReportTests {
    private func indexer(
        _ name: String, answered: Int = 0, failed: Int = 0,
        averageLatency: TimeInterval = 0, isEnabled: Bool = true
    ) -> SubIndexer {
        var subject = SubIndexer(
            id: SearchProviderID(rawValue: name),
            name: name,
            torznabURL: URL(string: "http://localhost:9117/\(name)/api")!,
            isEnabled: isEnabled)
        for _ in 0..<answered { subject.recordProbe(latency: averageLatency, failure: nil) }
        for _ in 0..<failed { subject.recordProbe(latency: 0, failure: "timed out") }
        return subject
    }

    private func server(_ indexers: [SubIndexer]) -> IndexerServerConfig {
        IndexerServerConfig(
            id: IndexerServerID(rawValue: "jackett"),
            displayName: "Jackett",
            rootURL: URL(string: "http://localhost:9117")!,
            indexers: indexers)
    }

    // MARK: - Rolling measurement

    /// The whole reason this exists: one number from one query cannot tell an
    /// indexer that is usually fast from one that was fast once.
    @Test func healthAveragesEverySearchRatherThanKeepingTheLastOne() {
        var subject = indexer("knaben")
        subject.recordProbe(latency: 1, failure: nil)
        subject.recordProbe(latency: 3, failure: nil)
        #expect(subject.health?.answered == 2)
        #expect(subject.health?.averageLatency == 2)
        #expect(subject.health?.slowestLatency == 3)
        // The last-probe fields keep working for the edit sheet.
        #expect(subject.lastLatency == 3)
    }

    /// The time spent waiting for a failure is the timeout setting, which says
    /// more about the user than about the indexer.
    @Test func aFailureDoesNotDragTheAverageSpeedDown() {
        var subject = indexer("ebookbay")
        subject.recordProbe(latency: 1, failure: nil)
        subject.recordProbe(latency: 180, failure: "timed out")
        #expect(subject.health?.averageLatency == 1)
        #expect(subject.health?.failureRate == 0.5)
        #expect(subject.health?.lastFailure == "timed out")
    }

    @Test func nothingRecordedIsNilRatherThanZero() {
        let health = IndexerHealth()
        #expect(health.averageLatency == nil)
        #expect(health.failureRate == nil)
        #expect(HealthReport.verdict(for: health) == .untested)
    }

    // MARK: - Verdicts

    @Test func failingMoreOftenThanNotIsFailing() {
        let subject = indexer("x", answered: 2, failed: 3)
        #expect(HealthReport.verdict(for: subject.health) == .failing)
    }

    @Test func aFifthOfSearchesMissedIsUnreliable() {
        let subject = indexer("x", answered: 8, failed: 2)
        #expect(HealthReport.verdict(for: subject.health) == .unreliable)
    }

    /// **Two failures out of two is not a habit.** Without a floor, an indexer
    /// that happened to be restarting the first time it was ever asked would
    /// be branded failing on the strength of one search.
    @Test func aRateNeedsEnoughSearchesBehindItToMeanAnything() {
        let subject = indexer("x", answered: 0, failed: 2)
        #expect(HealthReport.verdict(for: subject.health) == .healthy)
        let established = indexer("y", answered: 1, failed: 4)
        #expect(HealthReport.verdict(for: established.health) == .failing)
    }

    @Test func answeringReliablyButSlowlyIsSlow() {
        let subject = indexer("1337x", answered: 6, averageLatency: 13)
        #expect(HealthReport.verdict(for: subject.health) == .slow)
    }

    @Test func fastAndReliableIsHealthy() {
        let subject = indexer("thepiratebay", answered: 20, averageLatency: 0.3)
        #expect(HealthReport.verdict(for: subject.health) == .healthy)
    }

    // MARK: - Ordering

    /// The pane exists to surface a problem, not to list an inventory.
    @Test func theWorstIndexerIsFirstAndTheDisabledOnesAreLast() {
        let rows = HealthReport.indexerRows([server([
            indexer("healthy", answered: 20, averageLatency: 0.2),
            indexer("switched-off", answered: 2, failed: 9, isEnabled: false),
            indexer("failing", answered: 2, failed: 9),
            indexer("slow", answered: 9, averageLatency: 20),
        ])])
        #expect(rows.map(\.name).map { $0.replacingOccurrences(of: "Jackett · ", with: "") }
            == ["failing", "slow", "healthy", "switched-off"])
    }

    /// A row the user has just been told about must not vanish the moment they
    /// act on it.
    @Test func aDisabledIndexerIsStillListed() {
        let rows = HealthReport.indexerRows([server([
            indexer("failing", answered: 2, failed: 9, isEnabled: false),
        ])])
        #expect(rows.count == 1)
        #expect(rows[0].isEnabled == false)
    }

    // MARK: - Timings

    /// Three numbers rather than a sentence, and the spread is the point: an
    /// indexer answering between 0.2s and 27s is a different problem from one
    /// that always takes 13s.
    @Test func timingsReportTheFastestSlowestAndAverage() throws {
        var subject = indexer("1337x")
        subject.recordProbe(latency: 0.2, failure: nil)
        subject.recordProbe(latency: 27, failure: nil)
        let row = try #require(HealthReport.indexerRows([server([subject])]).first)
        let timings = try #require(row.timings)
        #expect(timings.fastest == "200 ms")
        #expect(timings.slowest == "27.0s")
        #expect(timings.average == "13.6s")
    }

    /// An empty cell is honest; zeroes are not.
    @Test func nothingMeasuredHasNoTimingsAtAll() throws {
        let row = try #require(HealthReport.indexerRows([server([indexer("new")])]).first)
        #expect(row.timings == nil)
    }

    /// A failure contributes no timing, so an indexer that has only ever failed
    /// shows nothing rather than a fabricated zero.
    @Test func anIndexerThatHasOnlyFailedShowsNoTimings() throws {
        let row = try #require(HealthReport.indexerRows([server([
            indexer("dead", failed: 5),
        ])]).first)
        #expect(row.timings == nil)
        #expect(row.verdict == .failing)
    }

    // MARK: - Headline

    @Test func theHeadlineNamesTheOneProblemOrCountsThem() {
        #expect(HealthReport.headline(HealthReport.indexerRows([server([
            indexer("a", answered: 20, averageLatency: 0.2),
        ])])) == "All 1 indexers are healthy.")

        let one = HealthReport.headline(HealthReport.indexerRows([server([
            indexer("a", answered: 20, averageLatency: 0.2),
            indexer("bad", answered: 2, failed: 9),
        ])]))
        #expect(one.contains("bad"))
        #expect(one.contains("failing"))

        let many = HealthReport.headline(HealthReport.indexerRows([server([
            indexer("bad", answered: 2, failed: 9),
            indexer("worse", answered: 1, failed: 9),
        ])]))
        #expect(many == "2 indexers need attention.")
    }

    @Test func nothingMeasuredSaysSoRatherThanClaimingHealth() {
        #expect(HealthReport.headline(HealthReport.indexerRows([server([indexer("a")])]))
            == "Nothing measured yet. Run a search.")
    }

    // MARK: - Debrid

    private func debridRows(
        _ stats: [DebridProviderID: DebridCacheStats],
        canReport: Bool = true
    ) -> [HealthReport.DebridRow] {
        HealthReport.debridRows(
            providers: [
                (id: DebridProviderID(rawValue: "torbox"), name: "TorBox",
                 canReport: true, isEnabled: true),
                (id: DebridProviderID(rawValue: "realdebrid"), name: "Real-Debrid",
                 canReport: canReport, isEnabled: true),
            ],
            stats: stats)
    }

    @Test func theServiceHoldingMostOfWhatYouSearchForIsFirst() {
        let rows = debridRows([
            DebridProviderID(rawValue: "torbox"): DebridCacheStats(checked: 100, hits: 10),
            DebridProviderID(rawValue: "realdebrid"): DebridCacheStats(checked: 100, hits: 60),
        ])
        #expect(rows.map(\.name) == ["Real-Debrid", "TorBox"])
    }

    /// **Not a fabricated 0%.** Real-Debrid's availability endpoint is
    /// disabled, so it has no rate — and printing zero would be the same
    /// invented miss `CacheReadiness` exists to prevent.
    @Test func aServiceThatCannotReportSaysUnsupportedAndSortsLast() {
        let rows = debridRows([:], canReport: false)
        #expect(rows.last?.name == "Real-Debrid")
        #expect(rows.last?.stats.hitRate == nil)
        // Not a fabricated 0%, and not a sentence about what it holds: it
        // cannot answer the question at all.
        #expect(rows.last?.hitRateText == "Unsupported")
    }

    @Test func aServiceWithNothingCheckedShowsNothing() {
        let rows = debridRows([:])
        #expect(rows.first { $0.name == "TorBox" }?.hitRateText == "")
    }

    @Test func aReportedRateIsAPercentage() {
        let rows = debridRows([
            DebridProviderID(rawValue: "torbox"): DebridCacheStats(checked: 200, hits: 34),
        ])
        #expect(rows.first { $0.name == "TorBox" }?.hitRateText == "17%")
    }

    @Test func statsAddUpAcrossSessions() {
        let a = DebridCacheStats(checked: 10, hits: 3, errors: 1)
        let b = DebridCacheStats(checked: 5, hits: 2, errors: 0)
        #expect(a + b == DebridCacheStats(checked: 15, hits: 5, errors: 1))
        #expect((a + b).misses == 10)
    }

    // MARK: - Records that cannot be true

    /// **The exact records the reporting install had on disk.**
    /// `fastestLatency` was added after `answered` and `latencyTotal` were
    /// already persisted, so a decoded record kept its old count and total and
    /// then took its "minimum" from the first sample recorded afterwards. The
    /// pane printed `fastest: 544 ms / slowest: 544 ms / average: 313 ms`.
    @Test(arguments: [
        // RuTracker.org: mean 2.412s, "minimum" 2.666s.
        #"{"answered":4,"failed":0,"latencyTotal":9.649233,"slowestLatency":3.213529542,"fastestLatency":2.665611375}"#,
        // The Pirate Bay: mean 0.622s, "minimum" 1.051s.
        #"{"answered":7,"failed":0,"latencyTotal":4.356191834,"slowestLatency":1.178473542,"fastestLatency":1.050626416}"#,
        // 1337x: never given a minimum at all.
        #"{"answered":3,"failed":0,"latencyTotal":230.989695833,"slowestLatency":109.159748416}"#,
    ])
    func aRecordWhoseNumbersCannotAllBeTrueStartsAgain(json: String) throws {
        let decoded = try JSONDecoder().decode(IndexerHealth.self, from: Data(json.utf8))
        #expect(decoded.answered == 0)
        #expect(decoded.failed == 0)
        #expect(decoded.fastestLatency == nil)
        #expect(decoded.isConsistent)
    }

    /// A record that adds up is left exactly as it was. Knaben's, from the same
    /// install: mean 0.873s, between a 0.849s minimum and a 2.279s maximum.
    @Test func aConsistentRecordSurvivesDecodingUntouched() throws {
        let json = #"{"answered":6,"failed":0,"latencyTotal":5.236758875,"slowestLatency":2.278754625,"fastestLatency":0.84937825}"#
        let decoded = try JSONDecoder().decode(IndexerHealth.self, from: Data(json.utf8))
        #expect(decoded.answered == 6)
        #expect(decoded.fastestLatency == 0.84937825)
        #expect(decoded.isConsistent)
    }

    /// A single sample is the fastest, the slowest and the average at once, and
    /// the division must not fail the epsilon.
    @Test func oneSampleIsConsistentWithItself() throws {
        var subject = IndexerHealth()
        subject.record(latency: 4.829055625, failure: nil)
        let round = try JSONDecoder().decode(
            IndexerHealth.self, from: JSONEncoder().encode(subject))
        #expect(round == subject)
        #expect(round.isConsistent)
    }

    /// Belt and braces: even handed an impossible record directly, the pane
    /// shows nothing rather than nonsense.
    @Test func anImpossibleRecordIsNeverRendered() {
        let broken = IndexerHealth(
            answered: 7, failed: 0, latencyTotal: 4.356,
            slowestLatency: 1.178, fastestLatency: 1.050)
        #expect(!broken.isConsistent)
        var subject = indexer("tpb")
        subject.health = broken
        let row = HealthReport.indexerRows([server([subject])]).first
        #expect(row?.timings == nil)
    }
}
