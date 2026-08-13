import Foundation
import FetchPluginAPI

/// One recognized value plus every release-name spelling for it. Token
/// tables are **data**, not `switch` statements (§8) — this is what makes
/// `releaseParser` a Tier-1 declarative plugin later (§3): contributing a
/// new release-group alias or source spelling is adding a row, not writing
/// code. `ReleaseNameParser` never special-cases a specific alias string;
/// it only ever calls `QualityMatcher.find` against one of these tables.
struct QualityTokenEntry<Value: Sendable>: Sendable {
    let value: Value
    let regex: NSRegularExpression

    /// Aliases are matched whole-word (`\b`), except at an edge that isn't
    /// itself a word character (e.g. the `+` in `"DDP+"`), where requiring
    /// a boundary there would wrongly reject the alias at end-of-string or
    /// before punctuation — `\b` is only meaningful between a word and a
    /// non-word character, and `+`-then-space is non-word-to-non-word.
    init(_ value: Value, aliases: [String]) {
        self.value = value
        // Longest-first: within one entry, a multi-word phrase like
        // "DTS HD MA" must be offered to the regex engine before a shorter
        // alias that is also a prefix of it, or alternation (which tries
        // branches in listed order, not longest-match) would settle for
        // the short one.
        let sorted = aliases.sorted { $0.count > $1.count }
        let branches = sorted.map { alias -> String in
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            let leadingIsWord = alias.first.map { $0.isLetter || $0.isNumber } ?? true
            let trailingIsWord = alias.last.map { $0.isLetter || $0.isNumber } ?? true
            return (leadingIsWord ? #"\b"# : "") + escaped + (trailingIsWord ? #"\b"# : "")
        }
        let pattern = "(?:" + branches.joined(separator: "|") + ")"
        // swiftlint:disable:next force_try — pattern is built from escaped
        // literals only, so it is always syntactically valid.
        self.regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

/// Finds, across every entry in a table, the leftmost alias match in
/// `text` — ties (two entries' aliases both start at the same index) are
/// broken in favor of the longer match, since that is always the more
/// specific one (e.g. "DTS HD MA" over "DTS").
enum QualityMatcher {
    static func find<Value>(
        _ table: [QualityTokenEntry<Value>], in text: String
    ) -> (range: Range<String.Index>, value: Value)? {
        let full = NSRange(text.startIndex..., in: text)
        var best: (range: Range<String.Index>, value: Value)?

        for entry in table {
            guard let match = entry.regex.firstMatch(in: text, range: full),
                  let range = Range(match.range, in: text)
            else { continue }

            if let current = best {
                if range.lowerBound < current.range.lowerBound {
                    best = (range, entry.value)
                } else if range.lowerBound == current.range.lowerBound,
                          text.distance(from: range.lowerBound, to: range.upperBound)
                            > text.distance(from: current.range.lowerBound, to: current.range.upperBound) {
                    best = (range, entry.value)
                }
            } else {
                best = (range, entry.value)
            }
        }
        return best
    }

    /// All non-overlapping category matches (used for `languages`, where
    /// more than one token can legitimately be present at once, e.g.
    /// "MULTI FRENCH").
    static func findAll<Value>(
        _ table: [QualityTokenEntry<Value>], in text: String
    ) -> [(range: Range<String.Index>, value: Value)] {
        let full = NSRange(text.startIndex..., in: text)
        var results: [(range: Range<String.Index>, value: Value)] = []
        for entry in table {
            entry.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match, let range = Range(match.range, in: text) else { return }
                results.append((range, entry.value))
            }
        }
        return results.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

enum TokenTables {
    // MARK: Resolution
    static let resolution: [QualityTokenEntry<Resolution>] = [
        QualityTokenEntry(.r2160p, aliases: ["2160p", "2160i", "4K", "UHD"]),
        QualityTokenEntry(.r1080p, aliases: ["1080p", "1080i", "FHD"]),
        QualityTokenEntry(.r720p, aliases: ["720p", "720i"]),
        QualityTokenEntry(.r576p, aliases: ["576p", "576i"]),
        QualityTokenEntry(.r480p, aliases: ["480p", "480i"]),
    ]

    // MARK: Source
    static let source: [QualityTokenEntry<ReleaseSource>] = [
        QualityTokenEntry(.remux, aliases: ["REMUX"]),
        QualityTokenEntry(.bluray, aliases: ["BluRay", "Blu Ray", "BDRip", "BRRip", "BD Rip", "BDRemux"]),
        QualityTokenEntry(.webdl, aliases: ["WEB DL", "WEBDL", "WEB"]),
        QualityTokenEntry(.webrip, aliases: ["WEBRip", "WEB Rip"]),
        QualityTokenEntry(.hdtv, aliases: ["HDTV", "PDTV", "DSR"]),
        QualityTokenEntry(.dvd, aliases: ["DVDRip", "DVD Rip", "DVDR", "DVD"]),
        QualityTokenEntry(.screener, aliases: ["DVDSCR", "BDSCR", "SCREENER", "SCR"]),
        QualityTokenEntry(.cam, aliases: ["CAMRip", "HDCAM", "CAM", "TELESYNC", "TELECINE", "TS", "TC"]),
    ]

    // MARK: Video codec
    static let videoCodec: [QualityTokenEntry<VideoCodec>] = [
        QualityTokenEntry(.hevc, aliases: ["HEVC", "x265", "H265", "H 265"]),
        QualityTokenEntry(.avc, aliases: ["AVC", "x264", "H264", "H 264"]),
        QualityTokenEntry(.av1, aliases: ["AV1"]),
        QualityTokenEntry(.xvid, aliases: ["XviD"]),
        QualityTokenEntry(.vp9, aliases: ["VP9"]),
    ]

    // MARK: Audio codec
    // Order matters conceptually (not mechanically — `QualityMatcher.find`'s
    // longest-match tie-break handles it) — DTS HD MA must not be swallowed
    // by the bare DTS entry, EAC3 must not be swallowed by AC3.
    static let audioCodec: [QualityTokenEntry<AudioCodec>] = [
        QualityTokenEntry(.trueHD, aliases: ["TrueHD", "True HD"]),
        QualityTokenEntry(.dtsHDMA, aliases: ["DTS HD MA", "DTS HDMA", "DTS X", "DTS-X"]),
        QualityTokenEntry(.dts, aliases: ["DTS"]),
        QualityTokenEntry(.eac3, aliases: ["EAC3", "E AC3", "DDP", "DD+", "DD Plus"]),
        QualityTokenEntry(.ac3, aliases: ["AC3", "DD"]),
        QualityTokenEntry(.aac, aliases: ["AAC"]),
        QualityTokenEntry(.flac, aliases: ["FLAC"]),
        QualityTokenEntry(.mp3, aliases: ["MP3"]),
        QualityTokenEntry(.opus, aliases: ["Opus"]),
    ]

    // MARK: HDR
    static let hdr: [QualityTokenEntry<HDRFormat>] = [
        QualityTokenEntry(.hdr10Plus, aliases: ["HDR10Plus", "HDR10+", "HDR10 Plus"]),
        QualityTokenEntry(.dolbyVision, aliases: ["Dolby Vision", "DoVi", "DV"]),
        QualityTokenEntry(.hdr10, aliases: ["HDR10", "HDR"]),
        QualityTokenEntry(.hlg, aliases: ["HLG"]),
    ]

    // MARK: Edition
    static let edition: [QualityTokenEntry<Edition>] = [
        QualityTokenEntry(.directorsCut, aliases: ["Directors Cut", "Director's Cut", "DC"]),
        QualityTokenEntry(.extended, aliases: ["Extended Cut", "Extended Edition", "Extended"]),
        QualityTokenEntry(.remastered, aliases: ["Remastered"]),
        QualityTokenEntry(.imax, aliases: ["IMAX"]),
        QualityTokenEntry(.uncut, aliases: ["Uncut"]),
        QualityTokenEntry(.unknown("Unrated"), aliases: ["Unrated"]),
        QualityTokenEntry(.unknown("Theatrical"), aliases: ["Theatrical Cut", "Theatrical"]),
        QualityTokenEntry(.unknown("Criterion"), aliases: ["Criterion"]),
    ]

    // MARK: Language (plain strings — §8 doesn't call for a closed enum here)
    static let language: [QualityTokenEntry<String>] = [
        QualityTokenEntry("Multi", aliases: ["MULTI"]),
        QualityTokenEntry("Dual Audio", aliases: ["Dual Audio", "DUAL"]),
        QualityTokenEntry("French", aliases: ["FRENCH", "VFF", "VOSTFR"]),
        QualityTokenEntry("German", aliases: ["GERMAN"]),
        QualityTokenEntry("Italian", aliases: ["ITALIAN"]),
        QualityTokenEntry("Spanish", aliases: ["SPANISH", "CASTELLANO"]),
        QualityTokenEntry("Japanese", aliases: ["JAPANESE", "JAPDUB"]),
        QualityTokenEntry("Korean", aliases: ["KOREAN"]),
        QualityTokenEntry("Russian", aliases: ["RUSSIAN"]),
        QualityTokenEntry("Hindi", aliases: ["HINDI"]),
    ]

    // MARK: Proper / repack (booleans, but table-shaped for consistency)
    static let proper: [QualityTokenEntry<Bool>] = [QualityTokenEntry(true, aliases: ["PROPER"])]
    static let repack: [QualityTokenEntry<Bool>] = [QualityTokenEntry(true, aliases: ["REPACK", "RERIP"])]

    // MARK: Document format
    //
    // Typed rather than a canonical-uppercase string (7d §3.2): this is what
    // the text ranking sorts on, and a Torznab book indexer is the only
    // source whose format Fetch learns by parsing a release name. A string
    // here would leave every non-Gutenberg book unrankable.
    static let documentFormat: [QualityTokenEntry<DocumentFormat>] = [
        QualityTokenEntry(.epub, aliases: ["EPUB"]),
        QualityTokenEntry(.pdf, aliases: ["PDF"]),
        QualityTokenEntry(.mobi, aliases: ["MOBI"]),
        QualityTokenEntry(.azw3, aliases: ["AZW3", "KF8"]),
        QualityTokenEntry(.cbr, aliases: ["CBR"]),
        QualityTokenEntry(.cbz, aliases: ["CBZ"]),
        QualityTokenEntry(.djvu, aliases: ["DJVU"]),
    ]

    /// Trailing hyphen-fragments that are never a release group. This
    /// exists because the group-tag heuristic (`ReleaseNameParser`) looks
    /// at the *last* hyphen in the raw name, and a source token like
    /// "WEB-DL" also contains a hyphen — when a release genuinely has no
    /// group tag at all and the name simply ends in "...WEB-DL", the naive
    /// heuristic would otherwise misread "DL" as the group.
    static let neverAGroupTag: Set<String> = [
        "DL", "RIP", "SD", "HD", "3D", "NF", "AMZN", "DSNP",
    ]

    /// True when `word` is (in full) a recognized quality token in any
    /// category — a second, more general guard for the same trailing-group
    /// heuristic: a candidate that is exactly "x265" or "REPACK" is a
    /// codec/flag that got left at the end of the name, not a group.
    static func isEntirelyAQualityToken(_ word: String) -> Bool {
        func matchesWhole<V>(_ table: [QualityTokenEntry<V>]) -> Bool {
            guard let match = QualityMatcher.find(table, in: word) else { return false }
            return match.range == word.startIndex..<word.endIndex
        }
        return matchesWhole(resolution) || matchesWhole(source) || matchesWhole(videoCodec)
            || matchesWhole(audioCodec) || matchesWhole(hdr) || matchesWhole(edition)
            || matchesWhole(proper) || matchesWhole(repack) || matchesWhole(language)
    }
}
