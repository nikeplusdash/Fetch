import Foundation

public struct CredentialAccount: Hashable, Sendable {
    public let layer: String        // "debrid" | "search"
    public let providerID: String

    public init(layer: String, providerID: String) {
        self.layer = layer
        self.providerID = providerID
    }

    /// Unit separator, not ".": plugin identifiers are reverse-DNS, so a
    /// dot-joined key would let (layer:"debrid", provider:"a.b") collide
    /// with (layer:"debrid.a", provider:"b").
    public var key: String { "\(layer)\u{1F}\(providerID)" }
}

/// Where secrets live. `FileCredentialStore` is the only implementation;
/// the protocol survives it so tests can substitute an in-memory double
/// without touching the filesystem.
///
/// **There was a Keychain implementation and it caused a data-loss bug.**
/// Switching the default store from Keychain to file shipped no migration,
/// so an already-saved TorBox key stayed in the Keychain while the app read
/// an empty file store, ran unconfigured, and reported every search result
/// as "not cached". If a second store is ever added, migrate on read or
/// this repeats.
public protocol CredentialStore: Sendable {
    func store(_ secret: String, for account: CredentialAccount) throws
    func read(for account: CredentialAccount) throws -> String?
    func delete(for account: CredentialAccount) throws
}
