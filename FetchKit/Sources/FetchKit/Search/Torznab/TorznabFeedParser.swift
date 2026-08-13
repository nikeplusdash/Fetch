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
/// - An item whose only pointer is a `.torrent` URL in `<link>` is dropped:
///   v1 does not fetch and parse bencode.
enum TorznabFeedParser {
    static func parse(
        _ data: Data,
        providerID: SearchProviderID,
        categoryNames: [Int: String] = [:]
    ) throws -> [SearchResult] {
        let delegate = Delegate(providerID: providerID, categoryNames: categoryNames)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError.map(String.init(describing:)) ?? "unknown XML error"
            throw SearchError.malformedFeed(reason: reason)
        }
        return delegate.results
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var results: [SearchResult] = []

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
                if let result = makeResult() { results.append(result) }
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

        private func makeResult() -> SearchResult? {
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
                // No infohash attr, no parseable magnet anywhere (attr or
                // link) — e.g. the item's only pointer is a `.torrent` URL.
                // Drop: it can't be cache-checked or deduplicated (§7).
                return nil
            }

            let magnet: MagnetLink
            if let candidateMagnet, candidateMagnet.infoHash == hash {
                magnet = candidateMagnet   // keeps the indexer's own trackers/dn
            } else {
                magnet = Self.synthesizeMagnet(hash: hash, title: title)
            }

            return SearchResult(
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
            )
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
