import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Hits a REAL Prowlarr. Skips unless FETCH_PROWLARR_URL and FETCH_PROWLARR_KEY are set.
@Suite(.serialized) struct LiveProwlarrTests {
    static var base: String? { ProcessInfo.processInfo.environment["FETCH_PROWLARR_URL"] }
    static var key: String? { ProcessInfo.processInfo.environment["FETCH_PROWLARR_KEY"] }

    private func makeProvider() -> TorznabProvider {
        TorznabProvider(
            id: SearchProviderID(rawValue: "prowlarr-live"),
            displayName: "Prowlarr",
            baseURL: URL(string: Self.base!)!,
            apiKey: Redacted(Self.key!),
            client: HTTPClient())
    }

    @Test(.enabled(if: LiveProwlarrTests.base != nil && LiveProwlarrTests.key != nil))
    func capabilitiesAndSearchAgainstRealProwlarr() async throws {
        let provider = makeProvider()

        let caps = try await provider.capabilities()
        print("CAPS modes=\(caps.supportedModes.map(\.rawValue).sorted()) categories=\(caps.categories.count) maxLimit=\(String(describing: caps.maxLimit))")
        #expect(!caps.categories.isEmpty)

        let results = try await provider.search(
            SearchQuery(text: "dune", mode: .general, categories: [], limit: 25, offset: 0))
        print("RESULTS \(results.count)")
        for r in results.prefix(4) {
            print("  • \(r.title.prefix(58))\n    parsed: \(r.metadata.title ?? "?") | \(String(describing: r.metadata.resolution)) | \(String(describing: r.metadata.source))")
            print("    hash=\((r.infoHashHex ?? "-").prefix(12))…  size=\(r.size.map(ByteCount.format) ?? "-")  seeds=\(r.seeders.map(String.init) ?? "-")  attrs=\(r.rawAttributes.count)")
        }
        #expect(!results.isEmpty, "live Prowlarr returned nothing through TorznabProvider")
        // Every result must carry a usable, normalized hash or it is useless downstream.
        #expect(results.allSatisfy { $0.infoHashHex?.count == 40 })
        #expect(results.allSatisfy { $0.infoHashHex == $0.infoHashHex?.lowercased() })
    }

    /// The bug this guards: a user pastes the *root* URL from their browser
    /// (`http://host:9696`), which redirects to a login page, and every search
    /// fails with an XML parse error. Set FETCH_INDEXER_ROOT to a bare server
    /// root to prove resolution finds a working endpoint under it.
    static var root: String? { ProcessInfo.processInfo.environment["FETCH_INDEXER_ROOT"] }

    @Test(.enabled(if: LiveProwlarrTests.root != nil && LiveProwlarrTests.key != nil))
    func aPastedServerRootResolvesToAWorkingTorznabEndpoint() async throws {
        let plan = try await IndexerSetup.plan(
            url: URL(string: Self.root!)!,
            apiKey: Redacted(Self.key!),
            client: HTTPClient())

        // Whatever the plan, the deliverable is the same: endpoints that
        // actually return results for a real query.
        let endpoints: [(name: String, url: URL)]
        switch plan {
        case .single(let url, let caps):
            print("ROOT \(Self.root!)  ->  single endpoint \(url.absoluteString)")
            print("  modes=\(caps.supportedModes.map(\.rawValue).sorted()) "
                + "categories=\(caps.categories.count)")
            #expect(!caps.categories.isEmpty)
            endpoints = [(url.lastPathComponent, url)]
        case .prowlarr(let root, let indexers):
            print("ROOT \(Self.root!)  ->  Prowlarr, \(indexers.count) indexers")
            endpoints = indexers.map { ($0.name, $0.torznabURL(root: root)) }
        case .jackett(let root, let indexers):
            print("ROOT \(Self.root!)  ->  Jackett, \(indexers.count) indexers")
            endpoints = indexers.map { ($0.name, $0.torznabURL(root: root)) }
        }

        let aggregator = SearchAggregator(providers: endpoints.map { endpoint in
            TorznabProvider(
                id: SearchProviderID(rawValue: endpoint.name), displayName: endpoint.name,
                baseURL: endpoint.url, apiKey: Redacted(Self.key!), client: HTTPClient())
        })
        let outcome = await aggregator.search(SearchQuery(text: "dune"))

        for (name, url) in endpoints { print("  • \(name) -> \(url.absoluteString)") }
        print("  \(outcome.results.count) results, \(outcome.failures.count) failed")
        for (id, error) in outcome.failures {
            print("    ✗ \(id.rawValue): \(error.localizedDescription)")
        }
        #expect(!outcome.results.isEmpty, "a pasted root produced no usable results")
    }

    @Test(.enabled(if: LiveProwlarrTests.base != nil && LiveProwlarrTests.key != nil))
    func aggregatorPopulatesMetadataFromLiveResults() async throws {
        let agg = SearchAggregator(providers: [makeProvider()])
        let outcome = try await agg.search(
            SearchQuery(text: "dune 2160p", mode: .general, categories: [], limit: 25, offset: 0))
        let results = outcome.results
        print("AGG RESULTS \(results.count)")
        for r in results.prefix(5) {
            let m = r.metadata
            print("  • \(r.title.prefix(56))")
            print("    title=\(m.title ?? "nil") year=\(m.year.map(String.init) ?? "nil") res=\(String(describing: m.resolution)) src=\(String(describing: m.source)) grp=\(m.releaseGroup ?? "nil")")
        }
        let parsed = results.filter { $0.metadata.title != nil }.count
        print("PARSED \(parsed)/\(results.count) have a title")
        #expect(parsed > results.count / 2, "parser populated almost nothing on live data")
    }
}
