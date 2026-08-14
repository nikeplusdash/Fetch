import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Hits a REAL Jackett. Skips unless FETCH_JACKETT_URL and FETCH_JACKETT_KEY
/// are set.
///
/// The offline tests pin the parser against a fixture; this pins the *premise*
/// — that `t=indexers` is reachable with nothing but the Torznab API key, and
/// that the endpoints it describes actually answer. Both were true when this
/// was written and both are properties of somebody else's server.
@Suite(.serialized) struct LiveJackettTests {
    static var base: String? { ProcessInfo.processInfo.environment["FETCH_JACKETT_URL"] }
    static var key: String? { ProcessInfo.processInfo.environment["FETCH_JACKETT_KEY"] }

    @Test(.enabled(if: LiveJackettTests.base != nil && LiveJackettTests.key != nil))
    func theRosterNamesEveryConfiguredIndexerAndWhatItCarries() async throws {
        let root = URL(string: Self.base!)!
        let indexers = try await JackettDirectory.discover(
            root: root, apiKey: Redacted(Self.key!), client: HTTPClient())

        print("ROSTER \(indexers.count) indexers")
        for indexer in indexers {
            let standard = indexer.categories.filter { $0.id < 10_000 }.map(\.id).sorted()
            print("  • \(indexer.id) — \(indexer.name)  cats=\(indexer.categories.count) "
                + "standard=\(standard)")
        }

        #expect(!indexers.isEmpty, "live Jackett listed no configured indexers")
        // A roster of one is the aggregate wearing a disguise, which is the
        // bug this exists to fix.
        #expect(indexers.allSatisfy { !$0.id.isEmpty })
        #expect(indexers.allSatisfy { !$0.name.isEmpty })
        // Names must not all be identical — the parser reading `<caps><server
        // title="Jackett">` instead of `<indexer><title>` would produce exactly
        // that, and every row would say "Jackett".
        #expect(Set(indexers.map(\.name)).count == indexers.count)
        #expect(indexers.contains { !$0.categories.isEmpty }, "no indexer carried any caps")
    }

    /// The URLs discovery hands out have to be the ones a search will use, and
    /// they are built by string-appending an id onto a trimmed root — the exact
    /// shape that goes wrong silently.
    @Test(.enabled(if: LiveJackettTests.base != nil && LiveJackettTests.key != nil))
    func everyDiscoveredEndpointAnswersItsOwnCaps() async throws {
        let root = URL(string: Self.base!)!
        let indexers = try await JackettDirectory.discover(
            root: root, apiKey: Redacted(Self.key!), client: HTTPClient())

        await withTaskGroup(of: (String, String?).self) { group in
            for indexer in indexers {
                group.addTask {
                    let provider = TorznabProvider(
                        id: SearchProviderID(rawValue: indexer.id),
                        displayName: indexer.name,
                        baseURL: indexer.torznabURL(root: root),
                        apiKey: Redacted(Self.key!),
                        client: HTTPClient())
                    do {
                        let caps = try await provider.capabilities()
                        return (indexer.id, caps.categories.isEmpty ? "no categories" : nil)
                    } catch {
                        return (indexer.id, "\(error)")
                    }
                }
            }
            for await (id, failure) in group {
                #expect(failure == nil, "\(id): \(failure ?? "")")
            }
        }
    }

    /// A saved Jackett server stores the **aggregate endpoint** as its root, so
    /// discovery has to work from that as well as from the bare host — every
    /// server configured before this existed is in exactly that state.
    @Test(.enabled(if: LiveJackettTests.base != nil && LiveJackettTests.key != nil))
    func discoveryWorksFromTheSavedAggregateURLToo() async throws {
        let aggregate = URL(string: Self.base!)!
            .appendingPathComponent("api/v2.0/indexers/all/results/torznab/api")
        let indexers = try await JackettDirectory.discover(
            root: aggregate, apiKey: Redacted(Self.key!), client: HTTPClient())
        #expect(!indexers.isEmpty)
        #expect(JackettDirectory.isJackettShaped(aggregate))
    }

    /// **The path a configured server actually takes.** The edit sheet fills
    /// its URL field from `rootURL`, which for every Jackett saved before
    /// discovery existed is the aggregate endpoint — a *complete* Torznab URL
    /// that `plan` used to take at its word and return as one indexer.
    @Test(.enabled(if: LiveJackettTests.base != nil && LiveJackettTests.key != nil))
    func planFromTheSavedAggregateURLSplitsItApart() async throws {
        let saved = URL(string: Self.base!)!
            .appendingPathComponent("api/v2.0/indexers/all/results/torznab/api")
        let plan = try await IndexerSetup.plan(
            url: saved, apiKey: Redacted(Self.key!), client: HTTPClient())
        guard case .jackett(_, let indexers) = plan else {
            Issue.record("a saved aggregate still planned as \(plan)")
            return
        }
        #expect(indexers.count > 1)
    }

    /// End to end through the entry point Settings actually calls.
    @Test(.enabled(if: LiveJackettTests.base != nil && LiveJackettTests.key != nil))
    func planFromABareHostReturnsAJackettPlanRatherThanOneAggregate() async throws {
        let plan = try await IndexerSetup.plan(
            url: URL(string: Self.base!)!,
            apiKey: Redacted(Self.key!),
            client: HTTPClient())
        guard case .jackett(let root, let indexers) = plan else {
            Issue.record("expected .jackett, got \(plan)")
            return
        }
        print("PLAN root=\(root.absoluteString) indexers=\(indexers.count)")
        #expect(indexers.count > 1)
    }

    /// **The result that was missing.** RuTracker needs a login, so Jackett
    /// publishes its items with no `magneturl` and no `infohash` — only a
    /// `/dl/rutracker/…` URL. The whole release was dropped in the parser.
    @Test(.enabled(if: LiveJackettTests.base != nil && LiveJackettTests.key != nil))
    func aLoginGatedTrackersResultIsRecoveredFromItsTorrentFile() async throws {
        let root = URL(string: Self.base!)!
        let provider = TorznabProvider(
            id: SearchProviderID(rawValue: "rutracker"),
            displayName: "RuTracker.org",
            baseURL: JackettDirectory.Indexer(id: "rutracker", name: "RuTracker.org")
                .torznabURL(root: root),
            apiKey: Redacted(Self.key!),
            client: HTTPClient())

        let results = try await provider.search(SearchQuery(
            text: "3 Body Problem",
            categories: SearchCategory.music.torznabCategories,
            limit: 100))

        for result in results {
            print("  • \(result.title.prefix(70))")
            print("    hash=\(result.infoHashHex ?? "-") seeds=\(result.seeders.map(String.init) ?? "-")")
        }
        #expect(!results.isEmpty, "the login-gated tracker returned nothing at all")
        // Every recovered result must be a *usable* torrent, not a row with a
        // title and nothing behind it.
        #expect(results.allSatisfy { $0.infoHashHex?.count == 40 })
        #expect(results.allSatisfy { $0.magnetURI?.isEmpty == false })
        #expect(results.contains { $0.title.contains("Ramin Djawadi") })
    }
}
