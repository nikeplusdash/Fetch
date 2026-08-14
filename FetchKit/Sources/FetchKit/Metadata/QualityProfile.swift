import Foundation
import FetchPluginAPI

/// A matchable predicate over one metadata field, so `required`/`rejected`
/// express "any x265" or "not CAM" without stringly-typed matching (§8).
public enum ReleaseToken: Sendable, Codable, Hashable {
    case resolution(Resolution)
    case source(ReleaseSource)
    case videoCodec(VideoCodec)
    case audioCodec(AudioCodec)
    case hdr(HDRFormat)
    case edition(Edition)
    case language(String)
    case releaseGroup(String)
    case documentFormat(DocumentFormat)
    /// Escape hatch for what the enums cannot express. Case-insensitive
    /// substring, not a regex: a bad regex in a user-supplied profile would
    /// silently match nothing, and a profile that quietly does nothing is
    /// worse than one that cannot be written.
    case titleMatches(String)

    func matches(_ result: SearchResult) -> Bool {
        let metadata = result.metadata
        return switch self {
        case .resolution(let value): metadata.resolution == value
        case .source(let value): metadata.source == value
        case .videoCodec(let value): metadata.videoCodec == value
        case .audioCodec(let value): metadata.audioCodec == value
        case .hdr(let value): metadata.hdr == value
        case .edition(let value): metadata.editions.contains(value)
        case .documentFormat(let value): metadata.documentFormat == value
        case .language(let value):
            metadata.languages.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        case .releaseGroup(let value):
            metadata.releaseGroup?.caseInsensitiveCompare(value) == .orderedSame
        case .titleMatches(let value):
            result.title.localizedCaseInsensitiveContains(value)
        }
    }
}

/// Relative pull of each term in the score.
public struct ScoreWeights: Sendable, Codable, Equatable {
    public var quality: Double
    /// Seeders for a torrent, downloads for Internet Archive and Gutenberg.
    ///
    /// Named for what it measures rather than for torrents: this term was
    /// `seeders`, and reading only `seeders` is half of why a book sorted
    /// last no matter how good it was.
    public var popularity: Double

    public init(quality: Double = 1.0, popularity: Double = 0.35) {
        self.quality = quality
        self.popularity = popularity
    }
}

/// Ranks releases so "Best match" can beat plain seeder order (§8, 7d §4).
///
/// The premise, from the spec: seeder count alone reliably surfaces the wrong
/// thing, because a 720p rip usually out-seeds the REMUX. Quality dominates,
/// with popularity as a tiebreaker between comparable releases — and, since
/// 7d, with the name match above both, so a result is never punished for
/// being a kind that has no seeders.
public struct QualityProfile: Sendable, Codable, Equatable {
    /// Keyed by the *representative* kind from `KindRanking.kind(for:)`, not
    /// by every `MediaKind`: `.movie`, `.music`, `.book` and `.other` are the
    /// four groups, so a user editing "Video" edits TV and anime with it.
    public var perKind: [MediaKind: KindRanking]
    /// Rejected if absent.
    public var required: [ReleaseToken]
    /// Rejected if present. A hard filter, never a penalty — no number of
    /// seeders makes a camrip the right answer.
    public var rejected: [ReleaseToken]
    public var weights: ScoreWeights

    public init(
        perKind: [MediaKind: KindRanking],
        required: [ReleaseToken] = [],
        rejected: [ReleaseToken] = [],
        weights: ScoreWeights = ScoreWeights()
    ) {
        self.perKind = perKind
        self.required = required
        self.rejected = rejected
        self.weights = weights
    }

    /// The shipped default: bigger and cleaner is better, cam and screener
    /// are refused outright (§8).
    public static let `default` = QualityProfile(
        perKind: [
            .movie: .video(
                resolution: [.r2160p, .r1080p, .r720p, .r576p, .r480p],
                source: [.remux, .bluray, .webdl, .webrip, .hdtv, .dvd],
                codec: [.av1, .hevc, .avc, .vp9, .xvid]),
            .music: .audio(codec: [.flac, .opus, .aac, .mp3], preferLossless: true),
            // PDF and DjVu last, not rejected: the amendment's line is "a
            // scanned PDF is the camrip of books", but a PDF is often the only
            // edition that exists, and refusing it outright would hide a book
            // rather than rank it low.
            .book: .text(format: [.epub, .azw3, .mobi, .cbz, .cbr, .html, .text, .pdf, .djvu]),
            .other: .generic,
        ],
        rejected: [.source(.cam), .source(.screener)])

    /// The ranking that judges a result.
    ///
    /// Normally the kind decides. When it does not — `.other`, `.software`,
    /// an `.unknown` the parser could not classify — the *metadata* decides
    /// instead: a result carrying a resolution is ranked on video axes even if
    /// nobody could say it was a film.
    ///
    /// Without that fallback, 7d would have quietly stopped ranking every
    /// release the parser fails to classify, which before 7d ranked fine on
    /// resolution and source. The existing video suite is what caught it.
    func ranking(for metadata: ReleaseMetadata) -> KindRanking {
        let byKind = perKind[KindRanking.kind(for: metadata.mediaKind)] ?? .generic
        guard case .generic = byKind else { return byKind }

        for inferred in [perKind[.movie], perKind[.music], perKind[.book]] {
            if let inferred, inferred.canScore(metadata) { return inferred }
        }
        return byKind
    }

    // MARK: - Editing surface
    //
    // `perKind` is the storage; these are how Settings and tests reach one
    // axis without unwrapping the enum at every call site. Setting an axis on
    // a profile whose ranking is a different case is a no-op — there is one
    // video ranking, and asking for its resolution order is asking for video.

    public var resolutionOrder: [Resolution] {
        get { if case .video(let r, _, _) = videoRanking { r } else { [] } }
        set {
            guard case .video(_, let s, let c) = videoRanking else { return }
            perKind[.movie] = .video(resolution: newValue, source: s, codec: c)
        }
    }

    public var sourceOrder: [ReleaseSource] {
        get { if case .video(_, let s, _) = videoRanking { s } else { [] } }
        set {
            guard case .video(let r, _, let c) = videoRanking else { return }
            perKind[.movie] = .video(resolution: r, source: newValue, codec: c)
        }
    }

    public var codecOrder: [VideoCodec] {
        get { if case .video(_, _, let c) = videoRanking { c } else { [] } }
        set {
            guard case .video(let r, let s, _) = videoRanking else { return }
            perKind[.movie] = .video(resolution: r, source: s, codec: newValue)
        }
    }

    public var audioCodecOrder: [AudioCodec] {
        get { if case .audio(let c, _) = audioRanking { c } else { [] } }
        set {
            guard case .audio(_, let lossless) = audioRanking else { return }
            perKind[.music] = .audio(codec: newValue, preferLossless: lossless)
        }
    }

    public var prefersLossless: Bool {
        get { if case .audio(_, let lossless) = audioRanking { lossless } else { false } }
        set {
            guard case .audio(let c, _) = audioRanking else { return }
            perKind[.music] = .audio(codec: c, preferLossless: newValue)
        }
    }

    public var documentFormatOrder: [DocumentFormat] {
        get { if case .text(let f) = textRanking { f } else { [] } }
        set { perKind[.book] = .text(format: newValue) }
    }

    private var videoRanking: KindRanking { perKind[.movie] ?? .generic }
    private var audioRanking: KindRanking { perKind[.music] ?? .generic }
    private var textRanking: KindRanking { perKind[.book] ?? .generic }

    // MARK: - Candidate order (7d §4.7)

    /// Reorders each result's candidates by the profile's format preference.
    ///
    /// This is where "prefer EPUB over a scanned PDF" actually happens. One
    /// Gutenberg book is **one** result with a candidate per format, so format
    /// preference is a question about candidate order, not result order — and
    /// it used to be answered inside `GutenbergProvider` at parse time, which
    /// is why changing the setting did not reorder results already on screen.
    public func orderingCandidates(of results: [SearchResult]) -> [SearchResult] {
        results.map(orderingCandidates(of:))
    }

    public func orderingCandidates(of result: SearchResult) -> SearchResult {
        guard case .text(let formats) = ranking(for: result.metadata),
              result.candidates.count > 1 else { return result }

        // A stable sort on rank alone: candidates with no format keep their
        // relative order and land after every ranked one, rather than being
        // shuffled against each other by an unstable comparison.
        let ordered = result.candidates.enumerated()
            .map { (offset: $0.offset, candidate: $0.element) }
            .sorted { a, b in
                let aRank = Self.formatRank(a.candidate.documentFormat, in: formats)
                let bRank = Self.formatRank(b.candidate.documentFormat, in: formats)
                return aRank != bRank ? aRank < bRank : a.offset < b.offset
            }
            .map(\.candidate)

        // The winner is what the row displays and what a download with no UI
        // takes, so the two cannot be allowed to disagree.
        var metadata = result.metadata
        if let winner = ordered.first(where: { $0.documentFormat != nil })?.documentFormat {
            metadata.documentFormat = winner
        }
        return result.withCandidates(ordered, metadata: metadata)
    }

    /// Position in the preference list; unranked and format-less candidates
    /// sort after every ranked one. Lower is better here, unlike `score`.
    private static func formatRank(_ format: DocumentFormat?, in order: [DocumentFormat]) -> Int {
        guard let format, let index = order.firstIndex(of: format) else { return order.count }
        return index
    }

    // MARK: - Filtering and ranking

    public struct Outcome: Sendable {
        /// Ranked, best first.
        public let accepted: [SearchResult]
        /// Removed by `required`/`rejected`. Surfaced rather than dropped, so
        /// §12.1's "show N filtered" affordance can make an over-strict
        /// profile discoverable instead of mystifying.
        public let rejected: [SearchResult]
    }

    /// Filters, then ranks against the query the user typed.
    public func apply(to results: [SearchResult], matching query: String) -> Outcome {
        var accepted: [SearchResult] = []
        var refused: [SearchResult] = []

        for result in results {
            if rejected.contains(where: { $0.matches(result) })
                || !required.allSatisfy({ $0.matches(result) }) {
                refused.append(result)
            } else {
                accepted.append(result)
            }
        }
        return Outcome(accepted: sorted(accepted, matching: query), rejected: refused)
    }

    /// Convenience for callers that only want the ranked survivors.
    public func rank(_ results: [SearchResult], matching query: String) -> [SearchResult] {
        apply(to: results, matching: query).accepted
    }

    private func sorted(_ results: [SearchResult], matching query: String) -> [SearchResult] {
        results
            .map { (result: $0, key: sortKey($0, matching: query)) }
            .sorted { a, b in
                // Name bucket is a strict outer key: a lower bucket never
                // outranks a higher one however good it is.
                if a.key.bucket != b.key.bucket { return a.key.bucket > b.key.bucket }
                if a.key.score != b.key.score { return a.key.score > b.key.score }
                // Ties break on id, so the order is reproducible run to run.
                return a.result.id.rawValue < b.result.id.rawValue
            }
            .map(\.result)
    }

    func sortKey(_ result: SearchResult, matching query: String) -> (bucket: Int, score: Double) {
        (NameMatch.bucket(title: result.title, query: query), score(result))
    }

    /// Quality position plus a damped popularity term.
    ///
    /// Popularity is logarithmic: the difference between 5 and 50 is worth
    /// caring about, between 2,000 and 4,000 is not, and a linear term would
    /// let a wildly popular rip overwhelm every quality signal — the exact
    /// failure this ranking exists to prevent.
    public func score(_ result: SearchResult) -> Double {
        let quality = ranking(for: result.metadata).score(result.metadata)
        return quality * weights.quality + popularity(of: result) * weights.popularity
    }

    /// Seeders where there are seeders, downloads where there are not.
    ///
    /// A book is not a torrent with nobody seeding it. Internet Archive and
    /// Gutenberg both publish a download count and both already carried it —
    /// as a string in `rawAttributes`, which nothing read.
    private func popularity(of result: SearchResult) -> Double {
        let count = result.seeders ?? result.grabs ?? 0
        return min(log10(Double(max(count, 0)) + 1) / Self.popularityCeiling, 1.0)
    }

    /// log10 of 100,000 — the point above which more is not more.
    ///
    /// The division is what keeps the composite balanced. `kindScore` is
    /// normalised to 0…1, but the video term it replaced ranged 0…6 against
    /// this same weight, so leaving popularity un-normalised made it roughly
    /// ten times more influential overnight — a 500,000-download scanned PDF
    /// beat a retail EPUB, which is the precise failure this ranking exists
    /// to prevent.
    private static let popularityCeiling = 5.0
}

// MARK: - Coding

extension QualityProfile {
    /// `perKind` encodes as a **string-keyed object**.
    ///
    /// Swift's default encoding for a dictionary with a non-`String` key is a
    /// flat alternating array, which would make the persisted profile
    /// unreadable and the v1 migration much harder to write.
    private enum CodingKeys: String, CodingKey {
        case version, perKind, required, rejected, weights
        // v1 shape, read by the migration below.
        case resolutionOrder, sourceOrder, codecOrder
    }

    static let currentVersion = 2

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1

        required = try container.decodeIfPresent([ReleaseToken].self, forKey: .required) ?? []
        rejected = try container.decodeIfPresent([ReleaseToken].self, forKey: .rejected) ?? []
        weights = try container.decodeIfPresent(ScoreWeights.self, forKey: .weights)
            ?? ScoreWeights()

        if version >= Self.currentVersion,
           let raw = try container.decodeIfPresent([String: KindRanking].self, forKey: .perKind) {
            perKind = Dictionary(
                uniqueKeysWithValues: raw.map { (MediaKind(name: $0.key), $0.value) })
        } else {
            // v1: three video axes and nothing else. Fold them into the video
            // ranking and take the shipped defaults for the kinds v1 could
            // not express — an empty order ranks every format equally, which
            // is the inert ranking 7d exists to fix.
            //
            // Without this the `try?` at the call site would decode nothing,
            // silently reset the profile to `.default`, and discard whatever
            // the user had customised.
            let resolutions = try container.decodeIfPresent(
                [Resolution].self, forKey: .resolutionOrder) ?? []
            let sources = try container.decodeIfPresent(
                [ReleaseSource].self, forKey: .sourceOrder) ?? []
            let codecs = try container.decodeIfPresent(
                [VideoCodec].self, forKey: .codecOrder) ?? []

            perKind = QualityProfile.default.perKind
            perKind[.movie] = .video(resolution: resolutions, source: sources, codec: codecs)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(
            Dictionary(uniqueKeysWithValues: perKind.map { ($0.key.name, $0.value) }),
            forKey: .perKind)
        try container.encode(required, forKey: .required)
        try container.encode(rejected, forKey: .rejected)
        try container.encode(weights, forKey: .weights)
    }
}

extension ScoreWeights {
    private enum CodingKeys: String, CodingKey {
        case quality, popularity
        /// v1's spelling of `popularity`, and a term v1 declared but never
        /// read — `score` computed `quality + seeders` and stopped. `size` is
        /// dropped rather than wired: §8's `sizeBounds` is where size
        /// preference belongs, and a slider that does nothing is worse than
        /// an absent one.
        case seeders, size
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decodeIfPresent(Double.self, forKey: .quality) ?? 1.0
        popularity = try container.decodeIfPresent(Double.self, forKey: .popularity)
            ?? container.decodeIfPresent(Double.self, forKey: .seeders)
            ?? 0.35
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quality, forKey: .quality)
        try container.encode(popularity, forKey: .popularity)
    }
}
