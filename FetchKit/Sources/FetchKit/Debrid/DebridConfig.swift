import Foundation
import FetchPluginAPI

/// The debrid services a user has configured, in preference order.
///
/// No API key here: it lives only in the credential store under
/// `CredentialAccount(layer: "debrid", providerID: id.rawValue)` — the shape
/// the TorBox key already used, so an existing install needs no migration.
public struct DebridConfig: Sendable, Codable, Equatable, Identifiable {
    public var id: DebridProviderID
    public var isEnabled: Bool

    public init(id: DebridProviderID, isEnabled: Bool = true) {
        self.id = id
        self.isEnabled = isEnabled
    }
}

/// The services this build can talk to, where a user finds their key, and how
/// to build one.
///
/// **Every field is derived from the provider type it describes.** It stayed a
/// table because Settings has to render a service the user has *not*
/// configured — there is no instance to ask, and demanding a `static
/// displayName` of every `DebridProvider` would push that into the plugin
/// contract, where a per-instance name is legitimate (`TorznabProvider` has
/// one).
///
/// The derivation is not tidiness. `AppModel` stores the **instance's**
/// `displayName` when routing a download and the **table's** when restoring
/// one, then compares them to decide whether a provider can be removed. One
/// character of drift and `removeDebrid` either refuses forever or tears down
/// a provider with live downloads. `DebridKindTests` asserts they agree.
public struct DebridKind: Sendable, Identifiable {
    public let id: DebridProviderID
    public let displayName: String
    /// Opened by Settings' "Get my API key" button. A link and a paste needs
    /// no registered client_id, cannot be revoked out from under the app, and
    /// works behind any network — unlike an OAuth device flow.
    public let apiKeyPageURL: URL
    /// False for Real-Debrid, whose instant-availability endpoint is disabled.
    /// Surfaced in Settings so the limitation is visible before it is noticed
    /// as an absent badge column.
    public let canReportCacheStatus: Bool
    /// Builds the live provider. Previously a `switch` on the raw id string,
    /// spelled once in `AppModel.makeProvider` and again in
    /// `SettingsView.testConnection` — so a fourth service meant editing two
    /// places, and either could silently disagree with this table.
    public let makeProvider: @Sendable (Redacted<String>, any HTTPClientProtocol)
        -> any DebridProvider

    public static let torbox = DebridKind(
        id: TorBoxProvider.providerID,
        displayName: TorBoxProvider.providerName,
        apiKeyPageURL: TorBoxProvider.apiKeyPageURL,
        canReportCacheStatus: TorBoxProvider.reportsCacheStatus,
        makeProvider: { TorBoxProvider(apiKey: $0, client: $1) })

    public static let premiumize = DebridKind(
        id: PremiumizeProvider.providerID,
        displayName: PremiumizeProvider.providerName,
        apiKeyPageURL: PremiumizeProvider.apiKeyPageURL,
        canReportCacheStatus: PremiumizeProvider.reportsCacheStatus,
        makeProvider: { PremiumizeProvider(apiKey: $0, client: $1) })

    public static let realDebrid = DebridKind(
        id: RealDebridProvider.providerID,
        displayName: RealDebridProvider.providerName,
        apiKeyPageURL: RealDebridProvider.apiKeyPageURL,
        canReportCacheStatus: RealDebridProvider.reportsCacheStatus,
        makeProvider: { RealDebridProvider(apiKey: $0, client: $1) })

    public static let all: [DebridKind] = [.torbox, .premiumize, .realDebrid]

    public static func kind(for id: DebridProviderID) -> DebridKind? {
        all.first { $0.id == id }
    }
}

/// Hand-written because the stored closure is not `Equatable`. Identity is the
/// service, so comparing ids is also the correct definition.
extension DebridKind: Equatable {
    public static func == (lhs: DebridKind, rhs: DebridKind) -> Bool {
        lhs.id == rhs.id
    }
}
