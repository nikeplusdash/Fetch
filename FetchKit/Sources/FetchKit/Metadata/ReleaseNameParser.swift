import Foundation
import FetchPluginAPI

enum ReleaseNameParser {
    static func parse(_ rawName: String) -> ReleaseMetadata {
        var working = rawName

        Self.stripKnownExtension(&working)

        let leadingGroupTag = Self.captureLeadingBracketTag(&working)
        let trailingGroupTag = Self.captureTrailingGroupTag(&working)

        working = Self.channelFusionFix.stringByReplacingMatches(
            in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "$1 $2"
        )
        let audioChannels = Self.extractAudioChannels(working)

        working = Self.normalize(working, targets: [".", "_"])

        let seasonEpisodeMatch = SeasonEpisodePattern.firstMatch(
            in: working, allowAnimeNumbering: leadingGroupTag != nil
        )
        let seasonEpisodeOffsets = seasonEpisodeMatch.map {
            (start: working.distance(from: working.startIndex, to: $0.range.lowerBound),
             end: working.distance(from: working.startIndex, to: $0.range.upperBound))
        }

        let creditSplitOffsets = Self.findCreditSplit(in: working).map {
            (creditEnd: working.distance(from: working.startIndex, to: $0.creditEnd),
             remainderStart: working.distance(from: working.startIndex, to: $0.remainderStart))
        }

        working = Self.normalize(working, targets: ["-"])

        let seasonEpisodeRange: Range<String.Index>? = seasonEpisodeOffsets.map { offsets in
            let lower = working.index(working.startIndex, offsetBy: offsets.start)
            let upper = working.index(working.startIndex, offsetBy: offsets.end)
            return lower..<upper
        }
        let creditSplit: (creditEnd: String.Index, remainderStart: String.Index)? = creditSplitOffsets.map { offsets in
            (working.index(working.startIndex, offsetBy: offsets.creditEnd),
             working.index(working.startIndex, offsetBy: offsets.remainderStart))
        }

        let quality = QualityMatches(in: working)

        let yearMatch = Self.resolveYear(in: working, quality: quality)

        var boundaries: [String.Index] = []
        if let seasonEpisodeRange { boundaries.append(seasonEpisodeRange.lowerBound) }
        if let yearMatch { boundaries.append(yearMatch.range.lowerBound) }
        if let start = quality.earliestStart { boundaries.append(start) }
        let titleBoundary = boundaries.min()

        let rawTitle = titleBoundary.map { String(working[working.startIndex..<$0]) } ?? working
        let title = Self.cleanUpTitle(rawTitle)

        var creditPart: String?
        var remainderPart: String?
        if let creditSplit, let titleBoundary, creditSplit.creditEnd < titleBoundary {
            creditPart = Self.cleanUpTitle(String(working[working.startIndex..<creditSplit.creditEnd]))
            remainderPart = Self.cleanUpTitle(String(working[creditSplit.remainderStart..<titleBoundary]))
        }

        let releaseGroup = trailingGroupTag ?? leadingGroupTag

        var metadata = ReleaseMetadata(
            season: seasonEpisodeMatch?.season,
            episodes: seasonEpisodeMatch?.episodes ?? [],
            absoluteEpisode: seasonEpisodeMatch?.absoluteEpisode,
            isSeasonPack: seasonEpisodeMatch?.isSeasonPack ?? false,
            resolution: quality.resolution?.value,
            source: quality.source?.value,
            videoCodec: quality.videoCodec?.value,
            audioCodec: quality.audioCodec?.value,
            audioChannels: audioChannels,
            hdr: quality.hdr?.value,
            editions: quality.edition.map { [$0.value] } ?? [],
            languages: quality.languages.map(\.value),
            isProper: quality.isProper != nil,
            isRepack: quality.isRepack != nil,
            releaseGroup: releaseGroup
        )

        Self.inferMediaKindAndTitleFields(
            into: &metadata, title: title, quality: quality, leadingGroupTag: leadingGroupTag,
            yearMatch: yearMatch, creditPart: creditPart, remainderPart: remainderPart
        )

        Self.recordTitleParseProvenance(&metadata)
        return metadata
    }


    private static let knownExtensions: Set<String> = [
        "mkv", "mp4", "avi", "ts", "m2ts", "wmv", "mov", "m4v",
        "flac", "mp3", "m4a", "wav", "ogg", "opus", "aac",
        "epub", "pdf", "mobi", "azw3", "cbr", "cbz",
        "nfo", "txt", "jpg", "jpeg", "png", "srt", "idx", "sub",
    ]

    private static func stripKnownExtension(_ s: inout String) {
        guard let dotIndex = s.lastIndex(of: "."), s.distance(from: dotIndex, to: s.endIndex) <= 6 else { return }
        let ext = s[s.index(after: dotIndex)...].lowercased()
        guard knownExtensions.contains(ext) else { return }
        s = String(s[..<dotIndex])
    }

    private static let leadingBracketTag = try! NSRegularExpression(
        pattern: #"^\[([^\]]+)\]\s*"#, options: []
    )

    private static func captureLeadingBracketTag(_ s: inout String) -> String? {
        let full = NSRange(s.startIndex..., in: s)
        guard let match = leadingBracketTag.firstMatch(in: s, range: full),
              let tagRange = Range(match.range(at: 1), in: s),
              let wholeRange = Range(match.range, in: s)
        else { return nil }
        let tag = String(s[tagRange])
        s.removeSubrange(wholeRange)
        return tag
    }

    private static let trailingGroupTag = try! NSRegularExpression(
        pattern: #"-([A-Za-z][A-Za-z0-9]*)$"#, options: []
    )

    private static func captureTrailingGroupTag(_ s: inout String) -> String? {
        let full = NSRange(s.startIndex..., in: s)
        guard let match = trailingGroupTag.firstMatch(in: s, range: full),
              let tagRange = Range(match.range(at: 1), in: s),
              let wholeRange = Range(match.range, in: s)
        else { return nil }
        let tag = String(s[tagRange])
        guard !TokenTables.neverAGroupTag.contains(tag.uppercased()),
              !TokenTables.isEntirelyAQualityToken(tag)
        else { return nil }
        s.removeSubrange(wholeRange)
        return tag
    }


    fileprivate static let channelFusionFix = try! NSRegularExpression(pattern: #"([A-Za-z])(\d\.\d)"#)
    private static let channelPattern = try! NSRegularExpression(pattern: #"\b([1-7]\.[01])\b"#)

    private static func extractAudioChannels(_ s: String) -> String? {
        let full = NSRange(s.startIndex..., in: s)
        guard let match = channelPattern.firstMatch(in: s, range: full),
              let range = Range(match.range(at: 1), in: s)
        else { return nil }
        return String(s[range])
    }


    private static func normalize(_ s: String, targets: Set<Character>) -> String {
        String(s.map { targets.contains($0) ? " " : $0 })
    }

    private static func findCreditSplit(
        in text: String
    ) -> (creditEnd: String.Index, remainderStart: String.Index)? {
        guard let range = text.range(of: " - ") else { return nil }
        return (range.lowerBound, range.upperBound)
    }


    private static let yearPattern = try! NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#)

    private static func resolveYear(
        in text: String, quality: QualityMatches
    ) -> (range: Range<String.Index>, value: Int)? {
        let full = NSRange(text.startIndex..., in: text)
        var candidates: [Range<String.Index>] = []
        yearPattern.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            candidates.append(r)
        }
        guard let last = candidates.last else { return nil }

        guard let qualityStart = quality.earliestStart, qualityStart > last.lowerBound else { return nil }

        guard let value = Int(text[last]) else { return nil }
        return (last, value)
    }


    private static let trimCharacters: Set<Character> = ["(", "[", "-", ",", ".", ":", " "]

    private static func cleanUpTitle(_ raw: String) -> String? {
        var chars = Array(raw)
        while let last = chars.last, trimCharacters.contains(last) { chars.removeLast() }
        while let first = chars.first, first == " " { chars.removeFirst() }
        let collapsed = String(chars)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }


    private static func inferMediaKindAndTitleFields(
        into metadata: inout ReleaseMetadata, title: String?, quality: QualityMatches,
        leadingGroupTag: String?, yearMatch: (range: Range<String.Index>, value: Int)?,
        creditPart: String?, remainderPart: String?
    ) {
        metadata.title = title
        metadata.year = yearMatch?.value

        let hasSeasonOrEpisode = metadata.season != nil || !metadata.episodes.isEmpty
            || metadata.absoluteEpisode != nil
        let hasVideoSignal = metadata.resolution != nil || metadata.videoCodec != nil || metadata.source != nil
        let hasPicture = metadata.resolution != nil || metadata.videoCodec != nil

        if hasSeasonOrEpisode {
            let isAnime = leadingGroupTag != nil || metadata.absoluteEpisode != nil
            metadata.mediaKind = isAnime ? .anime : .tv
            return
        }

        if let bookFormatMatch = QualityMatcher.find(TokenTables.documentFormat, in: quality.sourceText) {
            metadata.mediaKind = .book
            metadata.documentFormat = bookFormatMatch.value
            if let creditPart, let remainderPart {
                metadata.author = creditPart
                metadata.title = remainderPart
            }
            return
        }

        if let audio = metadata.audioCodec, !hasPicture,
           Self.musicDistributionCodecs.contains(audio) || !hasVideoSignal {
            metadata.mediaKind = .music
            if let creditPart, let remainderPart {
                metadata.artist = creditPart
                metadata.title = remainderPart
                metadata.album = remainderPart
            }
            return
        }

        if QualityMatcher.find(TokenTables.gameSignal, in: quality.sourceText) != nil {
            metadata.mediaKind = .game
            return
        }

        metadata.mediaKind = yearMatch != nil ? .movie : .other
    }

    static let musicDistributionCodecs: [AudioCodec] = [.flac, .mp3, .opus]


    private static func recordTitleParseProvenance(_ metadata: inout ReleaseMetadata) {
        var provenance: [MetadataField: MetadataSource] = [:]
        provenance[.mediaKind] = .titleParse
        if metadata.title != nil { provenance[.title] = .titleParse }
        if metadata.year != nil { provenance[.year] = .titleParse }
        if metadata.season != nil { provenance[.season] = .titleParse }
        if !metadata.episodes.isEmpty { provenance[.episodes] = .titleParse }
        if metadata.absoluteEpisode != nil { provenance[.absoluteEpisode] = .titleParse }
        if metadata.isSeasonPack { provenance[.isSeasonPack] = .titleParse }
        if metadata.resolution != nil { provenance[.resolution] = .titleParse }
        if metadata.source != nil { provenance[.source] = .titleParse }
        if metadata.videoCodec != nil { provenance[.videoCodec] = .titleParse }
        if metadata.audioCodec != nil { provenance[.audioCodec] = .titleParse }
        if metadata.audioChannels != nil { provenance[.audioChannels] = .titleParse }
        if metadata.hdr != nil { provenance[.hdr] = .titleParse }
        if !metadata.editions.isEmpty { provenance[.editions] = .titleParse }
        if !metadata.languages.isEmpty { provenance[.languages] = .titleParse }
        if metadata.isProper { provenance[.isProper] = .titleParse }
        if metadata.isRepack { provenance[.isRepack] = .titleParse }
        if metadata.releaseGroup != nil { provenance[.releaseGroup] = .titleParse }
        if metadata.artist != nil { provenance[.artist] = .titleParse }
        if metadata.album != nil { provenance[.album] = .titleParse }
        if metadata.author != nil { provenance[.author] = .titleParse }
        if metadata.documentFormat != nil { provenance[.documentFormat] = .titleParse }
        metadata.provenance = provenance
    }
}

struct QualityMatches {
    let sourceText: String
    let resolution: (range: Range<String.Index>, value: Resolution)?
    let source: (range: Range<String.Index>, value: ReleaseSource)?
    let videoCodec: (range: Range<String.Index>, value: VideoCodec)?
    let audioCodec: (range: Range<String.Index>, value: AudioCodec)?
    let hdr: (range: Range<String.Index>, value: HDRFormat)?
    let edition: (range: Range<String.Index>, value: Edition)?
    let languages: [(range: Range<String.Index>, value: String)]
    let isProper: Range<String.Index>?
    let isRepack: Range<String.Index>?

    init(in text: String) {
        sourceText = text
        resolution = QualityMatcher.find(TokenTables.resolution, in: text)
        source = QualityMatcher.find(TokenTables.source, in: text)
        videoCodec = QualityMatcher.find(TokenTables.videoCodec, in: text)
        audioCodec = QualityMatcher.find(TokenTables.audioCodec, in: text)
        hdr = QualityMatcher.find(TokenTables.hdr, in: text)
        edition = QualityMatcher.find(TokenTables.edition, in: text)
        languages = QualityMatcher.findAll(TokenTables.language, in: text)
        isProper = QualityMatcher.find(TokenTables.proper, in: text)?.range
        isRepack = QualityMatcher.find(TokenTables.repack, in: text)?.range
    }

    var earliestStart: String.Index? {
        var starts: [String.Index] = []
        if let resolution { starts.append(resolution.range.lowerBound) }
        if let source { starts.append(source.range.lowerBound) }
        if let videoCodec { starts.append(videoCodec.range.lowerBound) }
        if let audioCodec { starts.append(audioCodec.range.lowerBound) }
        if let hdr { starts.append(hdr.range.lowerBound) }
        if let edition { starts.append(edition.range.lowerBound) }
        starts.append(contentsOf: languages.map(\.range.lowerBound))
        if let isProper { starts.append(isProper.lowerBound) }
        if let isRepack { starts.append(isRepack.lowerBound) }
        if let documentFormat = QualityMatcher.find(TokenTables.documentFormat, in: sourceText) {
            starts.append(documentFormat.range.lowerBound)
        }
        return starts.min()
    }
}
