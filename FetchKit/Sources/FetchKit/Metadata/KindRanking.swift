import Foundation
import FetchPluginAPI

/// How one media kind's quality is judged (7d §4).
///
/// The shipped `QualityProfile` was `resolutionOrder` / `sourceOrder` /
/// `codecOrder` — video axes, all three. There was no way to say "prefer FLAC
/// over MP3 320" or "prefer a retail EPUB over a scanned PDF", so ranking was
/// silently inert for music, books, papers and software.
///
/// Every case scores **0…1**, so the composite in `QualityProfile.score`
/// means the same thing whichever kind produced it.
public enum KindRanking: Sendable, Codable, Equatable {
    case video(resolution: [Resolution], source: [ReleaseSource], codec: [VideoCodec])
    case audio(codec: [AudioCodec], preferLossless: Bool)
    case text(format: [DocumentFormat])
    /// No quality axis. Such a result orders on name match and popularity
    /// alone — deliberately, and not the same thing as scoring below every
    /// ranked result, since every `.generic` scores alike.
    case generic

    /// Which ranking judges a given kind.
    ///
    /// Unmapped kinds map to `.generic` rather than to nothing: a kind with
    /// no ranking must still be *ranked*, or 7d reintroduces its own bug for
    /// software and games.
    public static func kind(for mediaKind: MediaKind) -> MediaKind {
        switch mediaKind {
        case .movie, .tv, .anime: .movie
        case .music: .music
        case .book: .book
        case .software, .game, .other, .unknown: .other
        }
    }

    func score(_ metadata: ReleaseMetadata) -> Double {
        switch self {
        case .video(let resolutions, let sources, let codecs):
            // The 3 / 2 / 1 weighting is unchanged from the shipped profile;
            // the divisor is new and is only a normalisation, so video's
            // relative order is exactly what it was.
            (Self.rank(metadata.resolution, in: resolutions) * 3.0
                + Self.rank(metadata.source, in: sources) * 2.0
                + Self.rank(metadata.videoCodec, in: codecs) * 1.0) / 6.0

        case .audio(let codecs, let preferLossless):
            // A multiplier, not a filter. "Lossless only" belongs in
            // `rejected`, where the "show N filtered" affordance makes what it
            // removed visible instead of mystifying.
            Self.rank(metadata.audioCodec, in: codecs)
                * (preferLossless && !Self.isLossless(metadata.audioCodec) ? 0.75 : 1.0)

        case .text(let formats):
            Self.rank(metadata.documentFormat, in: formats)

        case .generic:
            0
        }
    }

    private static func isLossless(_ codec: AudioCodec?) -> Bool {
        switch codec {
        case .flac, .trueHD, .dtsHDMA: true
        default: false
        }
    }

    /// 1.0 for the most preferred, decreasing to just above 0 for the least.
    ///
    /// An absent or unrecognized value scores 0 — below every ranked option,
    /// but still ranked, because dropping unparsed releases would hide results
    /// the user can plainly see on the indexer.
    static func rank<T: Equatable>(_ value: T?, in order: [T]) -> Double {
        guard let value, let index = order.firstIndex(of: value), !order.isEmpty else {
            return 0
        }
        return Double(order.count - index) / Double(order.count)
    }
}

extension KindRanking {
    /// Whether this ranking has anything to say about a result.
    ///
    /// Used only for the unclassified-kind fallback in
    /// `QualityProfile.ranking(for:)`: a ranking that would score 0 for want
    /// of the field it reads is not an answer.
    func canScore(_ metadata: ReleaseMetadata) -> Bool {
        switch self {
        case .video:
            metadata.resolution != nil || metadata.source != nil || metadata.videoCodec != nil
        case .audio:
            metadata.audioCodec != nil
        case .text:
            metadata.documentFormat != nil
        case .generic:
            false
        }
    }
}
