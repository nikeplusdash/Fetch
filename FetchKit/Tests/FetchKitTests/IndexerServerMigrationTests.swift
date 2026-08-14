import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Migration is the highest-risk piece of this change: it runs once, against
/// data the user cannot see, and getting it wrong loses a working setup.
///
/// Two separate incidents on 2026-08-01 — a Keychain-to-file credential store
/// switch, and a bundle identifier change that moved the UserDefaults domain —
/// both stranded live state by writing somewhere new and never reading the old
/// location again. Hence `IndexerServerMigration.fold` reads and never deletes,
/// and hence this many tests.
@Suite struct IndexerServerMigrationTests {
    private func legacy(_ name: String, _ url: String, enabled: Bool = true) -> SearchProviderConfig {
        SearchProviderConfig(
            id: SearchProviderID(rawValue: "legacy-\(name)"),
            displayName: name,
            baseURL: URL(string: url)!,
            isEnabled: enabled
        )
    }

    // MARK: - The shape this exists to fix

    /// The reported bug: one Prowlarr server showing as six top-level rows.
    @Test func aProwlarrFanOutFoldsBackIntoOneServer() {
        let servers = IndexerServerMigration.fold([
            legacy("Jackett — BlueRoms", "http://10.0.0.181:9696/9/api"),
            legacy("Jackett — dmhy", "http://10.0.0.181:9696/1/api"),
            legacy("Jackett — Nyaa.si", "http://10.0.0.181:9696/7/api"),
            legacy("Jackett — RuTor", "http://10.0.0.181:9696/5/api"),
            legacy("Jackett — The Pirate Bay", "http://10.0.0.181:9696/6/api"),
            legacy("Jackett — TorrentDownload", "http://10.0.0.181:9696/3/api"),
        ])

        #expect(servers.count == 1)
        let server = try! #require(servers.first)
        #expect(server.displayName == "Jackett")
        #expect(server.indexers.count == 6)
        #expect(server.indexers.map(\.name).sorted()
            == ["BlueRoms", "The Pirate Bay", "TorrentDownload", "Nyaa.si", "RuTor", "dmhy"].sorted())
    }

    @Test func theServerRootDropsThePerIndexerPath() {
        let servers = IndexerServerMigration.fold([
            legacy("Prowlarr — A", "http://10.0.0.181:9696/1/api"),
            legacy("Prowlarr — B", "http://10.0.0.181:9696/2/api"),
        ])
        #expect(servers.first?.rootURL.absoluteString == "http://10.0.0.181:9696")
    }

    // MARK: - Grouping rules

    /// Two servers on different ports of the same host are different servers.
    @Test func differentHostsAndPortsStaySeparate() {
        let servers = IndexerServerMigration.fold([
            legacy("Jackett", "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api"),
            legacy("Prowlarr — A", "http://10.0.0.181:9696/1/api"),
            legacy("Prowlarr — B", "http://10.0.0.181:9696/2/api"),
        ])
        #expect(servers.count == 2)
        #expect(Set(servers.map(\.displayName)) == ["Jackett", "Prowlarr"])
    }

    /// A standalone endpoint becomes a server holding exactly one indexer, so
    /// the search layer has a single shape to consume.
    @Test func aNameWithNoSeparatorBecomesASingleIndexerServer() {
        let servers = IndexerServerMigration.fold([
            legacy("Jackett", "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")
        ])
        #expect(servers.count == 1)
        #expect(servers[0].displayName == "Jackett")
        #expect(servers[0].indexers.count == 1)
        #expect(servers[0].indexers[0].name == "Jackett")
        #expect(servers[0].indexers[0].torznabURL.absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")
    }

    /// Same host and port, but names that disagree on the server prefix —
    /// group by endpoint, since the URL is authoritative and the name is not.
    @Test func nameDisagreementDoesNotSplitOneServer() {
        let servers = IndexerServerMigration.fold([
            legacy("Prowlarr — A", "http://10.0.0.181:9696/1/api"),
            legacy("Jackett — B", "http://10.0.0.181:9696/2/api"),
        ])
        #expect(servers.count == 1)
        #expect(servers[0].indexers.count == 2)
    }

    // MARK: - Preservation

    @Test func perIndexerEnablementSurvivesTheFold() {
        let servers = IndexerServerMigration.fold([
            legacy("P — A", "http://box:9696/1/api", enabled: true),
            legacy("P — B", "http://box:9696/2/api", enabled: false),
        ])
        let byName = Dictionary(uniqueKeysWithValues: servers[0].indexers.map { ($0.name, $0.isEnabled) })
        #expect(byName["A"] == true)
        #expect(byName["B"] == false)
    }

    /// The sub-indexer keeps the legacy provider id. Credentials are stored
    /// under that id, so changing it would strand every key — the exact
    /// failure this migration exists to avoid repeating.
    @Test func subIndexersKeepTheirLegacyProviderIDs() {
        let servers = IndexerServerMigration.fold([
            legacy("P — A", "http://box:9696/1/api")
        ])
        #expect(servers[0].indexers[0].id == SearchProviderID(rawValue: "legacy-P — A"))
    }

    /// A server with every indexer disabled is still enabled itself — the
    /// legacy model had no server-level flag, so inventing "off" here would
    /// silently disable a working setup.
    @Test func aFoldedServerIsEnabledEvenWhenAllItsIndexersAreOff() {
        let servers = IndexerServerMigration.fold([
            legacy("P — A", "http://box:9696/1/api", enabled: false),
            legacy("P — B", "http://box:9696/2/api", enabled: false),
        ])
        #expect(servers[0].isEnabled)
        #expect(servers[0].activeIndexers.isEmpty)
    }

    // MARK: - Degenerate input

    @Test func anEmptyLegacySetFoldsToNothing() {
        #expect(IndexerServerMigration.fold([]).isEmpty)
    }

    @Test func foldingIsIdempotentOnItsOwnOutput() {
        let input = [
            legacy("P — A", "http://box:9696/1/api"),
            legacy("P — B", "http://box:9696/2/api"),
        ]
        let once = IndexerServerMigration.fold(input)
        let twice = IndexerServerMigration.fold(input)
        #expect(once == twice)
    }

    /// Ordering must not depend on dictionary iteration, or the settings list
    /// reshuffles itself on every launch.
    @Test func serverAndIndexerOrderIsStable() {
        let input = [
            legacy("Z — c", "http://z:9696/3/api"),
            legacy("A — a", "http://a:9696/1/api"),
            legacy("Z — a", "http://z:9696/1/api"),
            legacy("A — b", "http://a:9696/2/api"),
        ]
        let first = IndexerServerMigration.fold(input)
        for _ in 0..<20 {
            #expect(IndexerServerMigration.fold(input) == first)
        }
        // Input order decides, so the settings list matches what was there.
        #expect(first.map(\.displayName) == ["Z", "A"])
        #expect(first[0].indexers.map(\.name) == ["c", "a"])
    }
}

/// The credential half of the migration. The fold above is pure; this moves the
/// API key from N per-indexer entries to one per-server entry, and is where a
/// mistake costs the user a working setup rather than a cosmetic regrouping.
@Suite struct IndexerServerCredentialMigrationTests {
    private func account(_ id: String) -> CredentialAccount {
        CredentialAccount(layer: "search", providerID: id)
    }

    private func legacy(_ name: String, _ url: String) -> SearchProviderConfig {
        SearchProviderConfig(
            id: SearchProviderID(rawValue: "legacy-\(name)"),
            displayName: name,
            baseURL: URL(string: url)!,
            isEnabled: true
        )
    }

    @Test func theServerGetsOneKeyCopiedFromItsIndexers() throws {
        let store = InMemoryCredentialStore([
            account("legacy-P — A"): "prowlarr-key",
            account("legacy-P — B"): "prowlarr-key",
        ])
        let servers = IndexerServerMigration.migrate(
            legacy: [legacy("P — A", "http://box:9696/1/api"),
                     legacy("P — B", "http://box:9696/2/api")],
            credentials: store)

        let serverID = try #require(servers.first?.id.rawValue)
        #expect(try store.read(for: account(serverID)) == "prowlarr-key")
    }

    /// One write per server, not one per indexer — the wart that motivated the
    /// whole restructure.
    @Test func theKeyIsWrittenOncePerServer() throws {
        let store = InMemoryCredentialStore([
            account("legacy-P — A"): "k", account("legacy-P — B"): "k",
            account("legacy-P — C"): "k",
        ])
        _ = IndexerServerMigration.migrate(
            legacy: [legacy("P — A", "http://box:9696/1/api"),
                     legacy("P — B", "http://box:9696/2/api"),
                     legacy("P — C", "http://box:9696/3/api")],
            credentials: store)
        #expect(store.writes.count == 1)
    }

    /// The old entries stay. Migration reads and never destroys, so rolling
    /// back to a previous build finds its credentials intact.
    @Test func theLegacyEntriesAreLeftInPlace() throws {
        let store = InMemoryCredentialStore([account("legacy-P — A"): "k"])
        _ = IndexerServerMigration.migrate(
            legacy: [legacy("P — A", "http://box:9696/1/api")], credentials: store)
        #expect(try store.read(for: account("legacy-P — A")) == "k")
    }

    /// A half-configured legacy set — some indexers never got a key written —
    /// must still yield a usable server rather than skipping it.
    @Test func aServerWhoseFirstIndexerLacksAKeyStillFindsOne() throws {
        let store = InMemoryCredentialStore([account("legacy-P — B"): "found-it"])
        let servers = IndexerServerMigration.migrate(
            legacy: [legacy("P — A", "http://box:9696/1/api"),
                     legacy("P — B", "http://box:9696/2/api")],
            credentials: store)

        let serverID = try #require(servers.first?.id.rawValue)
        #expect(try store.read(for: account(serverID)) == "found-it")
    }

    @Test func aServerWithNoKeyAtAllIsStillMigrated() throws {
        let store = InMemoryCredentialStore()
        let servers = IndexerServerMigration.migrate(
            legacy: [legacy("P — A", "http://box:9696/1/api")], credentials: store)
        #expect(servers.count == 1)
        #expect(store.writes.isEmpty)
    }

    /// Two servers must not cross-contaminate keys.
    @Test func eachServerKeepsItsOwnKey() throws {
        let store = InMemoryCredentialStore([
            account("legacy-J"): "jackett-key",
            account("legacy-P — A"): "prowlarr-key",
        ])
        let servers = IndexerServerMigration.migrate(
            legacy: [legacy("J", "http://box:9117/api/v2.0/indexers/all/results/torznab/api"),
                     legacy("P — A", "http://box:9696/1/api")],
            credentials: store)

        #expect(servers.count == 2)
        let jackett = try #require(servers.first { $0.displayName == "J" })
        let prowlarr = try #require(servers.first { $0.displayName == "P" })
        #expect(try store.read(for: account(jackett.id.rawValue)) == "jackett-key")
        #expect(try store.read(for: account(prowlarr.id.rawValue)) == "prowlarr-key")
    }
}

/// The exact config found on a real install on 2026-08-01, kept verbatim.
///
/// It has a property none of the synthetic cases above do: the display names
/// disagree with reality. The Jackett aggregate on :9117 was named "Prowlarr",
/// and the six Prowlarr indexers on :9696 were named "Jackett — …". Grouping by
/// URL origin rather than by name is what makes this fold correctly anyway.
@Suite struct RealWorldMigrationFixtureTests {
    private static let json = """
    [
     {"displayName":"Prowlarr","isEnabled":true,
      "id":"9A21F96E-967C-4223-97AC-D8507179B4CD",
      "baseURL":"http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api"},
     {"displayName":"Jackett — BlueRoms","isEnabled":true,
      "id":"8C8D4097-63F8-4A71-84CD-064B3396723E","baseURL":"http://10.0.0.181:9696/9/api"},
     {"displayName":"Jackett — dmhy","isEnabled":true,
      "id":"9F9B0E79-37E0-409F-8460-D18AB7CCC0F0","baseURL":"http://10.0.0.181:9696/1/api"},
     {"displayName":"Jackett — Nyaa.si","isEnabled":true,
      "id":"95DE80D1-7509-4C00-909A-8F00D746541A","baseURL":"http://10.0.0.181:9696/7/api"},
     {"displayName":"Jackett — RuTor","isEnabled":true,
      "id":"735F1F0A-9CFC-4EBB-BF0A-64A0CBE1284C","baseURL":"http://10.0.0.181:9696/5/api"},
     {"displayName":"Jackett — The Pirate Bay","isEnabled":true,
      "id":"EE74E532-F3AB-48C3-A6A7-D8115025592C","baseURL":"http://10.0.0.181:9696/6/api"},
     {"displayName":"Jackett — TorrentDownload","isEnabled":true,
      "id":"D64D6048-3020-4F97-9716-FECB441C30BE","baseURL":"http://10.0.0.181:9696/3/api"}
    ]
    """

    private func legacyConfigs() throws -> [SearchProviderConfig] {
        try JSONDecoder().decode([SearchProviderConfig].self, from: Data(Self.json.utf8))
    }

    @Test func sevenFlatRowsBecomeTwoServers() throws {
        let servers = IndexerServerMigration.fold(try legacyConfigs())

        #expect(servers.count == 2)
        #expect(servers.map(\.displayName) == ["Prowlarr", "Jackett"])
        #expect(servers[0].indexers.count == 1)
        #expect(servers[1].indexers.count == 6)
        // Nothing is dropped on the way through.
        #expect(servers.flatMap(\.indexers).count == 7)
    }

    @Test func theAggregateEndpointSurvivesIntact() throws {
        let servers = IndexerServerMigration.fold(try legacyConfigs())
        let aggregate = try #require(servers.first)

        #expect(aggregate.rootURL.absoluteString == "http://10.0.0.181:9117")
        // A standalone endpoint's full path must not be truncated to the root,
        // or it stops answering.
        #expect(aggregate.indexers[0].torznabURL.absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")
    }

    @Test func everyIndexerKeepsTheIDItsKeyIsStoredUnder() throws {
        let legacy = try legacyConfigs()
        let servers = IndexerServerMigration.fold(legacy)

        let migratedIDs = Set(servers.flatMap(\.indexers).map(\.id))
        #expect(migratedIDs == Set(legacy.map(\.id)))
    }

    @Test func eachServerEndsUpWithTheRightKey() throws {
        let legacy = try legacyConfigs()
        let store = InMemoryCredentialStore([
            CredentialAccount(layer: "search", providerID: "9A21F96E-967C-4223-97AC-D8507179B4CD"): "jackett-key",
            CredentialAccount(layer: "search", providerID: "8C8D4097-63F8-4A71-84CD-064B3396723E"): "prowlarr-key",
            CredentialAccount(layer: "search", providerID: "9F9B0E79-37E0-409F-8460-D18AB7CCC0F0"): "prowlarr-key",
        ])

        let servers = IndexerServerMigration.migrate(legacy: legacy, credentials: store)

        #expect(try store.read(for: CredentialAccount(
            layer: "search", providerID: servers[0].id.rawValue)) == "jackett-key")
        #expect(try store.read(for: CredentialAccount(
            layer: "search", providerID: servers[1].id.rawValue)) == "prowlarr-key")
        // Seven legacy entries collapse to two writes.
        #expect(store.writes.count == 2)
    }
}
