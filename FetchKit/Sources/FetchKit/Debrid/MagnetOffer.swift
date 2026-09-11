import Foundation
import FetchPluginAPI

/**
 A magnet that arrived somewhere other than a search, offered as one row.

 The search field already takes a query. A magnet is not a query, and asking
 an indexer for one returns nothing — so the field stops pretending to search
 and offers the one thing there is to do with what it is holding. The row
 carries the magnet's own display name and enough of the infohash to tell one
 from another, so a wrong paste is visible **before** an account slot is spent
 on it.
 */
public struct MagnetOffer: Identifiable, Equatable, Sendable {
    public let magnet: MagnetLink

    public var id: String { magnet.infoHash.hex }

    public var displayName: String {
        guard let name = magnet.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return "Magnet link" }
        return name
    }

    public var shortHash: String {
        "btih:" + magnet.infoHash.hex.prefix(Self.shortHashLength) + "…"
    }

    public static let shortHashLength = 16

    public init(magnet: MagnetLink) {
        self.magnet = magnet
    }
}

public extension PastedLink {
    static func magnetOffer(from text: String) -> MagnetOffer? {
        MagnetLink(text).map(MagnetOffer.init(magnet:))
    }
}

public extension SearchResult {
    static func pastedMagnet(_ magnet: MagnetLink, source: SearchProviderID) -> SearchResult {
        let title = MagnetOffer(magnet: magnet).displayName
        return SearchResult(
            candidates: [.torrent(
                infoHash: magnet.infoHash, magnet: magnet, targetPath: nil)],
            title: title,
            size: nil,
            seeders: nil,
            peers: nil,
            category: nil,
            publishDate: nil,
            sources: [source],
            rawAttributes: [:],
            metadata: ReleaseNameParser.parse(title))
    }
}
