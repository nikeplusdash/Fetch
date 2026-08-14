import Foundation
import FetchPluginAPI

/// Pure, synchronous, table-driven release-name parser (§8). Turns a
/// release or file name into a `ReleaseMetadata` with `.titleParse`
/// provenance on every field it determined. No I/O, no attribute lookup —
/// `ReleaseMetadataMerger` is what overlays Torznab attributes afterward.
///
/// ## Parsing order
///
/// §8 states the order as: normalize separators (after saving the group
/// tags) → season/episode → year → quality tokens → title = everything
/// before the earliest boundary → infer `mediaKind`. The *implementation*
/// below runs the year and quality-token steps in the opposite sequence
/// (quality tokens first), because resolving "is this 4-digit token the
/// year" requires knowing whether a quality token appears anywhere after
/// it (§8's own rule: "the last 4-digit token wins as the release year
/// only when another quality token follows it") — that check needs the
/// quality-token positions already in hand. The *result* matches §8's
/// stated precedence; only the internal computation order differs, and
/// only because the dependency runs the other way.
enum ReleaseNameParser {
    static func parse(_ rawName: String) -> ReleaseMetadata {
        var working = rawName

        // Step 1: strip a file extension (irrelevant to a bare release
        // name, essential for file-level parsing — §8's two-level parsing
        // works on real file names like "Show.S01E05.1080p.mkv").
        Self.stripKnownExtension(&working)

        // Step 1 (cont'd): capture the leading `[Group]` anime tag and the
        // trailing `-GROUP` scene tag *before* separator normalization
        // would destroy the brackets/hyphen that mark them (§8).
        let leadingGroupTag = Self.captureLeadingBracketTag(&working)
        let trailingGroupTag = Self.captureTrailingGroupTag(&working)

        // Also capture audio channels ("5.1", "7.1", "2.0") before dot
        // normalization would destroy the decimal point — the same
        // "preserve before destroying" principle §8 states for group tags,
        // extended to the one other dot-bearing token the schema tracks.
        // "DDP5.1" has no word boundary between the codec letters and the
        // digit run (letters and digits are both `\w`), so a space is
        // inserted first to give the channel regex somewhere to anchor.
        working = Self.channelFusionFix.stringByReplacingMatches(
            in: working, range: NSRange(working.startIndex..., in: working), withTemplate: "$1 $2"
        )
        let audioChannels = Self.extractAudioChannels(working)

        // Step 1 (cont'd): normalize `.`/`_` to spaces. Hyphens are
        // deliberately normalized *after* season/episode extraction below
        // — the range form (`S01E02-E05`) is distinguished from the list
        // form (`S01E02E03`) only by that hyphen, so destroying it first
        // would erase the very signal step 2 depends on.
        working = Self.normalize(working, targets: [".", "_"])

        // Step 2: season/episode, in §8's precedence order.
        let seasonEpisodeMatch = SeasonEpisodePattern.firstMatch(
            in: working, allowAnimeNumbering: leadingGroupTag != nil
        )
        // Carry the match's position across the hyphen-normalization below
        // via integer offsets (not `String.Index`, which is not valid
        // across two different `String` values) — safe because replacing
        // "-" with " " is character-count-preserving.
        let seasonEpisodeOffsets = seasonEpisodeMatch.map {
            (start: working.distance(from: working.startIndex, to: $0.range.lowerBound),
             end: working.distance(from: working.startIndex, to: $0.range.upperBound))
        }

        // "Artist - Album" / "Author - Title" (music/book convention) is
        // the same story as the anime dash pattern above — the delimiting
        // hyphen must be read before normalization destroys it. Only the
        // *first* " - " counts, and only the offsets are kept (same
        // character-count-preserving trick as `seasonEpisodeOffsets`);
        // whether it's actually used is decided later, once `mediaKind`
        // is known — a movie/TV title that happens to contain " - " as a
        // stylistic separator must not get split.
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

        // Step 4 (computed ahead of step 3 — see the doc comment above):
        // match every quality-token table against the whole string.
        let quality = QualityMatches(in: working)

        // Step 3: year. See `resolveYear` for the "last 4-digit token,
        // only if a quality token follows it" rule (§8) that disambiguates
        // `Blade Runner 2049` (no year — nothing follows "2049") from
        // `2012 2009 1080p...` (year 2009 — "1080p" follows it).
        let yearMatch = Self.resolveYear(in: working, quality: quality)

        // Step 5: title = everything before the earliest boundary.
        var boundaries: [String.Index] = []
        if let seasonEpisodeRange { boundaries.append(seasonEpisodeRange.lowerBound) }
        if let yearMatch { boundaries.append(yearMatch.range.lowerBound) }
        if let start = quality.earliestStart { boundaries.append(start) }
        let titleBoundary = boundaries.min()

        let rawTitle = titleBoundary.map { String(working[working.startIndex..<$0]) } ?? working
        let title = Self.cleanUpTitle(rawTitle)

        // Only usable if the split point actually falls inside the title
        // region — the anime dash pattern (" - 12 ") also matches
        // `findCreditSplit`'s shape, but its `remainderStart` would land
        // at/after `titleBoundary`, which the season/episode branch below
        // ignores this pair for entirely.
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

    // MARK: - Step 1: extension / group tags

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

    // MARK: - Audio channels

    fileprivate static let channelFusionFix = try! NSRegularExpression(pattern: #"([A-Za-z])(\d\.\d)"#)
    private static let channelPattern = try! NSRegularExpression(pattern: #"\b([1-7]\.[01])\b"#)

    private static func extractAudioChannels(_ s: String) -> String? {
        let full = NSRange(s.startIndex..., in: s)
        guard let match = channelPattern.firstMatch(in: s, range: full),
              let range = Range(match.range(at: 1), in: s)
        else { return nil }
        return String(s[range])
    }

    // MARK: - Separator normalization (character-count-preserving)

    private static func normalize(_ s: String, targets: Set<Character>) -> String {
        String(s.map { targets.contains($0) ? " " : $0 })
    }

    /// The *first* " - " in `text` — the conventional "Artist - Album" /
    /// "Author - Title" delimiter. Must run before hyphen normalization
    /// destroys it (same reasoning as the group tags and season/episode
    /// range hyphen). Whether it is actually a credit split (vs., e.g.,
    /// the anime " - 12 " absolute-episode marker, or just absent) is
    /// decided later by the caller.
    private static func findCreditSplit(
        in text: String
    ) -> (creditEnd: String.Index, remainderStart: String.Index)? {
        guard let range = text.range(of: " - ") else { return nil }
        return (range.lowerBound, range.upperBound)
    }

    // MARK: - Step 3: year

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

        // "the last 4-digit token wins as the release year only when
        // another quality token follows it; otherwise it stays part of
        // the title" (§8) — e.g. "Blade Runner 2049 2017 2160p..." picks
        // 2017 (2160p follows it) and leaves "2049" in the title; a bare
        // "Blade Runner 2049" with nothing after it leaves the number in
        // the title entirely (`year` stays `nil`).
        guard let qualityStart = quality.earliestStart, qualityStart > last.lowerBound else { return nil }

        guard let value = Int(text[last]) else { return nil }
        return (last, value)
    }

    // MARK: - Title clean-up

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

    // MARK: - Step 6: mediaKind inference + music/book title splitting

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
        /// Something to actually look at, as opposed to a source a release of
        /// any kind could have come from.
        let hasPicture = metadata.resolution != nil || metadata.videoCodec != nil

        if hasSeasonOrEpisode {
            let isAnime = leadingGroupTag != nil || metadata.absoluteEpisode != nil
            metadata.mediaKind = isAnime ? .anime : .tv
            return
        }

        // "Artist - Album" / "Author - Title" (music/book convention):
        // only applied once we know the release actually *is* music/book —
        // a movie or TV title that happens to contain " - " must keep it.
        if let bookFormatMatch = QualityMatcher.find(TokenTables.documentFormat, in: quality.sourceText) {
            metadata.mediaKind = .book
            metadata.documentFormat = bookFormatMatch.value
            if let creditPart, let remainderPart {
                metadata.author = creditPart
                metadata.title = remainderPart
            }
            return
        }

        // **A source is not a picture.** `hasVideoSignal` counts `source`, and
        // WEB, CD and Vinyl are all sources a *music* release carries — so
        // "Muse - The Wow! Signal .2026.WEB.FLAC.[16bit.44.1khz]-EICHBAUM"
        // failed the music test on the strength of the word WEB, fell through
        // to "has a year, so it is a film", and the album was filed under
        // Movies. Only a resolution or a video codec means there is something
        // to look at.
        //
        // The codec is what settles the rest. Dropping `source` from the test
        // outright would make "Some.Movie.2020.WEB.DTS-GROUP" music, because a
        // film with no resolution in its name still names its audio. FLAC, MP3
        // and Opus are how music is distributed; DTS, AC3, E-AC3 and TrueHD are
        // film soundtracks. AAC is deliberately absent — it is as common in a
        // video container as in a music one, so it decides nothing on its own
        // and falls back to the stricter test.
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

        // **Before the year, because the year is what fooled it.** The rule
        // below is "a release with a year is a film", and a game repack carries
        // one as reliably as a film does. Only tokens that cannot appear in a
        // film release are checked here, so this can run first without turning
        // false Movies into false Games. See `TokenTables.gameSignal`.
        if QualityMatcher.find(TokenTables.gameSignal, in: quality.sourceText) != nil {
            metadata.mediaKind = .game
            return
        }

        metadata.mediaKind = yearMatch != nil ? .movie : .other
    }

    /// How music is distributed, as opposed to how a film's soundtrack is
    /// encoded. See the kind decision above for why the distinction is load
    /// bearing and why AAC is not in it.
    static let musicDistributionCodecs: [AudioCodec] = [.flac, .mp3, .opus]

    // MARK: - Provenance

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

/// Every quality-token-table match found against one working string,
/// computed once and reused for both the year-adjacency check (§8) and
/// the final field population.
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

    /// The leftmost start position among every category match — "the
    /// first quality token" §8's title-boundary rule (step 5) refers to.
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
