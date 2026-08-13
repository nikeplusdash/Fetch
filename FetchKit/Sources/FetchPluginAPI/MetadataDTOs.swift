import Foundation

// MARK: - Forward-compatible enums (§8)
//
// Same rule as `DebridTorrentState` (`DebridDTOs.swift`): an unrecognized
// token must round-trip through `Codable` unchanged, never trap and never
// silently become `nil`. Each enum below carries a single canonical raw
// string for its known cases and an `.unknown(String)` case for everything
// else. The *parser's* alias tables (which release-name spellings map to
// which case, e.g. "BDRip" and "Blu-Ray" both meaning `.bluray`) are a
// separate, much larger concern and live in `FetchKit/Metadata/TokenTables`
// — this file only fixes the wire format.

/// What kind of content a release is. Drives which optional fields of
/// `ReleaseMetadata` are meaningful (season/episode for `.tv`/`.anime`,
/// artist/album for `.music`, author/documentFormat for `.book`).
/// A metadata value whose canonical wire spelling is also what the UI shows.
///
/// `MediaKind` had this as a bare `name` property already, for a persistence
/// reason. Making it a protocol and giving it to the rest removes the trick
/// three views were using to read these: encoding the value to JSON and
/// decoding it back as a `String`, purely to reach the switch inside
/// `encode(to:)`. That worked, silently returned `"?"` when it did not, and
/// was written out three times.
///
/// One switch per type now serves both encoding and display.
public protocol WireNamed {
    /// The canonical spelling. Round-trips through `init(from:)`.
    var name: String { get }
}

public enum MediaKind: Sendable, Codable, Equatable, Hashable, WireNamed {
    case movie, tv, anime, music, book, software, game, other
    case unknown(String)

    /// The canonical wire spelling. Exposed rather than buried in `encode`
    /// because 7d keys a dictionary on `MediaKind`, and Swift encodes a
    /// dictionary with a non-`String` key as a flat alternating array — which
    /// would make the persisted `QualityProfile` unreadable.
    public var name: String {
        switch self {
        case .movie: "movie"
        case .tv: "tv"
        case .anime: "anime"
        case .music: "music"
        case .book: "book"
        case .software: "software"
        case .game: "game"
        case .other: "other"
        case .unknown(let raw): raw
        }
    }

    public init(name: String) {
        switch name.lowercased() {
        case "movie": self = .movie
        case "tv": self = .tv
        case "anime": self = .anime
        case "music": self = .music
        case "book": self = .book
        case "software": self = .software
        case "game": self = .game
        case "other": self = .other
        default: self = .unknown(name)
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(name: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// Vertical resolution. `.other` is reserved for the enum itself never being
/// used as a token value — genuinely unrecognized text becomes `.unknown`.
public enum Resolution: Sendable, Codable, Equatable, Hashable, WireNamed {
    case r2160p, r1080p, r720p, r576p, r480p
    case unknown(String)

    public var name: String {
        switch self {
        case .r2160p: "2160p"
        case .r1080p: "1080p"
        case .r720p: "720p"
        case .r576p: "576p"
        case .r480p: "480p"
        case .unknown(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "2160p": self = .r2160p
        case "1080p": self = .r1080p
        case "720p": self = .r720p
        case "576p": self = .r576p
        case "480p": self = .r480p
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

public enum ReleaseSource: Sendable, Codable, Equatable, Hashable, WireNamed {
    case remux, bluray, webdl, webrip, hdtv, dvd, screener, cam
    case unknown(String)

    public var name: String {
        switch self {
        case .remux: "remux"
        case .bluray: "bluray"
        case .webdl: "webdl"
        case .webrip: "webrip"
        case .hdtv: "hdtv"
        case .dvd: "dvd"
        case .screener: "screener"
        case .cam: "cam"
        case .unknown(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "remux": self = .remux
        case "bluray": self = .bluray
        case "webdl": self = .webdl
        case "webrip": self = .webrip
        case "hdtv": self = .hdtv
        case "dvd": self = .dvd
        case "screener": self = .screener
        case "cam": self = .cam
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

public enum VideoCodec: Sendable, Codable, Equatable, Hashable, WireNamed {
    case hevc, avc, av1, xvid, vp9
    case unknown(String)

    public var name: String {
        switch self {
        case .hevc: "hevc"
        case .avc: "avc"
        case .av1: "av1"
        case .xvid: "xvid"
        case .vp9: "vp9"
        case .unknown(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "hevc": self = .hevc
        case "avc": self = .avc
        case "av1": self = .av1
        case "xvid": self = .xvid
        case "vp9": self = .vp9
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

public enum AudioCodec: Sendable, Codable, Equatable, Hashable, WireNamed {
    case trueHD, dtsHDMA, dts, eac3, ac3, aac, flac, mp3, opus
    case unknown(String)

    public var name: String {
        switch self {
        case .trueHD: "truehd"
        case .dtsHDMA: "dtshdma"
        case .dts: "dts"
        case .eac3: "eac3"
        case .ac3: "ac3"
        case .aac: "aac"
        case .flac: "flac"
        case .mp3: "mp3"
        case .opus: "opus"
        case .unknown(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "truehd": self = .trueHD
        case "dtshdma": self = .dtsHDMA
        case "dts": self = .dts
        case "eac3": self = .eac3
        case "ac3": self = .ac3
        case "aac": self = .aac
        case "flac": self = .flac
        case "mp3": self = .mp3
        case "opus": self = .opus
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// The format a document or book is published in (7d §3.1).
///
/// Deliberately **not** Gutenberg's `BookFormat`, which is a Gutendex MIME
/// decoder: its cases are the ones Gutendex names, it has no PDF or comic
/// formats because Project Gutenberg publishes none, and `.htmlZip` is typed
/// `application/octet-stream` because that is what the API says. Internet
/// Archive already serves PDF and DjVu, and Anna's Archive is nearly all of
/// them. This is the neutral vocabulary the ranking speaks; `BookFormat` maps
/// into it and stays what it is.
public enum DocumentFormat: Sendable, Codable, Equatable, Hashable, WireNamed {
    case epub, azw3, mobi, pdf
    case cbz, cbr, djvu
    case html, text
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "epub": self = .epub
        case "azw3": self = .azw3
        case "mobi": self = .mobi
        case "pdf": self = .pdf
        case "cbz": self = .cbz
        case "cbr": self = .cbr
        case "djvu": self = .djvu
        case "html": self = .html
        case "text": self = .text
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }

    /// The wire spelling, which is *not* `displayName`: this is `"epub"`,
    /// that is `"EPUB"`. The distinction predates `WireNamed` and is the
    /// reason the protocol names the wire form rather than the pretty one.
    public var name: String {
        switch self {
        case .epub: "epub"
        case .azw3: "azw3"
        case .mobi: "mobi"
        case .pdf: "pdf"
        case .cbz: "cbz"
        case .cbr: "cbr"
        case .djvu: "djvu"
        case .html: "html"
        case .text: "text"
        case .unknown(let raw): raw
        }
    }

    public var displayName: String {
        switch self {
        case .epub: "EPUB"
        case .azw3: "AZW3"
        case .mobi: "MOBI"
        case .pdf: "PDF"
        case .cbz: "CBZ"
        case .cbr: "CBR"
        case .djvu: "DjVu"
        case .html: "HTML"
        case .text: "Plain text"
        case .unknown(let raw): raw.uppercased()
        }
    }
}

public enum HDRFormat: Sendable, Codable, Equatable, Hashable, WireNamed {
    case hdr10, hdr10Plus, dolbyVision, hlg
    case unknown(String)

    public var name: String {
        switch self {
        case .hdr10: "hdr10"
        case .hdr10Plus: "hdr10plus"
        case .dolbyVision: "dolbyvision"
        case .hlg: "hlg"
        case .unknown(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "hdr10": self = .hdr10
        case "hdr10plus": self = .hdr10Plus
        case "dolbyvision": self = .dolbyVision
        case "hlg": self = .hlg
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

public enum Edition: Sendable, Codable, Equatable, Hashable, WireNamed {
    case extended, directorsCut, remastered, imax, uncut
    case unknown(String)

    public var name: String {
        switch self {
        case .extended: "extended"
        case .directorsCut: "directorscut"
        case .remastered: "remastered"
        case .imax: "imax"
        case .uncut: "uncut"
        case .unknown(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "extended": self = .extended
        case "directorscut": self = .directorsCut
        case "remastered": self = .remastered
        case "imax": self = .imax
        case "uncut": self = .uncut
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

// MARK: - Provenance (§8)

/// Every field `ReleaseMetadata` tracks, so `provenance` can record where
/// each one came from. `String`-backed rather than an `unknown(String)`
/// case: unlike the quality enums above, this describes Fetch's own struct
/// shape, not open-ended external vocabulary — a plugin cannot invent a new
/// field, only contribute values for the fields that already exist.
public enum MetadataField: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case mediaKind, title, year, season, episodes, absoluteEpisode, isSeasonPack, episodeTitle
    case imdbID, tmdbID, tvdbID
    case resolution, source, videoCodec, audioCodec, audioChannels, hdr, editions, languages
    case isProper, isRepack, releaseGroup
    case artist, album, author, documentFormat
}

/// Which of the two sources (§8) produced a field's current value.
/// `.inherited` is specific to two-level parsing: a file that didn't
/// determine a field itself but received it from the torrent-level parse.
public enum MetadataSource: String, Sendable, Codable, Equatable, Hashable {
    case attribute, titleParse, inherited
}

// MARK: - ReleaseMetadata

/// One release's metadata, resolved from the release/file name and (when
/// present) Torznab attributes — see `FetchKit/Metadata/ReleaseNameParser`
/// and `ReleaseMetadataMerger` for how this is populated. `Sendable` and
/// `Codable` because it crosses the plugin boundary (§3, §8): every
/// `metadataEnricher`/`namingStrategy`/`routingRule` extension point
/// receives or returns one.
public struct ReleaseMetadata: Sendable, Codable, Equatable {
    public let apiVersion: Int

    // Identity
    public var mediaKind: MediaKind
    public var title: String?
    public var year: Int?
    public var season: Int?
    /// `S01E02E03` and `S01E02-E05` both yield `[2, 3]`/`[2, 3, 4, 5]` — see
    /// `ReleaseNameParser` for the list-vs-range distinction.
    public var episodes: [Int]
    /// Anime absolute numbering, independent of `season`/`episodes`.
    public var absoluteEpisode: Int?
    public var isSeasonPack: Bool
    public var episodeTitle: String?

    // External identity — from attributes only, never guessed from the name.
    public var imdbID: String?
    public var tmdbID: Int?
    public var tvdbID: Int?

    // Quality
    public var resolution: Resolution?
    public var source: ReleaseSource?
    public var videoCodec: VideoCodec?
    public var audioCodec: AudioCodec?
    public var audioChannels: String?
    public var hdr: HDRFormat?
    public var editions: [Edition]
    public var languages: [String]
    public var isProper: Bool
    public var isRepack: Bool
    public var releaseGroup: String?

    // Music / book
    public var artist: String?
    public var album: String?
    public var author: String?
    public var documentFormat: DocumentFormat?

    // Provenance
    public var provenance: [MetadataField: MetadataSource]

    public init(
        mediaKind: MediaKind = .other,
        title: String? = nil,
        year: Int? = nil,
        season: Int? = nil,
        episodes: [Int] = [],
        absoluteEpisode: Int? = nil,
        isSeasonPack: Bool = false,
        episodeTitle: String? = nil,
        imdbID: String? = nil,
        tmdbID: Int? = nil,
        tvdbID: Int? = nil,
        resolution: Resolution? = nil,
        source: ReleaseSource? = nil,
        videoCodec: VideoCodec? = nil,
        audioCodec: AudioCodec? = nil,
        audioChannels: String? = nil,
        hdr: HDRFormat? = nil,
        editions: [Edition] = [],
        languages: [String] = [],
        isProper: Bool = false,
        isRepack: Bool = false,
        releaseGroup: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        author: String? = nil,
        documentFormat: DocumentFormat? = nil,
        provenance: [MetadataField: MetadataSource] = [:]
    ) {
        self.apiVersion = currentAPIVersion
        self.mediaKind = mediaKind
        self.title = title
        self.year = year
        self.season = season
        self.episodes = episodes
        self.absoluteEpisode = absoluteEpisode
        self.isSeasonPack = isSeasonPack
        self.episodeTitle = episodeTitle
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.tvdbID = tvdbID
        self.resolution = resolution
        self.source = source
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.hdr = hdr
        self.editions = editions
        self.languages = languages
        self.isProper = isProper
        self.isRepack = isRepack
        self.releaseGroup = releaseGroup
        self.artist = artist
        self.album = album
        self.author = author
        self.documentFormat = documentFormat
        self.provenance = provenance
    }

    /// The pre-parse state a `SearchResult` carries before `SearchAggregator`
    /// runs its parse/enrich stage (§7 staging note). Distinct from a
    /// "parsed but everything absent" result — `mediaKind` is `.other` and
    /// `provenance` is empty either way, but callers should treat this as
    /// "not parsed yet" rather than "parsed as unknown".
    public static let unparsed = ReleaseMetadata()
}
