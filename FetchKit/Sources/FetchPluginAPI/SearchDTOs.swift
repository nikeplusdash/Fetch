import Foundation

/**
 One Torznab/Newznab category — e.g. `2000 Movies`, `5000 TV`.

 Fetch ships `TorznabCategory.standard`, the well-known Newznab top-level
 IDs, and merges in whatever an indexer advertises via `t=caps` (§4, §7).
 */
public struct TorznabCategory: Hashable, Sendable, Codable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

extension TorznabCategory {
    public static let standard: [TorznabCategory] = [
        TorznabCategory(id: 1000, name: "Console"),
        TorznabCategory(id: 2000, name: "Movies"),
        TorznabCategory(id: 3000, name: "Audio"),
        TorznabCategory(id: 4000, name: "PC"),
        TorznabCategory(id: 5000, name: "TV"),
        TorznabCategory(id: 6000, name: "XXX"),
        TorznabCategory(id: 7000, name: "Books"),
        TorznabCategory(id: 8000, name: "Other"),
    ]
}

/**
 What an indexer advertises in `t=caps` — no payload, so it is `Hashable`
 and can live in the `Set` on `ProviderCapabilities`.
 */
public enum SearchModeKind: String, Sendable, Codable, CaseIterable, Hashable {
    case search, tvsearch, movie, music, book
}

/**
 A search request's shape. `.general` is free text; the rest carry the
 structured parameters a Torznab indexer accepts for that mode (§7). Fetch
 derives these from the user's own query text — never from an external
 metadata service.
 */
public enum SearchMode: Sendable, Equatable, Codable {
    case general
    case tv(season: Int?, episode: Int?, tvdbID: Int?)
    case movie(imdbID: String?)
    case music
    case book

    public var kind: SearchModeKind {
        switch self {
        case .general: .search
        case .tv: .tvsearch
        case .movie: .movie
        case .music: .music
        case .book: .book
        }
    }
}

public struct SearchQuery: Sendable, Equatable, Codable {
    public let apiVersion: Int
    public let text: String
    public let mode: SearchMode
    public let categories: [TorznabCategory]
    public let limit: Int
    public let offset: Int

    public init(
        text: String,
        mode: SearchMode = .general,
        categories: [TorznabCategory] = [],
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.apiVersion = currentAPIVersion
        self.text = text
        self.mode = mode
        self.categories = categories
        self.limit = limit
        self.offset = offset
    }
}

/**
 `supportedModes` gates structured search per indexer (§7): an indexer that
 does not advertise `tvsearch` receives the free-text fallback rather than
 parameters it will ignore or reject. `supportedAttributes` is the union of
 every mode's advertised `supportedParams` — the query parameters this
 indexer is documented to accept, not the result attributes it emits (those
 vary per-item and are read directly off each result, see `rawAttributes`).
 */
public struct ProviderCapabilities: Sendable, Equatable, Codable {
    public let apiVersion: Int
    public let categories: [TorznabCategory]
    public let supportedModes: Set<SearchModeKind>
    public let supportedAttributes: Set<String>
    public let maxLimit: Int?

    public init(
        categories: [TorznabCategory],
        supportedModes: Set<SearchModeKind>,
        supportedAttributes: Set<String>,
        maxLimit: Int?
    ) {
        self.apiVersion = currentAPIVersion
        self.categories = categories
        self.supportedModes = supportedModes
        self.supportedAttributes = supportedAttributes
        self.maxLimit = maxLimit
    }
}

/**
 One release from a search provider.

 `InfoHash`/`MagnetLink` live in `FetchKit`, which `FetchPluginAPI` cannot
 import (same reasoning as `CacheEntry.infoHashHex` in `DebridDTOs.swift`)
 — so the boundary carries `infoHashHex` (lowercase 40-char hex) and
 `magnetURI` (a raw `magnet:` string), and `FetchKit` maps them.

 `rawAttributes` carries every `torznab:attr` a provider found verbatim —
 this is what the M2 aggregator unions across duplicate results (see
 `SearchAggregator`) and what M3's attribute merge reads to overlay
 `metadata`.

 `metadata` defaults to `.unparsed` (§8's "deliberately not present yet"
 placeholder from M2) so every existing producer keeps compiling; the
 `SearchAggregator.parse` stage is the only place that is expected to
 populate it for real, by running `ReleaseNameParser` against `title` and
 then overlaying `rawAttributes` via `ReleaseMetadataMerger`.
 */
public struct SearchResult: Sendable, Equatable, Codable, Identifiable {
    public let id: ResultID

    public let candidates: [ResultOrigin]

    public let apiVersion: Int
    public let title: String
    public let size: Int64?
    public let seeders: Int?
    public let peers: Int?
    public let grabs: Int?
    public let fileCount: Int?
    public let category: TorznabCategory?
    public let publishDate: Date?
    public let sources: [SearchProviderID]
    public let sourceKey: String?
    public let rawAttributes: [String: String]
    public let metadata: ReleaseMetadata

    public var infoHashHex: String? { torrentCandidate?.0.hex }

    public var magnetURI: String? { torrentCandidate?.1.raw }

    private var torrentCandidate: (InfoHash, MagnetLink)? {
        for candidate in candidates {
            if case .torrent(let hash, let magnet, _) = candidate { return (hash, magnet) }
        }
        return nil
    }

    public var isUsable: Bool { candidates.contains { $0.isUsable } }

    /**
     The general initialiser: any mix of origins.
     */
    public init(
        candidates: [ResultOrigin],
        title: String,
        size: Int64?,
        seeders: Int?,
        peers: Int?,
        grabs: Int? = nil,
        fileCount: Int? = nil,
        category: TorznabCategory?,
        publishDate: Date?,
        sources: [SearchProviderID],
        sourceKey: String? = nil,
        rawAttributes: [String: String],
        metadata: ReleaseMetadata = .unparsed
    ) {
        let ordered = candidates.enumerated()
            .sorted { ($0.element.preferenceRank, $0.offset) < ($1.element.preferenceRank, $1.offset) }
            .map(\.element)

        self.apiVersion = currentAPIVersion
        self.candidates = ordered
        self.sourceKey = sourceKey
        let identifying = ordered.first { if case .torrent = $0 { true } else { false } }
        if let identifying {
            self.id = ResultID(origin: identifying)
        } else if let sourceKey, !sourceKey.isEmpty {
            self.id = ResultID(sourceKey: sourceKey)
        } else if let first = ordered.first {
            self.id = ResultID(origin: first)
        } else {
            self.id = ResultID(unreachable: title)
        }
        self.title = title
        self.size = size
        self.seeders = seeders
        self.peers = peers
        self.grabs = grabs
        self.fileCount = fileCount
        self.category = category
        self.publishDate = publishDate
        self.sources = sources
        self.rawAttributes = rawAttributes
        self.metadata = metadata
    }

    /**
     The torrent initialiser, unchanged in signature.

     Every Torznab provider and every existing test builds results this way.
     Keeping it means stage 7a adds a capability without touching the path
     that already works — which is the whole point of doing 7a separately.
     */
    public init(
        infoHashHex: String,
        title: String,
        size: Int64,
        seeders: Int,
        peers: Int,
        grabs: Int?,
        fileCount: Int?,
        category: TorznabCategory?,
        publishDate: Date?,
        magnetURI: String,
        sources: [SearchProviderID],
        rawAttributes: [String: String],
        metadata: ReleaseMetadata = .unparsed
    ) {
        let candidates: [ResultOrigin]
        if let hash = InfoHash(infoHashHex), let magnet = MagnetLink(magnetURI) {
            candidates = [.torrent(infoHash: hash, magnet: magnet, targetPath: nil)]
        } else {
            candidates = []
        }

        self.init(
            candidates: candidates, title: title, size: size, seeders: seeders,
            peers: peers, grabs: grabs, fileCount: fileCount, category: category,
            publishDate: publishDate, sources: sources,
            rawAttributes: rawAttributes, metadata: metadata)
    }

    /**
     A copy with `metadata` replaced — used by `SearchAggregator.parse` so
     the pipeline stage doesn't need to re-list every other field.
     */
    public func withMetadata(_ metadata: ReleaseMetadata) -> SearchResult {
        SearchResult(
            candidates: candidates, title: title, size: size, seeders: seeders,
            peers: peers, grabs: grabs, fileCount: fileCount, category: category,
            publishDate: publishDate, sources: sources, sourceKey: sourceKey,
            rawAttributes: rawAttributes, metadata: metadata
        )
    }

    /**
     A copy with `candidates` replaced, for 7d's candidate reordering.

     The init re-sorts by `preferenceRank`, and that is intended: the
     ranking may only reorder candidates *within* a preference tier, never
     promote a `.hosted` above a `.direct`. Since the sort is stable and
     every `.direct` shares rank 0, the format order survives.
     */
    public func withCandidates(
        _ candidates: [ResultOrigin], metadata: ReleaseMetadata? = nil
    ) -> SearchResult {
        SearchResult(
            candidates: candidates, title: title, size: size, seeders: seeders,
            peers: peers, grabs: grabs, fileCount: fileCount, category: category,
            publishDate: publishDate, sources: sources, sourceKey: sourceKey,
            rawAttributes: rawAttributes, metadata: metadata ?? self.metadata
        )
    }
}
