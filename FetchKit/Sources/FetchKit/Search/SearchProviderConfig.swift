import Foundation
import FetchPluginAPI

/// The non-secret half of a configured Torznab endpoint — display name,
/// base URL, and an enabled toggle (Settings § Search tab). The API key is
/// deliberately absent: it lives only in the Keychain, under
/// `CredentialAccount(layer: "search", providerID: id.rawValue)`, so this
/// type is safe to encode into `UserDefaults` in full.
public struct SearchProviderConfig: Sendable, Codable, Equatable, Identifiable {
    public var id: SearchProviderID
    public var displayName: String
    public var baseURL: URL
    public var isEnabled: Bool

    public init(
        id: SearchProviderID, displayName: String, baseURL: URL, isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.isEnabled = isEnabled
    }
}
