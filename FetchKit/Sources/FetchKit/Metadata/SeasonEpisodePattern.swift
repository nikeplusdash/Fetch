import Foundation

struct SeasonEpisodeMatch {
    let range: Range<String.Index>
    var season: Int?
    var episodes: [Int] = []
    var absoluteEpisode: Int?
    var isSeasonPack: Bool = false
}

enum SeasonEpisodePattern {
    private static let list = try! NSRegularExpression(
        pattern: #"\bS(\d{1,2})((?:[ ]?E\d{1,3}){2,})\b"#, options: [.caseInsensitive]
    )
    private static let listMember = try! NSRegularExpression(
        pattern: #"E(\d{1,3})"#, options: [.caseInsensitive]
    )
    private static let range = try! NSRegularExpression(
        pattern: #"\bS(\d{1,2})[ ]?E(\d{1,3})[\s-]+E?(\d{1,3})\b"#, options: [.caseInsensitive]
    )
    private static let single = try! NSRegularExpression(
        pattern: #"\bS(\d{1,2})[ ]?E(\d{1,3})\b"#, options: [.caseInsensitive]
    )
    private static let altXY = try! NSRegularExpression(
        pattern: #"\b(\d{1,2})x(\d{1,3})\b"#, options: [.caseInsensitive]
    )
    private static let seasonWord = try! NSRegularExpression(
        pattern: #"\bSeason[\s.]?(\d{1,2})\b"#, options: [.caseInsensitive]
    )
    private static let bareSeason = try! NSRegularExpression(
        pattern: #"\bS(\d{1,2})\b"#, options: [.caseInsensitive]
    )
    private static let animeDash = try! NSRegularExpression(
        pattern: #"[\s]-[\s](\d{1,4})(?=[\s(\[]|$)"#, options: []
    )
    private static let animeBracket = try! NSRegularExpression(
        pattern: #"\[(\d{1,3})\]"#, options: []
    )

    static func firstMatch(in text: String, allowAnimeNumbering: Bool) -> SeasonEpisodeMatch? {
        let full = NSRange(text.startIndex..., in: text)

        if let m = list.firstMatch(in: text, range: full),
           let whole = Range(m.range, in: text),
           let seasonRange = Range(m.range(at: 1), in: text),
           let season = Int(text[seasonRange]) {
            var episodes: [Int] = []
            listMember.enumerateMatches(in: text, range: m.range(at: 2)) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text), let e = Int(text[r]) else { return }
                episodes.append(e)
            }
            return SeasonEpisodeMatch(range: whole, season: season, episodes: episodes)
        }

        if let m = range.firstMatch(in: text, range: full),
           let whole = Range(m.range, in: text),
           let seasonRange = Range(m.range(at: 1), in: text), let season = Int(text[seasonRange]),
           let startRange = Range(m.range(at: 2), in: text), let start = Int(text[startRange]),
           let endRange = Range(m.range(at: 3), in: text), let end = Int(text[endRange]),
           start <= end {
            return SeasonEpisodeMatch(range: whole, season: season, episodes: Array(start...end))
        }

        if let m = single.firstMatch(in: text, range: full),
           let whole = Range(m.range, in: text),
           let seasonRange = Range(m.range(at: 1), in: text), let season = Int(text[seasonRange]),
           let episodeRange = Range(m.range(at: 2), in: text), let episode = Int(text[episodeRange]) {
            return SeasonEpisodeMatch(range: whole, season: season, episodes: [episode])
        }

        if let m = altXY.firstMatch(in: text, range: full),
           let whole = Range(m.range, in: text),
           let seasonRange = Range(m.range(at: 1), in: text), let season = Int(text[seasonRange]),
           let episodeRange = Range(m.range(at: 2), in: text), let episode = Int(text[episodeRange]) {
            return SeasonEpisodeMatch(range: whole, season: season, episodes: [episode])
        }

        if let m = seasonWord.firstMatch(in: text, range: full),
           let whole = Range(m.range, in: text),
           let seasonRange = Range(m.range(at: 1), in: text), let season = Int(text[seasonRange]) {
            return SeasonEpisodeMatch(range: whole, season: season, isSeasonPack: true)
        }

        if let m = bareSeason.firstMatch(in: text, range: full),
           let whole = Range(m.range, in: text),
           let seasonRange = Range(m.range(at: 1), in: text), let season = Int(text[seasonRange]) {
            return SeasonEpisodeMatch(range: whole, season: season, isSeasonPack: true)
        }

        guard allowAnimeNumbering else { return nil }

        if let m = animeDash.firstMatch(in: text, range: full),
           let whole = Range(m.range, in: text),
           let numRange = Range(m.range(at: 1), in: text), let number = Int(text[numRange]) {
            return SeasonEpisodeMatch(range: whole, absoluteEpisode: number)
        }

        if let m = animeBracket.firstMatch(in: text, range: full),
           let whole = Range(m.range, in: text),
           let numRange = Range(m.range(at: 1), in: text), let number = Int(text[numRange]) {
            return SeasonEpisodeMatch(range: whole, absoluteEpisode: number)
        }

        return nil
    }
}
