import Foundation
import FetchPluginAPI

/// A magnet that arrived somewhere other than a search, offered as one row.
///
/// The search field already takes a query. A magnet is not a query, and asking
/// an indexer for one returns nothing — so the field stops pretending to search
/// and offers the one thing there is to do with what it is holding. The row
/// carries the magnet's own display name and enough of the infohash to tell one
/// from another, so a wrong paste is visible **before** an account slot is spent
/// on it.
public struct MagnetOffer: Identifiable, Equatable, Sendable {
    public let magnet: MagnetLink

    /// The infohash, which is the identity — two pastes of the same torrent are
    /// one offer, not two rows.
    public var id: String { magnet.infoHash.hex }

    /// The `dn` parameter, or a stand-in. A magnet without one is common from
    /// scrapers and is still perfectly downloadable, so it is not a refusal.
    public var displayName: String {
        guard let name = magnet.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return "Magnet link" }
        return name
    }

    /// Enough hash to recognise, not so much that it is a wall of hex.
    ///
    /// Sixteen characters: two torrents sharing a 16-hex prefix do not occur
    /// outside a deliberate attack, and the whole 40 in a 12pt mono face is
    /// wider than the row it has to sit in.
    public var shortHash: String {
        "btih:" + magnet.infoHash.hex.prefix(Self.shortHashLength) + "…"
    }

    public static let shortHashLength = 16

    public init(magnet: MagnetLink) {
        self.magnet = magnet
    }
}

public extension PastedLink {
    /// Whether this text is a magnet, decided without asking anything.
    ///
    /// **Separate from `resolve`.** `resolve` needs the configured providers and
    /// their host coverage, because deciding what a *hoster* link is takes both.
    /// A magnet needs neither, and the search field has to answer on every
    /// keystroke — so the cheap question is asked cheaply, and the field never
    /// waits on coverage to notice what it is holding.
    static func magnetOffer(from text: String) -> MagnetOffer? {
        MagnetLink(text).map(MagnetOffer.init(magnet:))
    }
}

public extension SearchResult {
    /// A magnet dropped or pasted, shaped as the thing every sheet already
    /// takes.
    ///
    /// **So there is one path into a download.** The picker sheet resolves
    /// availability, offers the file list, carries the Queued/Ready pill and the
    /// destination menu. A second flow for magnets that arrive by hand would
    /// have to grow all four again, and the two would drift — which is exactly
    /// what happened to the add-link sheet, whose availability answer and
    /// confirm rule were a second implementation of the picker's.
    ///
    /// The name is parsed for the same reason a Torznab title is: the
    /// organization rules route on `ReleaseMetadata`, so a magnet whose `dn` is
    /// a release name lands in the same folder the identical search result
    /// would.
    static func pastedMagnet(_ magnet: MagnetLink, source: SearchProviderID) -> SearchResult {
        let title = MagnetOffer(magnet: magnet).displayName
        return SearchResult(
            candidates: [.torrent(
                infoHash: magnet.infoHash, magnet: magnet, targetPath: nil)],
            title: title,
            // Unknown, and stated as unknown. A magnet declares no length; the
            // file list the sheet loads is where a size comes from, and a
            // fabricated 0 would render as "0 bytes" beside a 4 GB film.
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
