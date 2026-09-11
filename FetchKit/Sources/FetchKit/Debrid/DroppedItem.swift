import Foundation
import FetchPluginAPI

/**
 What a drop on the window is, decided before anything opens.

 **Refused at the drop, not after.** A file that is not a torrent must never
 light the overlay, because an overlay that accepts everything and then opens
 an empty sheet teaches you to distrust the highlight. The rule lived in
 `DownloadsView`'s drop handler, where it was reachable on exactly one screen
 and testable on none.

 **Nothing here contacts a peer.** Classification is a look at a URL; parsing
 the `.torrent` is `TorrentFile`, which is local bencode and a SHA-1. Only the
 infohash leaves the machine, over HTTPS, to the configured debrid services.
 */
public enum DroppedItem: Equatable, Sendable {
    case torrentFile(URL)
    case magnet(String)
    case webLink(URL)

    /**
     The first thing in the drop that Fetch can act on, or nil.

     **First, not all of them.** Dragging three things and getting one
     download is confusing after the fact and obvious before it, which is why
     the overlay names the file it is about to take.
     */
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

    public var isDirectlyDownloadable: Bool {
        switch self {
        case .torrentFile, .magnet: true
        case .webLink: false
        }
    }

    public var displayName: String {
        switch self {
        case .torrentFile(let url): url.lastPathComponent
        case .magnet(let raw): MagnetLink(raw)?.displayName ?? "Magnet link"
        case .webLink(let url): url.host() ?? url.absoluteString
        }
    }
}
