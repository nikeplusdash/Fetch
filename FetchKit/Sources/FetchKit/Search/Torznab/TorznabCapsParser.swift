import Foundation
import FetchPluginAPI

/// Parses a Torznab `t=caps` response into `ProviderCapabilities`.
///
/// `<caps>` is mandatory in the Torznab spec, so this is safe to depend on
/// for mode gating (§7): an indexer that does not advertise `tvsearch` gets
/// the free-text fallback instead of structured parameters it will ignore or
/// reject.
enum TorznabCapsParser {
    /// Element names that advertise a search mode, mapped to the
    /// `SearchModeKind` they gate. Some indexer software emits `audio-search`
    /// instead of the spec's `music-search`; both are accepted.
    private static let modeElements: [String: SearchModeKind] = [
        "search": .search,
        "tv-search": .tvsearch,
        "movie-search": .movie,
        "music-search": .music,
        "audio-search": .music,
        "book-search": .book,
    ]

    static func parse(_ data: Data) throws -> ProviderCapabilities {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError.map(String.init(describing:)) ?? "unknown XML error"
            throw SearchError.malformedFeed(reason: reason)
        }

        return ProviderCapabilities(
            categories: delegate.categories,
            supportedModes: delegate.supportedModes,
            supportedAttributes: delegate.supportedAttributes,
            maxLimit: delegate.maxLimit
        )
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var categories: [TorznabCategory] = []
        var supportedModes: Set<SearchModeKind> = []
        var supportedAttributes: Set<String> = []
        var maxLimit: Int?

        // `<category>` elements can nest `<subcat>` children; track the
        // enclosing category name only for logging/debugging — subcats are
        // flattened into `categories` as independent, filterable entries.
        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            switch elementName {
            case "limits":
                if let max = attributes["max"], let value = Int(max) {
                    maxLimit = value
                }

            case "category", "subcat":
                if let idString = attributes["id"], let id = Int(idString),
                   let name = attributes["name"] {
                    categories.append(TorznabCategory(id: id, name: name))
                }

            default:
                guard let kind = TorznabCapsParser.modeElements[elementName] else { return }
                if (attributes["available"] ?? "no").lowercased() == "yes" {
                    supportedModes.insert(kind)
                }
                let params = attributes["supportedParams"] ?? ""
                for param in params.split(separator: ",") {
                    let trimmed = param.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { supportedAttributes.insert(trimmed) }
                }
            }
        }
    }
}
