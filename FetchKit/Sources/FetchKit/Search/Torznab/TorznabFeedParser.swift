import Foundation
import FetchPluginAPI

enum TorznabFeedParser {
    struct Parsed {
        var results: [SearchResult]
        var unresolved: [UnresolvedItem]
    }

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

        func resolved(with torrent: TorrentFile) -> SearchResult? {
            guard let magnet = torrent.magnet else { return nil }
            return SearchResult(
                infoHashHex: torrent.infoHash.hex,
                title: title,
                size: size,
                seeders: seeders,
                peers: peers,
                grabs: grabs,
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
            case needsTorrentFile(UnresolvedItem)
            case unusable
        }

        private func makeResult() -> Outcome {
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
                magnet = candidateMagnet
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

        private static let magnetDisplayNameAllowed: CharacterSet = {
            var set = CharacterSet.alphanumerics
            set.insert(charactersIn: "-._~")
            return set
        }()

        private static func synthesizeMagnet(hash: InfoHash, title: String) -> MagnetLink {
            var raw = "magnet:?xt=urn:btih:\(hash.hex)"
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                let encoded = trimmedTitle.addingPercentEncoding(
                    withAllowedCharacters: magnetDisplayNameAllowed
                ) ?? trimmedTitle
                raw += "&dn=\(encoded)"
            }
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
