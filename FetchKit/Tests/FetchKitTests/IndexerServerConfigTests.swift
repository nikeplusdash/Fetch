import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct IndexerServerConfigTests {
    private func sub(
        _ name: String, _ url: String, enabled: Bool = true
    ) -> SubIndexer {
        SubIndexer(
            id: SearchProviderID(rawValue: "id-\(name)"),
            name: name,
            torznabURL: URL(string: url)!,
            isEnabled: enabled
        )
    }

    private func server(
        _ name: String, root: String, enabled: Bool = true, indexers: [SubIndexer]
    ) -> IndexerServerConfig {
        IndexerServerConfig(
            id: IndexerServerID(rawValue: "srv-\(name)"),
            displayName: name,
            rootURL: URL(string: root)!,
            isEnabled: enabled,
            indexers: indexers
        )
    }

    // MARK: - Effective enablement

    @Test func anEnabledServerSearchesOnlyItsEnabledIndexers() {
        let config = server("Prowlarr", root: "http://box:9696", indexers: [
            sub("a", "http://box:9696/1/api"),
            sub("b", "http://box:9696/2/api", enabled: false),
            sub("c", "http://box:9696/3/api"),
        ])
        #expect(config.activeIndexers.map(\.name) == ["a", "c"])
    }

    /// Disabling the server must not clear the per-indexer toggles, so
    /// re-enabling restores exactly the previous selection rather than
    /// silently turning everything back on.
    @Test func aDisabledServerContributesNothingButKeepsItsToggles() {
        let config = server("Prowlarr", root: "http://box:9696", enabled: false, indexers: [
            sub("a", "http://box:9696/1/api"),
            sub("b", "http://box:9696/2/api", enabled: false),
        ])
        #expect(config.activeIndexers.isEmpty)
        #expect(config.indexers.map(\.isEnabled) == [true, false])
    }

    @Test func theRowSummaryCountsEnabledAgainstTotal() {
        let config = server("Prowlarr", root: "http://box:9696", indexers: [
            sub("a", "http://box:9696/1/api"),
            sub("b", "http://box:9696/2/api", enabled: false),
            sub("c", "http://box:9696/3/api"),
        ])
        #expect(config.enabledCount == 2)
        #expect(config.indexers.count == 3)
    }

    // MARK: - Round trip

    @Test func configRoundTripsThroughJSON() throws {
        var indexer = sub("The Pirate Bay", "http://box:9696/6/api")
        indexer.lastLatency = 0.24
        indexer.lastProbeFailure = "timed out"
        let original = server("Prowlarr", root: "http://box:9696", indexers: [indexer])

        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([IndexerServerConfig].self, from: data)

        #expect(decoded == [original])
        #expect(decoded[0].indexers[0].lastProbeFailure == "timed out")
    }

    /// The config is written to UserDefaults in full, so it must never carry
    /// the API key — that lives only in the credential store, keyed by the
    /// server's id.
    @Test func configCarriesNoSecret() throws {
        let original = server("Prowlarr", root: "http://user:hunter2@box:9696", indexers: [
            sub("a", "http://box:9696/1/api")
        ])
        let json = String(data: try JSONEncoder().encode(original), encoding: .utf8)!
        #expect(!json.contains("apiKey"))
        #expect(!json.contains("key"))
    }
}

/// What a probe records.
///
/// It used to record a result count, which was meaningless: the probe queried
/// a fixed arbitrary term, and a count is only comparable between indexers of
/// the same scope anyway — an anime tracker returning few results for a film
/// says nothing about the tracker. Latency is kept because it is the real wait,
/// and a failure now carries its reason instead of collapsing to zero.
@Suite struct IndexerProbeTests {
    private func indexer() -> SubIndexer {
        SubIndexer(
            id: SearchProviderID(rawValue: "i"), name: "Nyaa",
            torznabURL: URL(string: "http://box:9696/7/api")!)
    }

    @Test func afreshIndexerHasNoProbeRecorded() {
        let i = indexer()
        #expect(i.lastLatency == nil)
        #expect(i.lastProbeFailure == nil)
    }

    /// The distinction the old column could not draw: an indexer that answered
    /// with nothing looked identical to one that timed out.
    @Test func aSuccessfulProbeRecordsLatencyAndNoFailure() {
        var i = indexer()
        i.recordProbe(latency: 0.495, failure: nil)
        #expect(i.lastLatency == 0.495)
        #expect(i.lastProbeFailure == nil)
        #expect(i.lastTestedAt != nil)
    }

    @Test func aFailedProbeRecordsWhy() {
        var i = indexer()
        i.recordProbe(latency: 25.0, failure: "timed out")
        #expect(i.lastLatency == 25.0)
        #expect(i.lastProbeFailure == "timed out")
    }

    /// A later success must clear the earlier failure, or a fixed indexer
    /// stays marked broken forever.
    @Test func aSuccessAfterAFailureClearsIt() {
        var i = indexer()
        i.recordProbe(latency: 25.0, failure: "timed out")
        i.recordProbe(latency: 0.3, failure: nil)
        #expect(i.lastProbeFailure == nil)
    }

    /// Configs persisted before the count was dropped must still decode —
    /// otherwise the whole server list is lost on upgrade, which is the
    /// failure mode this project has hit twice already.
    @Test func aConfigWrittenWithTheOldResultCountStillDecodes() throws {
        let legacy = """
        [{"id":"srv","displayName":"Prowlarr","rootURL":"http://box:9696",
          "isEnabled":true,
          "indexers":[{"id":"i","name":"Nyaa","torznabURL":"http://box:9696/7/api",
                       "isEnabled":true,"isMissingFromServer":false,
                       "lastLatency":0.5,"lastResultCount":9}]}]
        """
        let decoded = try JSONDecoder().decode(
            [IndexerServerConfig].self, from: Data(legacy.utf8))

        #expect(decoded.count == 1)
        #expect(decoded[0].indexers[0].lastLatency == 0.5)
        #expect(decoded[0].indexers[0].lastProbeFailure == nil)
    }
}
