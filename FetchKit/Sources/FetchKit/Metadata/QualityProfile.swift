import Foundation
import FetchPluginAPI

/**
 A matchable predicate over one metadata field, so `required`/`rejected`
 express "any x265" or "not CAM" without stringly-typed matching (§8).
 */
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

/**
 Relative pull of each term in the score.
 */
public struct ScoreWeights: Sendable, Codable, Equatable {
    public var quality: Double
    public var popularity: Double

    public init(quality: Double = 1.0, popularity: Double = 0.35) {
        self.quality = quality
        self.popularity = popularity
    }
}

/**
 Ranks releases so "Best match" can beat plain seeder order (§8, 7d §4).

 The premise, from the spec: seeder count alone reliably surfaces the wrong
 thing, because a 720p rip usually out-seeds the REMUX. Quality dominates,
 with popularity as a tiebreaker between comparable releases — and, since
 7d, with the name match above both, so a result is never punished for
 being a kind that has no seeders.
 */
public struct QualityProfile: Sendable, Codable, Equatable {
    public var perKind: [MediaKind: KindRanking]
    public var required: [ReleaseToken]
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

    public static let `default` = QualityProfile(
        perKind: [
            .movie: .video(
                resolution: [.r2160p, .r1080p, .r720p, .r576p, .r480p],
                source: [.remux, .bluray, .webdl, .webrip, .hdtv, .dvd],
                codec: [.av1, .hevc, .avc, .vp9, .xvid]),
            .music: .audio(codec: [.flac, .opus, .aac, .mp3], preferLossless: true),
            .book: .text(format: [.epub, .azw3, .mobi, .cbz, .cbr, .html, .text, .pdf, .djvu]),
            .other: .generic,
        ],
        rejected: [.source(.cam), .source(.screener)])

    func ranking(for metadata: ReleaseMetadata) -> KindRanking {
        let byKind = perKind[KindRanking.kind(for: metadata.mediaKind)] ?? .generic
        guard case .generic = byKind else { return byKind }

        for inferred in [perKind[.movie], perKind[.music], perKind[.book]] {
            if let inferred, inferred.canScore(metadata) { return inferred }
        }
        return byKind
    }


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


    /**
     Reorders each result's candidates by the profile's format preference.

     This is where "prefer EPUB over a scanned PDF" actually happens. One
     Gutenberg book is **one** result with a candidate per format, so format
     preference is a question about candidate order, not result order — and
     it used to be answered inside `GutenbergProvider` at parse time, which
     is why changing the setting did not reorder results already on screen.
     */
    public func orderingCandidates(of results: [SearchResult]) -> [SearchResult] {
        results.map(orderingCandidates(of:))
    }

    public func orderingCandidates(of result: SearchResult) -> SearchResult {
        guard case .text(let formats) = ranking(for: result.metadata),
              result.candidates.count > 1 else { return result }

        let ordered = result.candidates.enumerated()
            .map { (offset: $0.offset, candidate: $0.element) }
            .sorted { a, b in
                let aRank = Self.formatRank(a.candidate.documentFormat, in: formats)
                let bRank = Self.formatRank(b.candidate.documentFormat, in: formats)
                return aRank != bRank ? aRank < bRank : a.offset < b.offset
            }
            .map(\.candidate)

        var metadata = result.metadata
        if let winner = ordered.first(where: { $0.documentFormat != nil })?.documentFormat {
            metadata.documentFormat = winner
        }
        return result.withCandidates(ordered, metadata: metadata)
    }

    private static func formatRank(_ format: DocumentFormat?, in order: [DocumentFormat]) -> Int {
        guard let format, let index = order.firstIndex(of: format) else { return order.count }
        return index
    }


    public struct Outcome: Sendable {
        public let accepted: [SearchResult]
        public let rejected: [SearchResult]
    }

    /**
     Filters, then ranks against the query the user typed.
     */
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

    /**
     Convenience for callers that only want the ranked survivors.
     */
    public func rank(_ results: [SearchResult], matching query: String) -> [SearchResult] {
        apply(to: results, matching: query).accepted
    }

    private func sorted(_ results: [SearchResult], matching query: String) -> [SearchResult] {
        results
            .map { (result: $0, key: sortKey($0, matching: query)) }
            .sorted { a, b in
                if a.key.bucket != b.key.bucket { return a.key.bucket > b.key.bucket }
                if a.key.score != b.key.score { return a.key.score > b.key.score }
                return a.result.id.rawValue < b.result.id.rawValue
            }
            .map(\.result)
    }

    func sortKey(_ result: SearchResult, matching query: String) -> (bucket: Int, score: Double) {
        (NameMatch.bucket(title: result.title, query: query), score(result))
    }

    /**
     Quality position plus a damped popularity term.

     Popularity is logarithmic: the difference between 5 and 50 is worth
     caring about, between 2,000 and 4,000 is not, and a linear term would
     let a wildly popular rip overwhelm every quality signal — the exact
     failure this ranking exists to prevent.
     */
    public func score(_ result: SearchResult) -> Double {
        let quality = ranking(for: result.metadata).score(result.metadata)
        return quality * weights.quality + popularity(of: result) * weights.popularity
    }

    private func popularity(of result: SearchResult) -> Double {
        let count = result.seeders ?? result.grabs ?? 0
        return min(log10(Double(max(count, 0)) + 1) / Self.popularityCeiling, 1.0)
    }

    private static let popularityCeiling = 5.0
}


extension QualityProfile {
    private enum CodingKeys: String, CodingKey {
        case version, perKind, required, rejected, weights
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
