import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

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
        #expect(indexers.allSatisfy { !$0.id.isEmpty })
        #expect(indexers.allSatisfy { !$0.name.isEmpty })
        #expect(Set(indexers.map(\.name)).count == indexers.count)
        #expect(indexers.contains { !$0.categories.isEmpty }, "no indexer carried any caps")
    }

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

    @Test(.enabled(if: LiveJackettTests.base != nil && LiveJackettTests.key != nil))
    func discoveryWorksFromTheSavedAggregateURLToo() async throws {
        let aggregate = URL(string: Self.base!)!
            .appendingPathComponent("api/v2.0/indexers/all/results/torznab/api")
        let indexers = try await JackettDirectory.discover(
            root: aggregate, apiKey: Redacted(Self.key!), client: HTTPClient())
        #expect(!indexers.isEmpty)
        #expect(JackettDirectory.isJackettShaped(aggregate))
    }

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
        #expect(results.allSatisfy { $0.infoHashHex?.count == 40 })
        #expect(results.allSatisfy { $0.magnetURI?.isEmpty == false })
        #expect(results.contains { $0.title.contains("Ramin Djawadi") })
    }
}
