import Foundation

/// Derives `season`/`episode` from a free-text search query, e.g.
/// `"The Expanse S03E05"` → `(title: "The Expanse", season: 3, episode: 5)`.
///
/// This is deliberately tiny — it recognizes exactly the two conventions a
/// user is likely to type (`S03E05`, `3x05`) and nothing else: no ranges, no
/// season packs, no anime absolute numbering. It exists so `TorznabProvider`
/// can pick `t=tvsearch` over free-text `t=search` (§7) without depending on
/// `ReleaseNameParser`, which is M3 scope and parses complete release names
/// against a corpus-tested token table, not search-box text.
///
/// `public`: the search UI's "structured query feedback" (design spec
/// §12.1 — showing a removable `S03E05` token once the query parses)
/// reuses this exact extraction rather than re-implementing the two
/// regexes at the view layer, so the token shown always agrees with what
/// `TorznabProvider.search` actually sent.
public enum SeasonEpisodeQueryParser {
    public struct Extraction: Sendable, Equatable {
        public let title: String
        public let season: Int?
        public let episode: Int?
    }

    private static let patterns: [NSRegularExpression] = [
        // "S03E05", "s3e5"
        try! NSRegularExpression(pattern: #"\bS(\d{1,2})E(\d{1,3})\b"#, options: [.caseInsensitive]),
        // "3x05"
        try! NSRegularExpression(pattern: #"\b(\d{1,2})x(\d{1,3})\b"#, options: [.caseInsensitive]),
    ]

    public static func extract(from text: String) -> Extraction {
        let full = NSRange(text.startIndex..., in: text)

        for pattern in patterns {
            guard let match = pattern.firstMatch(in: text, range: full),
                  match.numberOfRanges == 3,
                  let seasonRange = Range(match.range(at: 1), in: text),
                  let episodeRange = Range(match.range(at: 2), in: text),
                  let season = Int(text[seasonRange]),
                  let episode = Int(text[episodeRange]),
                  let wholeRange = Range(match.range, in: text)
            else { continue }

            var remainder = text
            remainder.removeSubrange(wholeRange)
            let title = remainder
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            return Extraction(title: title, season: season, episode: episode)
        }

        return Extraction(title: text, season: nil, episode: nil)
    }
}
