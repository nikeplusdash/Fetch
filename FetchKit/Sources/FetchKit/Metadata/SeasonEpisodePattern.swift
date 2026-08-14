import Foundation

/// The result of matching one season/episode convention against a release
/// name, plus the matched range so `ReleaseNameParser` can use its start
/// position as a title boundary (§8 step 5).
struct SeasonEpisodeMatch {
    let range: Range<String.Index>
    var season: Int?
    var episodes: [Int] = []
    var absoluteEpisode: Int?
    var isSeasonPack: Bool = false
}

/// Season/episode extraction, tried in the precedence order §8 specifies:
/// `S01E02E03` (list) before `S01E02-E05` (range) before `S01E02` (single)
/// before `1x02` before `Season 1` before bare `S01` (pack) before anime
/// ` - 12 ` before anime `[12]`. Earlier patterns are strictly more
/// specific than later ones, so trying them in this order — and stopping
/// at the first match — is what keeps `S01E02E03` from being read as a
/// bare `S01` pack, and `S01E01-E03` (range) from being read as two
/// unrelated single-episode mentions.
///
/// Runs on text where `.`/`_` have already become spaces but hyphens have
/// **not** yet been normalized — the range form's hyphen (`S01E02-E05`) is
/// the only thing that distinguishes it from the list form
/// (`S01E02E03`, no separator at all), so it must still be intact here.
/// Callers normalize remaining hyphens themselves once this returns.
enum SeasonEpisodePattern {
    // "S01E02E03", "S01E02E03E04", ... (2+ E-groups: a list)
    private static let list = try! NSRegularExpression(
        pattern: #"\bS(\d{1,2})((?:[ ]?E\d{1,3}){2,})\b"#, options: [.caseInsensitive]
    )
    private static let listMember = try! NSRegularExpression(
        pattern: #"E(\d{1,3})"#, options: [.caseInsensitive]
    )
    // "S01E02-E05" or "S01E02-05" (a range)
    private static let range = try! NSRegularExpression(
        pattern: #"\bS(\d{1,2})[ ]?E(\d{1,3})[\s-]+E?(\d{1,3})\b"#, options: [.caseInsensitive]
    )
    // "S01E02"
    private static let single = try! NSRegularExpression(
        pattern: #"\bS(\d{1,2})[ ]?E(\d{1,3})\b"#, options: [.caseInsensitive]
    )
    // "1x02"
    private static let altXY = try! NSRegularExpression(
        pattern: #"\b(\d{1,2})x(\d{1,3})\b"#, options: [.caseInsensitive]
    )
    // "Season 1", "Season 01"
    private static let seasonWord = try! NSRegularExpression(
        pattern: #"\bSeason[\s.]?(\d{1,2})\b"#, options: [.caseInsensitive]
    )
    // bare "S01" (season pack, not followed by an episode marker)
    private static let bareSeason = try! NSRegularExpression(
        pattern: #"\bS(\d{1,2})\b"#, options: [.caseInsensitive]
    )
    // anime " - 12 " absolute numbering. 4 digits, not 3, because
    // long-running shows (One Piece is past 1000 episodes) use absolute
    // numbering too.
    private static let animeDash = try! NSRegularExpression(
        pattern: #"[\s]-[\s](\d{1,4})(?=[\s(\[]|$)"#, options: []
    )
    // anime "[12]" absolute numbering
    private static let animeBracket = try! NSRegularExpression(
        pattern: #"\[(\d{1,3})\]"#, options: []
    )

    /// `allowAnimeNumbering` gates the two anime patterns behind having
    /// seen a leading `[Group]` tag (§8 calls that convention "an anime
    /// group tag"). Without this, " - 12 " collides with the extremely
    /// common "Artist - <bare number>" music-album convention — e.g.
    /// Adele's albums are literally titled "19", "21", "25". A bracketed
    /// fansub group tag is the actual, reliable anime signal; a plain
    /// "Show - 12" with no group tag is not a real anime release-naming
    /// convention, so refusing to treat it as absolute numbering when
    /// there's no group tag costs nothing on real anime names.
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
