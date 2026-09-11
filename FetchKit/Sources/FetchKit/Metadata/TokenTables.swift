import Foundation
import FetchPluginAPI

struct QualityTokenEntry<Value: Sendable>: Sendable {
    let value: Value
    let regex: NSRegularExpression

    init(_ value: Value, aliases: [String]) {
        self.value = value
        let sorted = aliases.sorted { $0.count > $1.count }
        let branches = sorted.map { alias -> String in
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            let leadingIsWord = alias.first.map { $0.isLetter || $0.isNumber } ?? true
            let trailingIsWord = alias.last.map { $0.isLetter || $0.isNumber } ?? true
            return (leadingIsWord ? #"\b"# : "") + escaped + (trailingIsWord ? #"\b"# : "")
        }
        let pattern = "(?:" + branches.joined(separator: "|") + ")"
        self.regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

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
    static let resolution: [QualityTokenEntry<Resolution>] = [
        QualityTokenEntry(.r2160p, aliases: ["2160p", "2160i", "4K", "UHD"]),
        QualityTokenEntry(.r1080p, aliases: ["1080p", "1080i", "FHD"]),
        QualityTokenEntry(.r720p, aliases: ["720p", "720i"]),
        QualityTokenEntry(.r576p, aliases: ["576p", "576i"]),
        QualityTokenEntry(.r480p, aliases: ["480p", "480i"]),
    ]

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

    static let videoCodec: [QualityTokenEntry<VideoCodec>] = [
        QualityTokenEntry(.hevc, aliases: ["HEVC", "x265", "H265", "H 265"]),
        QualityTokenEntry(.avc, aliases: ["AVC", "x264", "H264", "H 264"]),
        QualityTokenEntry(.av1, aliases: ["AV1"]),
        QualityTokenEntry(.xvid, aliases: ["XviD"]),
        QualityTokenEntry(.vp9, aliases: ["VP9"]),
    ]

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

    static let hdr: [QualityTokenEntry<HDRFormat>] = [
        QualityTokenEntry(.hdr10Plus, aliases: ["HDR10Plus", "HDR10+", "HDR10 Plus"]),
        QualityTokenEntry(.dolbyVision, aliases: ["Dolby Vision", "DoVi", "DV"]),
        QualityTokenEntry(.hdr10, aliases: ["HDR10", "HDR"]),
        QualityTokenEntry(.hlg, aliases: ["HLG"]),
    ]

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

    static let proper: [QualityTokenEntry<Bool>] = [QualityTokenEntry(true, aliases: ["PROPER"])]
    static let repack: [QualityTokenEntry<Bool>] = [QualityTokenEntry(true, aliases: ["REPACK", "RERIP"])]

    static let documentFormat: [QualityTokenEntry<DocumentFormat>] = [
        QualityTokenEntry(.epub, aliases: ["EPUB"]),
        QualityTokenEntry(.pdf, aliases: ["PDF"]),
        QualityTokenEntry(.mobi, aliases: ["MOBI"]),
        QualityTokenEntry(.azw3, aliases: ["AZW3", "KF8"]),
        QualityTokenEntry(.cbr, aliases: ["CBR"]),
        QualityTokenEntry(.cbz, aliases: ["CBZ"]),
        QualityTokenEntry(.djvu, aliases: ["DJVU"]),
    ]

    static let gameSignal: [QualityTokenEntry<Bool>] = [
        QualityTokenEntry(true, aliases: [
            "FITGIRL", "DODI", "ELAMIGOS", "XATAB", "KAOSKREW",
            "RAZOR1911", "SKIDROW", "TENOKE",
            "GOG", "DENUVO", "GAMERIP",
        ]),
    ]

    static let neverAGroupTag: Set<String> = [
        "DL", "RIP", "SD", "HD", "3D", "NF", "AMZN", "DSNP",
    ]

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
