import Foundation
import FetchPluginAPI

/// Internet Archive — the first source that needs no debrid, no account, and
/// no key (amendment §6.2).
///
/// This is the honest proof of stage 7a. If an IA result downloads with every
/// debrid removed, `.direct` genuinely works rather than being a code path
/// that happens to compile.
///
/// Deliberately *not* Torznab. IA has a documented public JSON API, so parsing
/// its own shape is both simpler and far more stable than pretending it is a
/// tracker.
public struct InternetArchiveProvider: SearchProvider {
    /// Static so `ResultPresentation` can match a result to its source
    /// without constructing a provider.
    public static let providerID = SearchProviderID(rawValue: "internet-archive")
    public var id: SearchProviderID { Self.providerID }
    public let displayName = "Internet Archive"

    public static let host = "archive.org"
    private static let base = URL(string: "https://archive.org")!

    private let client: any HTTPClientProtocol

    public init(client: any HTTPClientProtocol = HTTPClient()) {
        self.client = client
    }

    /// No key, no round trip. A Torznab indexer cannot answer this without
    /// talking to its server; IA's answer is a constant, and spending a
    /// request on it would cost every search a needless hop.
    public func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            categories: [],
            supportedModes: [.search],
            supportedAttributes: [],
            // IA caps a page at 10,000 rows; Fetch never asks for near that,
            // so this documents the ceiling rather than constraining anything.
            maxLimit: 10_000)
    }

    // MARK: - Search

    /// What one search will ask archive.org for, however large a page the
    /// caller wants. Offset paging works here, so the tail stays reachable by
    /// scrolling rather than by one enormous request.
    static let maxRowsPerSearch = 100

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var components = URLComponents(
            url: Self.base.appendingPathComponent("advancedsearch.php"),
            resolvingAgainstBaseURL: false)!

        // Title-scoped and quoted. A bare `q=dune` is expanded by IA into
        // `text:dune OR text__reviews:dune`, which returns podcast episodes
        // that merely *mention* the word ahead of the book.
        //
        // The category clause is AND-ed onto that same expression rather than
        // sent as a separate parameter: IA's advancedsearch has one query
        // field, and `fl[]`/`sort[]` are not filters.
        var lucene = "title:(\"\(Self.escape(text))\")"
        if let mediatype = Self.mediatype(for: query.categories) {
            lucene += " AND mediatype:(\(mediatype))"
        }

        var items = [
            URLQueryItem(name: "q", value: lucene),
            // Clamped, unlike the Torznab path which asks for whatever the
            // indexer advertises. Archive.org is a keyless public service run
            // by a charity, and the page ceiling it *permits* (10,000) is not
            // an invitation — a search box has no business asking a free API
            // for five hundred rows when nobody scrolls past the first fifty.
            URLQueryItem(name: "rows", value: String(min(query.limit, Self.maxRowsPerSearch))),
            URLQueryItem(name: "page", value: String(query.offset / max(query.limit, 1) + 1)),
            URLQueryItem(name: "output", value: "json"),
            // Downloads, not IA's relevance score: relevance alone surfaces
            // obscure uploads above the canonical copy of the same work.
            URLQueryItem(name: "sort[]", value: "downloads desc"),
        ]
        for field in ["identifier", "title", "mediatype", "item_size",
                      "creator", "year", "downloads"] {
            items.append(URLQueryItem(name: "fl[]", value: field))
        }
        components.queryItems = items

        let endpoint = Endpoint(baseURL: components.url!, path: "")
        let response: SearchResponse = try await client.send(endpoint, as: SearchResponse.self)

        return response.response.docs.compactMap(result(from:))
    }

    /// Lucene special characters would otherwise turn a user's colon or quote
    /// into query syntax and either error or silently search for the wrong
    /// thing.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// IA's own vocabulary for the requested category.
    ///
    /// Derived from the Torznab IDs the query carries rather than from a
    /// `SearchCategory` parameter, because `SearchQuery` is the plugin
    /// boundary's type and adding a Fetch-specific enum to it would push an
    /// app concept across that boundary.
    ///
    /// This is the mapping's only home — `SearchCategory` does not keep its
    /// own copy, so there is nothing else to drift.
    ///
    /// Assumes `categories` came from a single pill, as every caller today
    /// guarantees. If IDs from two different pills were ever mixed, the first
    /// bucket found below wins; that case is unreached, not handled.
    static func mediatype(for categories: [TorznabCategory]) -> String? {
        guard !categories.isEmpty else { return nil }
        let ids = Set(categories.map { $0.id / 1000 * 1000 })
        // Anime (5070) deliberately yields nothing: its only plausible IA
        // mediatype is `movies`, which would return live-action films.
        if categories.contains(where: { $0.id == 5070 }) { return nil }
        if ids.contains(7000) { return "texts" }
        if ids.contains(3000) { return "audio" }
        if ids.contains(2000) || ids.contains(5000) { return "movies" }
        if ids.contains(4000) || ids.contains(1000) { return "software" }
        return nil
    }

    private func result(from doc: Doc) -> SearchResult? {
        guard !doc.identifier.isEmpty else { return nil }

        // The item's details page. The real file URLs need the second
        // `metadata` call, which is made only when the user opens the item —
        // 50 results must not mean 50 extra round trips for candidates
        // nobody opens (§6.2).
        let url = Self.base
            .appendingPathComponent("details")
            .appendingPathComponent(doc.identifier)

        var metadata = ReleaseMetadata.unparsed
        metadata.mediaKind = Self.mediaKind(doc.mediatype)
        metadata.title = doc.title
        metadata.year = doc.year
        metadata.provenance = [.title: .attribute, .mediaKind: .attribute]
        if doc.year != nil { metadata.provenance[.year] = .attribute }

        var attributes = ["identifier": doc.identifier]
        if let creator = doc.creator { attributes["creator"] = creator }
        if let downloads = doc.downloads { attributes["downloads"] = String(downloads) }

        return SearchResult(
            candidates: [.direct(url: url)],
            title: doc.title ?? doc.identifier,
            // IA reports the whole *item*, which is a folder. Kept because it
            // is the only size available before the file list is fetched.
            size: doc.item_size,
            // Absent, not zero: a book is not a torrent nobody is seeding.
            seeders: nil,
            peers: nil,
            // The item's download count, in the typed field the ranking
            // reads — see `GutenbergProvider` for why the raw attribute
            // alone was not enough.
            grabs: doc.downloads,
            category: nil,
            publishDate: nil,
            sources: [id],
            // IA's identifier, which is already the item's identity
            // everywhere else — `ItemFolder` names the download directory
            // after it.
            sourceKey: "internet-archive:\(doc.identifier)",
            rawAttributes: attributes,
            metadata: metadata)
    }

    /// IA's own vocabulary, mapped onto §8's `MediaKind` so IA results rank
    /// and route through the same machinery as everything else.
    static func mediaKind(_ mediatype: String?) -> MediaKind {
        switch mediatype {
        case "texts":    .book
        case "audio":    .music
        case "movies":   .movie
        case "software": .software
        // `.other` rather than `.unknown(_)`: IA told us its mediatype, so
        // this is a kind Fetch does not model, not a missing answer.
        default:         .other
        }
    }

    // MARK: - Item contents

    /// One file inside an IA item.
    public struct ItemFile: Sendable, Equatable {
        public let name: String
        public let format: String?
        /// Nil when IA did not report one. `Content-Length` settles it at
        /// download time; 0 would make a progress bar claim completion before
        /// a byte arrived.
        public let size: Int64?
        public let url: URL
        /// Generated by Archive.org from an upload rather than uploaded.
        ///
        /// Kept and flagged rather than dropped: an h.264 `.mp4` beside a
        /// `.mkv` is frequently the copy a user actually wants, because it
        /// plays anywhere. The UI defaults to hiding these so a picker is not
        /// every episode twice, and offers them behind a toggle.
        public let isDerived: Bool
    }

    /// The item's real, downloadable files.
    ///
    /// Fetched on selection rather than per search hit — this is the second
    /// call §6.2 keeps off the search path.
    public func files(inItem identifier: String) async throws -> [ItemFile] {
        try await metadata(of: identifier).files.compactMap { file in
            guard Self.isUserFacing(file), let url = Self.downloadURL(identifier, file.name)
            else { return nil }
            return ItemFile(
                name: file.name, format: file.format,
                size: file.size.flatMap(Int64.init), url: url,
                isDerived: file.source == "derivative")
        }
    }

    /// The item's own `.torrent`, when it has one.
    ///
    /// Verified live on 2026-08-02: archive.org generates `<id>_archive.torrent`
    /// for every item, carrying webseeds back to IA's own servers. That makes
    /// an IA item genuinely multi-candidate — a debrid that already holds it
    /// serves the file at CDN speed instead of through IA's rate limiting.
    ///
    /// Fetching this file is plain HTTPS to one host: no DHT, no peers, no
    /// announce. Any swarm participation is the debrid's, which is the point
    /// of a debrid.
    public func torrentURL(forItem identifier: String) async throws -> URL? {
        let files = try await metadata(of: identifier).files
        guard let torrent = files.first(where: { $0.name.hasSuffix(".torrent") })
        else { return nil }
        return Self.downloadURL(identifier, torrent.name)
    }

    private func metadata(of identifier: String) async throws -> MetadataResponse {
        let url = Self.base
            .appendingPathComponent("metadata")
            .appendingPathComponent(identifier)
        return try await client.send(
            Endpoint(baseURL: url, path: ""), as: MetadataResponse.self)
    }

    /// An IA item is a **folder tree**, not a flat list: a 1,786-episode
    /// collection stores files as `Show/Season 01/Ep.mkv`. So nesting is
    /// normal and must be preserved.
    ///
    /// What is rejected is escaping: a `..` component or an absolute path
    /// would put the download somewhere the item does not own. The name is
    /// remote data and this is where it stops being trusted — but the check
    /// is on the *components*, not on whether the string contains a slash.
    private static func downloadURL(_ identifier: String, _ name: String) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\") else { return nil }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != ".." && $0 != "." && !$0.isEmpty })
        else { return nil }

        var url = base
            .appendingPathComponent("download")
            .appendingPathComponent(identifier)
        for component in components {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// Whether a file belongs in a picker at all.
    ///
    /// Two different things hide under "derivative". An h.264 `.mp4` next to
    /// the uploaded `.mkv` is a **real alternative** and often the one wanted,
    /// since it plays anywhere — those are kept and flagged. Thumbnail strips,
    /// spectrograms and waveform peaks are not alternatives; on the item that
    /// exposed this they outnumbered the episodes two to one.
    ///
    /// A file with no `source` is kept. IA sets it on everything today, but an
    /// absent field must not silently empty the picker.
    private static func isUserFacing(_ file: MetadataFile) -> Bool {
        // The item's own bookkeeping, which IA still marks `original`.
        if file.name.hasPrefix("__") { return false }
        if file.source == "metadata" { return false }

        switch file.format {
        case "Metadata", "Item Tile", "Archive BitTorrent", "JSON", "Item Image",
             "Thumbnail", "Spectrogram", "Columbia Peaks", "Animated GIF",
             "Waveform", "PNG Thumb", "Cover Thumb":
            return false
        default:
            return true
        }
    }

    // MARK: - Wire shapes

    private struct SearchResponse: Decodable, Sendable {
        let response: Inner
        struct Inner: Decodable, Sendable { let docs: [Doc] }
    }

    struct Doc: Decodable, Sendable {
        let identifier: String
        let title: String?
        let mediatype: String?
        let item_size: Int64?
        let creator: String?
        let year: Int?
        let downloads: Int?

        // `creator` is sometimes a list and `year` sometimes a string; IA is
        // not strict about either, and a strict decoder would drop otherwise
        // perfectly good results.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try c.decode(String.self, forKey: .identifier)
            title = try? c.decode(String.self, forKey: .title)
            mediatype = try? c.decode(String.self, forKey: .mediatype)
            item_size = try? c.decode(Int64.self, forKey: .item_size)
            downloads = try? c.decode(Int.self, forKey: .downloads)

            if let one = try? c.decode(String.self, forKey: .creator) {
                creator = one
            } else {
                creator = (try? c.decode([String].self, forKey: .creator))?.first
            }
            if let n = try? c.decode(Int.self, forKey: .year) {
                year = n
            } else {
                year = (try? c.decode(String.self, forKey: .year)).flatMap(Int.init)
            }
        }

        enum CodingKeys: String, CodingKey {
            case identifier, title, mediatype, item_size, creator, year, downloads
        }
    }

    private struct MetadataResponse: Decodable, Sendable {
        let files: [MetadataFile]
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            files = (try? c.decode([MetadataFile].self, forKey: .files)) ?? []
        }
        enum CodingKeys: String, CodingKey { case files }
    }

    /// `size` is a **string** in IA's metadata, and absent for some derived
    /// files.
    private struct MetadataFile: Decodable, Sendable {
        let name: String
        let format: String?
        let size: String?
        /// `original`, `derivative`, or `metadata` — IA's own statement of
        /// what the uploader supplied versus what IA generated.
        let source: String?
    }
}
