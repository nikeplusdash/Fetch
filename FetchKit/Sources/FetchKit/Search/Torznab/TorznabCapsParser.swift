import Foundation
import FetchPluginAPI

enum TorznabCapsParser {
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
        if let error = delegate.errorDocument { throw error }

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
        var errorDocument: SearchError?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            switch elementName {
            case "error":
                errorDocument = TorznabErrorDocument.error(from: attributes)

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
