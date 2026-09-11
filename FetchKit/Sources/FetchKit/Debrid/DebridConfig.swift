import Foundation
import FetchPluginAPI

/**
 The debrid services a user has configured, in preference order.

 No API key here: it lives only in the credential store under
 `CredentialAccount(layer: "debrid", providerID: id.rawValue)` — the shape
 the TorBox key already used, so an existing install needs no migration.
 */
public struct DebridConfig: Sendable, Codable, Equatable, Identifiable {
    public var id: DebridProviderID
    public var isEnabled: Bool

    public init(id: DebridProviderID, isEnabled: Bool = true) {
        self.id = id
        self.isEnabled = isEnabled
    }
}

/**
 The services this build can talk to, where a user finds their key, and how
 to build one.

 **Every field is derived from the provider type it describes.** It stayed a
 table because Settings has to render a service the user has *not*
 configured — there is no instance to ask, and demanding a `static
 displayName` of every `DebridProvider` would push that into the plugin
 contract, where a per-instance name is legitimate (`TorznabProvider` has
 one).

 The derivation is not tidiness. `AppModel` stores the **instance's**
 `displayName` when routing a download and the **table's** when restoring
 one, then compares them to decide whether a provider can be removed. One
 character of drift and `removeDebrid` either refuses forever or tears down
 a provider with live downloads. `DebridKindTests` asserts they agree.
 */
public struct DebridKind: Sendable, Identifiable {
    public let id: DebridProviderID
    public let displayName: String
    public let apiKeyPageURL: URL
    /**
     Where "Open on <service>" goes.

     A home page rather than a deep link, because none of the three services
     documents a per-torrent web URL. A guessed pattern either 404s or, worse,
     lands on somebody else's account view; a home page is at least honest
     about being a fallback.
     */
    public let homePageURL: URL
    public let canReportCacheStatus: Bool
    public let makeProvider: @Sendable (Redacted<String>, any HTTPClientProtocol)
        -> any DebridProvider

    public static let torbox = DebridKind(
        id: TorBoxProvider.providerID,
        displayName: TorBoxProvider.providerName,
        apiKeyPageURL: TorBoxProvider.apiKeyPageURL,
        homePageURL: TorBoxProvider.homePageURL,
        canReportCacheStatus: TorBoxProvider.reportsCacheStatus,
        makeProvider: { TorBoxProvider(apiKey: $0, client: $1) })

    public static let premiumize = DebridKind(
        id: PremiumizeProvider.providerID,
        displayName: PremiumizeProvider.providerName,
        apiKeyPageURL: PremiumizeProvider.apiKeyPageURL,
        homePageURL: PremiumizeProvider.homePageURL,
        canReportCacheStatus: PremiumizeProvider.reportsCacheStatus,
        makeProvider: { PremiumizeProvider(apiKey: $0, client: $1) })

    public static let realDebrid = DebridKind(
        id: RealDebridProvider.providerID,
        displayName: RealDebridProvider.providerName,
        apiKeyPageURL: RealDebridProvider.apiKeyPageURL,
        homePageURL: RealDebridProvider.homePageURL,
        canReportCacheStatus: RealDebridProvider.reportsCacheStatus,
        makeProvider: { RealDebridProvider(apiKey: $0, client: $1) })

    public static let all: [DebridKind] = [.torbox, .premiumize, .realDebrid]

    public static func kind(for id: DebridProviderID) -> DebridKind? {
        all.first { $0.id == id }
    }
}

extension DebridKind: Equatable {
    public static func == (lhs: DebridKind, rhs: DebridKind) -> Bool {
        lhs.id == rhs.id
    }
}
