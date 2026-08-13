import Foundation
import FetchPluginAPI

/// The page a result came from, for opening in a browser.
///
/// **Not the file's URL.** A direct candidate points at the bytes — an `.epub`,
/// an `.mp4` — so opening it downloads the file a second time in Safari, which
/// is the one thing a "browse" action must not do. What is wanted is the item:
/// the Archive.org details page with its description, reviews and the rest of
/// its files; the Gutendex book page with its other formats and its metadata.
///
/// Both providers already carry the identifier that names it. `sourceKey` is
/// provider-namespaced precisely so it can be read back like this.
public enum SourcePage {
    public static func url(for result: SearchResult) -> URL? {
        if let key = result.sourceKey, let page = url(forSourceKey: key) { return page }

        // A torrent has no page of its own — its "source" is an indexer, and
        // the indexer's own listing is not something `SearchResult` carries.
        // Better nothing than a guess at a tracker's URL scheme.
        return nil
    }

    static func url(forSourceKey key: String) -> URL? {
        guard let separator = key.firstIndex(of: ":") else { return nil }
        let provider = String(key[key.startIndex..<separator])
        let identifier = String(key[key.index(after: separator)...])
        guard !identifier.isEmpty else { return nil }

        // Percent-encoded: Archive.org identifiers are conservative, but they
        // are user-supplied upstream and an unescaped one would silently build
        // a URL pointing somewhere else.
        guard let escaped = identifier.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) else { return nil }

        return switch provider {
        case "internet-archive": URL(string: "https://archive.org/details/\(escaped)")
        case "gutenberg": URL(string: "https://www.gutenberg.org/ebooks/\(escaped)")
        default: nil
        }
    }
}
