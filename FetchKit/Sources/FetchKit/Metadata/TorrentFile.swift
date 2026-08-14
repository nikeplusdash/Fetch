import Foundation
import FetchPluginAPI

/// A `.torrent` read from the user's own disk.
///
/// **Reading one is not P2P.** No peer is contacted and no announce is made —
/// this parses a local file. The magnet it yields goes to a debrid exactly as
/// a pasted one does, and any swarm work is the debrid's. That is the same
/// posture `TorrentMetadataFetcher` takes for its HTTPS fetches, and the
/// reason both exist rather than BEP 9 over DHT.
///
/// Composed from what is already here — `Bencode`, `InfoHash`,
/// `TorrentMetadata` — rather than parsing anything itself.
public struct TorrentFile: Sendable, Equatable {
    public let infoHash: InfoHash
    public let name: String
    public let files: [TorrentMetadata.File]
    /// Trackers from `announce` / `announce-list`, in order, deduplicated.
    public let trackers: [String]

    /// Reads a `.torrent`'s bytes.
    ///
    /// **No `expectedInfoHash`.** `TorrentMetadata.parse` takes one because
    /// bytes from a third party may be a decoy — itorrents.org serves a
    /// byte-identical fake for any hash it does not hold, confirmed live
    /// against three hashes. A file the user picked from their own disk *is*
    /// the source of truth: there is nothing to verify it against, and
    /// inventing an expectation would be theatre.
    public static func parse(_ data: Data) -> TorrentFile? {
        guard let range = Bencode.infoDictionaryRange(in: data),
              let infoHash = InfoHash(InfoHash.sha1Hex(data[range])),
              let metadata = TorrentMetadata.parse(data)
        else { return nil }

        return TorrentFile(
            infoHash: infoHash,
            name: metadata.name,
            files: metadata.files,
            trackers: Self.trackers(in: data))
    }

    /// A magnet the debrid can take.
    ///
    /// Optional because `MagnetLink` validates what it is handed, and a caller
    /// that gets a `TorrentFile` should not have to assume the round trip
    /// through a string succeeded.
    public var magnet: MagnetLink? {
        var components = URLComponents()
        components.scheme = "magnet"
        var items = [
            URLQueryItem(name: "xt", value: "urn:btih:\(infoHash.hex)"),
            URLQueryItem(name: "dn", value: name),
        ]
        items.append(contentsOf: trackers.map { URLQueryItem(name: "tr", value: $0) })
        components.queryItems = items

        // `URLComponents` percent-encodes the `xt` colons, which some parsers
        // dislike; the infohash form is fixed and safe to restore.
        let raw = (components.string ?? "").replacingOccurrences(
            of: "xt=urn%3Abtih%3A", with: "xt=urn:btih:")
        return MagnetLink(raw)
    }

    /// Total size of everything in the torrent.
    public var totalLength: Int64 { files.reduce(0) { $0 + $1.length } }

    private static func trackers(in data: Data) -> [String] {
        guard let root = Bencode.parse(data)?.dictionary else { return [] }

        var found: [String] = []
        var seen: Set<String> = []
        func add(_ url: String?) {
            guard let url, !url.isEmpty, seen.insert(url).inserted else { return }
            found.append(url)
        }

        add(root["announce"]?.string)
        // `announce-list` is a list of tiers, each a list of URLs.
        for tier in root["announce-list"]?.list ?? [] {
            for entry in tier.list ?? [] { add(entry.string) }
        }
        return found
    }
}
