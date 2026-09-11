import Foundation
import FetchPluginAPI

/**
 Identity of a piece of content, independent of which release encodes it.

 Opaque on purpose: how the key is derived is this file's business, and
 nothing downstream should pattern-match on its shape.
 */
public struct ContentKey: Hashable, Sendable {
    let raw: String
}

/**
 One piece of content and every release of it (§8, Grouping).
 */
public struct ContentGroup: Identifiable, Sendable {
    public let key: ContentKey
    public let displayTitle: String
    public let year: Int?
    public let releases: [SearchResult]

    public var id: ContentKey { key }
    public var best: SearchResult? { releases.first }
    public var releaseCount: Int { releases.count }

    public var maxSeeders: Int { releases.compactMap(\.seeders).max() ?? 0 }

    public var infoHashes: [String] { releases.compactMap(\.infoHashHex) }
}

public enum ContentGrouping {
    /**
     Resolves content identity, trying the strongest signal first (§8):

     1. `imdbID`, or `tvdbID` + season + episode — authoritative, indexer-supplied
     2. normalized title + year + season + episodes
     3. the raw title, normalized

     External ids are never guessed, only read from indexer attributes, so
     reaching level 1 means an indexer asserted it.
     */
    public static func key(
        for metadata: ReleaseMetadata, fallbackTitle: String
    ) -> ContentKey {
        if let imdb = metadata.imdbID, !imdb.isEmpty {
            return ContentKey(raw: "imdb:\(imdb.lowercased())")
        }
        if let tvdb = metadata.tvdbID {
            return ContentKey(raw: "tvdb:\(tvdb):\(episodeSuffix(metadata))")
        }
        if let title = metadata.title, !normalize(title).isEmpty {
            let year = metadata.year.map(String.init) ?? "-"
            return ContentKey(raw: "t:\(normalize(title)):\(year):\(episodeSuffix(metadata))")
        }
        return ContentKey(raw: "raw:\(normalize(fallbackTitle))")
    }

    private static func episodeSuffix(_ metadata: ReleaseMetadata) -> String {
        let season = metadata.season.map(String.init) ?? "-"
        let episodes = metadata.episodes.isEmpty
            ? "-"
            : metadata.episodes.sorted().map(String.init).joined(separator: ",")
        return "\(season)/\(episodes)"
    }

    static func normalize(_ title: String) -> String {
        var text = title.lowercased()

        for separator in [".", "_", "-", ":", "/"] {
            text = text.replacingOccurrences(of: separator, with: " ")
        }
        text = text.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? String($0) : "" }
            .joined()

        var words = text.split(separator: " ").map(String.init)

        if words.count > 1, let last = words.last, articles.contains(last) {
            words.removeLast()
            words.insert(last, at: 0)
        }
        return words.joined(separator: " ")
    }

    private static let articles: Set<String> = ["the", "a", "an"]

    /**
     Collapses releases into groups, ordered by their strongest member so
     the most-seeded content leads — the flat list's one useful property.
     */
    public static func group(_ results: [SearchResult]) -> [ContentGroup] {
        var buckets: [ContentKey: [SearchResult]] = [:]
        var order: [ContentKey] = []

        for result in results {
            let key = key(for: result.metadata, fallbackTitle: result.title)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(result)
        }

        let groups = order.compactMap { key -> ContentGroup? in
            guard let members = buckets[key], let first = members.first else { return nil }
            return ContentGroup(
                key: key,
                displayTitle: displayTitle(for: members) ?? first.title,
                year: members.compactMap(\.metadata.year).first,
                releases: members.sorted(by: strongerFirst))
        }

        return groups.sorted { a, b in
            a.maxSeeders != b.maxSeeders
                ? a.maxSeeders > b.maxSeeders
                : a.key.raw < b.key.raw
        }
    }

    private static func displayTitle(for members: [SearchResult]) -> String? {
        members.compactMap { $0.metadata.title }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func strongerFirst(_ a: SearchResult, _ b: SearchResult) -> Bool {
        let aSeeders = a.seeders ?? -1
        let bSeeders = b.seeders ?? -1
        return aSeeders != bSeeders ? aSeeders > bSeeders : a.id.rawValue < b.id.rawValue
    }
}
