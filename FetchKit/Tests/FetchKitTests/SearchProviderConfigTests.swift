import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// `SearchProviderConfig` is the non-secret half of a configured Torznab
/// endpoint (display name, base URL, enabled toggle) — the API key never
/// lives on this type, only in the Keychore under
/// `CredentialAccount(layer: "search", providerID:)`, so this being
/// `Codable` and stored in `UserDefaults` (Settings § Search tab) can never
/// leak a key.
@Suite struct SearchProviderConfigTests {
    @Test func roundTripsThroughJSON() throws {
        let config = SearchProviderConfig(
            id: SearchProviderID(rawValue: "jackett-local"),
            displayName: "Jackett",
            baseURL: URL(string: "http://localhost:9117/api/v2.0/indexers/all/results/torznab/api")!,
            isEnabled: true
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SearchProviderConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test func arrayOfConfigsRoundTrips() throws {
        let configs = [
            SearchProviderConfig(
                id: SearchProviderID(rawValue: "a"), displayName: "A",
                baseURL: URL(string: "http://localhost:9117/api")!, isEnabled: true
            ),
            SearchProviderConfig(
                id: SearchProviderID(rawValue: "b"), displayName: "B",
                baseURL: URL(string: "http://localhost:9696/1/api")!, isEnabled: false
            ),
        ]
        let data = try JSONEncoder().encode(configs)
        let decoded = try JSONDecoder().decode([SearchProviderConfig].self, from: data)
        #expect(decoded == configs)
    }

    @Test func defaultsToEnabled() {
        let config = SearchProviderConfig(
            id: SearchProviderID(rawValue: "x"), displayName: "X",
            baseURL: URL(string: "http://localhost/api")!
        )
        #expect(config.isEnabled)
    }
}
