import Foundation
import FetchPluginAPI

/// What a drop on the window is, decided before anything opens.
///
/// **Refused at the drop, not after.** A file that is not a torrent must never
/// light the overlay, because an overlay that accepts everything and then opens
/// an empty sheet teaches you to distrust the highlight. The rule lived in
/// `DownloadsView`'s drop handler, where it was reachable on exactly one screen
/// and testable on none.
///
/// **Nothing here contacts a peer.** Classification is a look at a URL; parsing
/// the `.torrent` is `TorrentFile`, which is local bencode and a SHA-1. Only the
/// infohash leaves the machine, over HTTPS, to the configured debrid services.
public enum DroppedItem: Equatable, Sendable {
    /// A `.torrent` on disk, to be parsed locally.
    case torrentFile(URL)
    /// A dragged magnet link. Dragged text and dragged files both arrive as
    /// `URL`, so the scheme is what tells them apart.
    case magnet(String)
    /// An http(s) address. **Not necessarily usable**, and taken anyway: the
    /// alternative is refusing it in silence, which is what three rounds of
    /// "drag and drop does not work" turned out to be. A link to a torrent file
    /// is fetched; anything else goes to Add Link, which is the one screen that
    /// can say whether a debrid covers the host. Pasting the same URL has
    /// always done this — dropping it did nothing.
    case webLink(URL)

    /// The first thing in the drop that Fetch can act on, or nil.
    ///
    /// **First, not all of them.** Dragging three things and getting one
    /// download is confusing after the fact and obvious before it, which is why
    /// the overlay names the file it is about to take.
    public static func first(in urls: [URL]) -> DroppedItem? {
        for url in urls {
            if url.isFileURL {
                guard url.pathExtension.lowercased() == "torrent" else { continue }
                return .torrentFile(url)
            }
            switch url.scheme?.lowercased() {
            case "magnet": return .magnet(url.absoluteString)
            case "http", "https": return .webLink(url)
            default: continue
            }
        }
        return nil
    }

    /// What the overlay says it will do, which is not the same for all three.
    ///
    /// A torrent and a magnet are downloads. A web link is a question, and
    /// saying "drop to download" over one would promise an answer Fetch does
    /// not have until Add Link has looked at it.
    public var isDirectlyDownloadable: Bool {
        switch self {
        case .torrentFile, .magnet: true
        case .webLink: false
        }
    }

    /// What the overlay calls it while it is being dragged.
    public var displayName: String {
        switch self {
        case .torrentFile(let url): url.lastPathComponent
        case .magnet(let raw): MagnetLink(raw)?.displayName ?? "Magnet link"
        case .webLink(let url): url.host() ?? url.absoluteString
        }
    }
}
