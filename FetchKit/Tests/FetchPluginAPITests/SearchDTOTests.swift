import Testing
import Foundation
@testable import FetchPluginAPI

@Suite struct SearchDTOTests {
    @Test func torznabCategoryRoundTrips() throws {
        let category = TorznabCategory(id: 5000, name: "TV")
        let data = try JSONEncoder().encode(category)
        #expect(try JSONDecoder().decode(TorznabCategory.self, from: data) == category)
    }

    @Test func standardCategoriesIncludeTheWellKnownNewznabIDs() {
        let ids = Set(TorznabCategory.standard.map(\.id))
        #expect(ids.isSuperset(of: [2000, 3000, 5000, 7000]))
    }

    @Test func searchModeKindRoundTrips() throws {
        for kind in SearchModeKind.allCases {
            let data = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(SearchModeKind.self, from: data) == kind)
        }
    }

    @Test func searchModeKindProjection() {
        #expect(SearchMode.general.kind == .search)
        #expect(SearchMode.tv(season: 3, episode: 5, tvdbID: nil).kind == .tvsearch)
        #expect(SearchMode.movie(imdbID: "tt123").kind == .movie)
        #expect(SearchMode.music.kind == .music)
        #expect(SearchMode.book.kind == .book)
    }

    @Test func searchQueryCarriesAPIVersionAndDefaults() {
        let query = SearchQuery(text: "The Expanse")
        #expect(query.apiVersion == currentAPIVersion)
        #expect(query.mode == .general)
        #expect(query.categories.isEmpty)
        #expect(query.limit == 50)
        #expect(query.offset == 0)
    }

    @Test func providerCapabilitiesCarriesAPIVersion() {
        let caps = ProviderCapabilities(
            categories: [TorznabCategory(id: 2000, name: "Movies")],
            supportedModes: [.search, .tvsearch],
            supportedAttributes: ["q", "season", "ep"],
            maxLimit: 100
        )
        #expect(caps.apiVersion == currentAPIVersion)
        #expect(caps.supportedModes.contains(.tvsearch))
    }

    @Test func searchResultIdentityIsTheInfoHash() {
        let result = SearchResult(
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            title: "The Expanse S03E05 1080p BluRay x265-GROUP",
            size: 1_234_567,
            seeders: 42,
            peers: 10,
            grabs: nil,
            fileCount: nil,
            category: nil,
            publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            sources: [SearchProviderID(rawValue: "jackett")],
            rawAttributes: [:]
        )
        #expect(result.id.rawValue == "btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        #expect(result.apiVersion == currentAPIVersion)
    }

    @Test func searchResultRoundTrips() throws {
        let result = SearchResult(
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            title: "A Title",
            size: 100,
            seeders: 1,
            peers: 2,
            grabs: 3,
            fileCount: 4,
            category: TorznabCategory(id: 5000, name: "TV"),
            publishDate: Date(timeIntervalSince1970: 0),
            magnetURI: "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            sources: [SearchProviderID(rawValue: "jackett")],
            rawAttributes: ["team": "GROUP"]
        )
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(SearchResult.self, from: data) == result)
    }

    /// A plugin conforming to `SearchProvider` must be implementable using
    /// only types visible from `FetchPluginAPI` — this is the compiler-enforced
    /// half of the boundary rule (§3), same as `BoundaryTests` for the debrid side.
    @Test func searchProviderIsImplementableWithoutImportingFetchKit() async throws {
        struct FakeSearchProvider: SearchProvider {
            let id = SearchProviderID(rawValue: "fake")
            let displayName = "Fake"
            func capabilities() async throws -> ProviderCapabilities {
                ProviderCapabilities(categories: [], supportedModes: [.search], supportedAttributes: [], maxLimit: nil)
            }
            func search(_ query: SearchQuery) async throws -> [SearchResult] { [] }
        }
        let provider = FakeSearchProvider()
        #expect(try await provider.search(SearchQuery(text: "x")).isEmpty)
    }
}
