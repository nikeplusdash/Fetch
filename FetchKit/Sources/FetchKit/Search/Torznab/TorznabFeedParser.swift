import Foundation
import FetchPluginAPI

/// Parses a Torznab search response (RSS 2.0 + `torznab:attr` elements) into
/// `[SearchResult]`.
///
/// Parsing rules (§7):
/// - Attribute presence varies wildly by indexer. A missing `seeders` becomes
///   `0`, never a parse failure — one odd field must not drop an otherwise
///   good result.
/// - `infohash` may be absent; the hash is then derived from `magneturl`
///   (or, pragmatically, from `<link>` when an indexer puts the magnet there
///   directly). With no hash from any source, the item is dropped — without
///   an infohash it can't be cache-checked or deduplicated.
/// - An item whose only pointer is a `.torrent` URL in `<link>` comes out as
///   `Parsed.unresolved` rather than as nothing. It used to be dropped, which
///   silently lost every result from a login-gated tracker.
enum TorznabFeedParser {
    /// A parsed feed, including the items that could not become results on
    /// their own.
    ///
    /// **Some trackers publish no magnet at all.** Verified against a live
    /// Jackett: RuTracker returns `[TR24][OF][FM] Ramin Djawadi - 3 Body
    /// Problem (Soundtrack…)` with no `magneturl` attribute, no `infohash`
    /// attribute, and a `<link>` pointing at Jackett's own `/dl/rutracker/…`
    /// endpoint — because the tracker requires a login and only Jackett holds
    /// the cookie. There is nothing to key such an item on, so the parser had
    /// no choice but to drop it, and the result the user was actually looking
    /// for was missing from a search that found nine other things.
    ///
    /// It is not unresolvable, only not resolvable *here*: the `.torrent`
    /// behind that URL contains the infohash. Fetching it is a network call and
    /// this is a pure parser, so the item comes out as work for the caller
    /// rather than as a result or as nothing.
    struct Parsed {
        var results: [SearchResult]
        var unresolved: [UnresolvedItem]
    }

    /// An item whose only pointer is a `.torrent` URL.
    ///
    /// Everything the feed said is kept, so resolving it costs one fetch and
    /// nothing has to be parsed twice.
    struct UnresolvedItem: Sendable {
        let torrentURL: URL
        let title: String
        let size: Int64
        let seeders: Int
        let peers: Int
        let grabs: Int?
        let fileCount: Int?
        let category: TorznabCategory?
        let publishDate: Date?
        let providerID: SearchProviderID
        let rawAttributes: [String: String]

        /// The result this becomes once the `.torrent` has given up its hash.
        func resolved(with torrent: TorrentFile) -> SearchResult? {
            guard let magnet = torrent.magnet else { return nil }
            return SearchResult(
                infoHashHex: torrent.infoHash.hex,
                title: title,
                size: size,
                seeders: seeders,
                peers: peers,
                grabs: grabs,
                // The torrent itself is authoritative about its own file
                // count; the feed's attribute is whatever the tracker typed.
                fileCount: fileCount ?? torrent.files.count,
                category: category,
                publishDate: publishDate,
                magnetURI: magnet.raw,
                sources: [providerID],
                rawAttributes: rawAttributes)
        }
    }

    static func parse(
        _ data: Data,
        providerID: SearchProviderID,
        categoryNames: [Int: String] = [:]
    ) throws -> [SearchResult] {
        try parseFeed(data, providerID: providerID, categoryNames: categoryNames).results
    }

    static func parseFeed(
        _ data: Data,
        providerID: SearchProviderID,
        categoryNames: [Int: String] = [:]
    ) throws -> Parsed {
        let delegate = Delegate(providerID: providerID, categoryNames: categoryNames)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError.map(String.init(describing:)) ?? "unknown XML error"
            throw SearchError.malformedFeed(reason: reason)
        }
        // A rejected key answers a search with 200 and an `<error code="100">`
        // document, which parses cleanly into no items — so the indexer looked
        // like one that simply found nothing, on every query, forever. See
        // `TorznabErrorDocument`.
        if let error = delegate.errorDocument { throw error }
        return Parsed(results: delegate.results, unresolved: delegate.unresolved)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var results: [SearchResult] = []
        var unresolved: [UnresolvedItem] = []
        var errorDocument: SearchError?

        private let providerID: SearchProviderID
        private let categoryNames: [Int: String]

        private var insideItem = false
        private var currentText = ""

        private var title = ""
        private var link: String?
        private var pubDateRaw: String?
        private var sizeElementRaw: String?
        private var attrPairs: [(name: String, value: String)] = []

        init(providerID: SearchProviderID, categoryNames: [Int: String]) {
            self.providerID = providerID
            self.categoryNames = categoryNames
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            currentText = ""

            // Before the `insideItem` guard: the error document has no items
            // for it to be inside of.
            if elementName == "error", !insideItem {
                errorDocument = TorznabErrorDocument.error(from: attributes)
                return
            }

            if elementName == "item" {
                insideItem = true
                title = ""
                link = nil
                pubDateRaw = nil
                sizeElementRaw = nil
                attrPairs = []
                return
            }
            guard insideItem else { return }

            // Namespace-agnostic: match on suffix so a "newznab:attr" or any
            // other prefix an indexer's XML declares is still recognized,
            // without configuring XMLParser's (heavier) namespace handling.
            if elementName.hasSuffix(":attr"), let name = attributes["name"] {
                attrPairs.append((name: name, value: attributes["value"] ?? ""))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            defer { currentText = "" }
            guard insideItem else { return }

            switch elementName {
            case "item":
                insideItem = false
                switch makeResult() {
                case .result(let result): results.append(result)
                case .needsTorrentFile(let item): unresolved.append(item)
                case .unusable: break
                }
            case "title":
                title = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "link":
                link = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "pubDate":
                pubDateRaw = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "size":
                sizeElementRaw = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                break
            }
        }

        enum Outcome {
            case result(SearchResult)
            /// Has a `.torrent` URL and nothing else to key on.
            case needsTorrentFile(UnresolvedItem)
            /// No hash and no `.torrent` either — genuinely nothing to act on.
            case unusable
        }

        private func makeResult() -> Outcome {
            // Duplicate attr names (e.g. a release filed under two
            // categories) are joined rather than overwritten, so nothing is
            // silently lost from rawAttributes.
            var multi: [String: [String]] = [:]
            for pair in attrPairs { multi[pair.name, default: []].append(pair.value) }
            var rawAttributes: [String: String] = [:]
            for (key, values) in multi { rawAttributes[key] = values.joined(separator: ",") }

            func first(_ key: String) -> String? { multi[key]?.first }

            let seeders = first("seeders").flatMap(Int.init) ?? 0
            let peers = first("peers").flatMap(Int.init) ?? first("leechers").flatMap(Int.init) ?? 0
            let grabs = first("grabs").flatMap(Int.init)
            let fileCount = first("files").flatMap(Int.init)

            let size = first("size").flatMap(Int64.init) ?? sizeElementRaw.flatMap(Int64.init) ?? 0

            let category = first("category").flatMap(Int.init).map { id in
                TorznabCategory(id: id, name: categoryNames[id] ?? "Category \(id)")
            }

            let hashAttr = first("infohash").flatMap(InfoHash.init)
            let magnetFromAttr = first("magneturl").flatMap(MagnetLink.init)
            let magnetFromLink: MagnetLink? = link.flatMap {
                $0.lowercased().hasPrefix("magnet:") ? MagnetLink($0) : nil
            }
            let candidateMagnet = magnetFromAttr ?? magnetFromLink

            guard let hash = hashAttr ?? candidateMagnet?.infoHash else {
                // No infohash attribute and no parseable magnet — the item's
                // only pointer is a `.torrent` URL, which is how a tracker that
                // needs a login publishes. It cannot be keyed, cache-checked or
                // deduplicated as it stands, but the file behind that URL
                // contains the hash, so it becomes work rather than nothing.
                guard let raw = link ?? first("guid"),
                      let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http"
                else { return .unusable }
                return .needsTorrentFile(UnresolvedItem(
                    torrentURL: url,
                    title: title,
                    size: size,
                    seeders: seeders,
                    peers: peers,
                    grabs: grabs,
                    fileCount: fileCount,
                    category: category,
                    publishDate: pubDateRaw.flatMap(Self.parseRFC822Date),
                    providerID: providerID,
                    rawAttributes: rawAttributes))
            }

            let magnet: MagnetLink
            if let candidateMagnet, candidateMagnet.infoHash == hash {
                magnet = candidateMagnet   // keeps the indexer's own trackers/dn
            } else {
                magnet = Self.synthesizeMagnet(hash: hash, title: title)
            }

            return .result(SearchResult(
                infoHashHex: hash.hex,
                title: title,
                size: size,
                seeders: seeders,
                peers: peers,
                grabs: grabs,
                fileCount: fileCount,
                category: category,
                publishDate: pubDateRaw.flatMap(Self.parseRFC822Date),
                magnetURI: magnet.raw,
                sources: [providerID],
                rawAttributes: rawAttributes
            ))
        }

        /// RFC 3986 "unreserved" characters only — deliberately stricter than
        /// `.urlQueryAllowed`, which leaves `&`/`=`/`+` unescaped and would
        /// corrupt a synthesized magnet's query string if the title contains
        /// one of them.
        private static let magnetDisplayNameAllowed: CharacterSet = {
            var set = CharacterSet.alphanumerics
            set.insert(charactersIn: "-._~")
            return set
        }()

        /// Some indexers supply `infohash` but no magnet anywhere (no
        /// `magneturl` attr, and `<link>` is a `.torrent` URL or absent).
        /// `SearchResult.magnetURI` is not optional, so a minimal magnet is
        /// built from the hash — this is exactly what a magnet URI *is*, a
        /// wrapper around the infohash plus optional display name/trackers.
        private static func synthesizeMagnet(hash: InfoHash, title: String) -> MagnetLink {
            var raw = "magnet:?xt=urn:btih:\(hash.hex)"
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                let encoded = trimmedTitle.addingPercentEncoding(
                    withAllowedCharacters: magnetDisplayNameAllowed
                ) ?? trimmedTitle
                raw += "&dn=\(encoded)"
            }
            // Safe to force-unwrap: hash.hex is always valid 40-char hex, so
            // this string always satisfies MagnetLink's own parsing rules.
            return MagnetLink(raw)!
        }

        private static func parseRFC822Date(_ raw: String) -> Date? {
            for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                if let date = formatter.date(from: raw) { return date }
            }
            return nil
        }
    }
}
