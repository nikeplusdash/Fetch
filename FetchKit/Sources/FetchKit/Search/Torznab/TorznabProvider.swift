import Foundation
import FetchPluginAPI

/// A Torznab (Jackett/Prowlarr) search indexer.
///
/// Settings accepts the full Torznab base URL, so both shapes work without
/// special-casing (§7):
/// - Jackett aggregate: `http://localhost:9117/api/v2.0/indexers/all/results/torznab/api`
/// - Prowlarr per-indexer: `http://localhost:9696/{id}/api`
public struct TorznabProvider: SearchProvider {
    public let id: SearchProviderID
    public let displayName: String

    private let baseURL: URL
    private let apiKey: Redacted<String>
    private let client: any HTTPClientProtocol
    private let capsStore: TorznabCapsStore

    /// `capsStore` defaults to a fresh, private store when not given one, so
    /// every existing call site and test compiles unchanged and behaves
    /// exactly as before this store existed — a per-instance store caches
    /// nothing across searches, same as Task 3's per-instance cache did, but
    /// nothing regresses for a caller that never shares one. `AppModel`
    /// passes in a store that outlives a single search, which is the whole
    /// point of this type.
    public init(
        id: SearchProviderID,
        displayName: String,
        baseURL: URL,
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol,
        capsStore: TorznabCapsStore? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.client = client
        self.capsStore = capsStore ?? TorznabCapsStore()
    }

    // MARK: - Capabilities

    public func capabilities() async throws -> ProviderCapabilities {
        try await capsStore.capabilities(for: id) { try await fetchCapabilities() }
    }

    /// The uncached `t=caps` round trip. Mandatory in the Torznab spec, so
    /// this is safe to depend on for mode gating.
    private func fetchCapabilities() async throws -> ProviderCapabilities {
        let endpoint = Endpoint(
            baseURL: baseURL,
            path: "",
            queryItems: [
                URLQueryItem(name: "t", value: "caps"),
                URLQueryItem(name: "apikey", value: apiKey.exposedValue),
            ]
        )
        let (data, _) = try await sendRaw(endpoint)
        return try TorznabCapsParser.parse(data)
    }

    // `participates(in:)` is not overridden here: this type's `capabilities()`
    // is exactly `SearchProvider`'s default implementation's dependency, so
    // the inherited default (`ExtensionPoints.swift`) already does the right
    // thing — a second copy of the same wrapping logic around
    // `CategoryIntersection.resolve` would only be a place for the two to
    // drift.

    // MARK: - Search

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        let caps = try await capabilities()
        let resolved = Self.resolveMode(query: query, caps: caps)

        // Always `extended=1` — many indexers return only a minimal
        // attribute set without it, silently degrading everything
        // downstream (§7).
        var items: [URLQueryItem] = [
            URLQueryItem(name: "t", value: resolved.mode.rawValue),
            URLQueryItem(name: "apikey", value: apiKey.exposedValue),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "q", value: resolved.text),
        ]
        items.append(contentsOf: resolved.params)

        switch CategoryIntersection.resolve(
            requested: query.categories, advertised: caps.categories)
        {
        case .skip:
            // An empty success, not a failure: this indexer does not carry
            // what was asked for, which is not an error to report.
            return []
        case .sendVerbatim:
            if !query.categories.isEmpty {
                let ids = query.categories.map { String($0.id) }.joined(separator: ",")
                items.append(URLQueryItem(name: "cat", value: ids))
            }
        case .send(let ids):
            items.append(URLQueryItem(
                name: "cat", value: ids.map(String.init).joined(separator: ",")))
        }
        // Clamped to what this indexer says it will serve. Asking past an
        // advertised maximum is at best ignored and at worst rejected, and the
        // number is right there in `t=caps` — `<limits default max>` — which
        // Fetch has parsed since M2 and never used for anything.
        //
        // **This is what a non-paging indexer needs.** Measured against the
        // reporting install's Jackett `/all/` aggregate: `offset=50` returns an
        // empty feed in 21ms (it does not implement offset at all), while
        // `limit` is honoured to its advertised 1000 — and a query costs the
        // same ~14s whether it asks for 50 results or 473, because the cost is
        // fanning out to the indexers behind it, not the size of the reply. So
        // for a source that cannot page, asking small is pure loss: the app
        // requested 50, showed those, and left 423 results the indexer had
        // already found sitting on the floor.
        items.append(URLQueryItem(
            name: "limit", value: String(min(query.limit, caps.maxLimit ?? query.limit))))
        if query.offset > 0 {
            items.append(URLQueryItem(name: "offset", value: String(query.offset)))
        }

        let endpoint = Endpoint(baseURL: baseURL, path: "", queryItems: items)
        let (data, _) = try await sendRaw(endpoint)

        // Fetch's static table plus whatever this indexer's caps advertised;
        // caps wins on conflict since it's this indexer's own declaration.
        let categoryNames = Dictionary(
            (TorznabCategory.standard + caps.categories).map { ($0.id, $0.name) },
            uniquingKeysWith: { _, indexerName in indexerName }
        )

        let parsed = try TorznabFeedParser.parseFeed(
            data, providerID: id, categoryNames: categoryNames)
        guard !parsed.unresolved.isEmpty else { return parsed.results }
        // **A tracker that needs a login publishes no magnet.** Verified: the
        // one RuTracker result for "3 Body Problem" carries no `magneturl` and
        // no `infohash`, only a `/dl/rutracker/…` URL — so it was dropped, and
        // the release the user was looking for was missing from a search that
        // found nine other things. The `.torrent` behind that URL has the hash;
        // `TorrentFileResolver` fetches it, bounded, and the item becomes an
        // ordinary result with a cache badge and a file picker like any other.
        let recovered = await TorrentFileResolver.resolve(parsed.unresolved, client: client)
        return parsed.results + recovered
    }

    // MARK: - Mode resolution

    struct ResolvedQuery {
        let mode: SearchModeKind
        let text: String
        let params: [URLQueryItem]
    }

    /// Maps `SearchQuery.mode` onto the parameters table from §7, gated by
    /// what this indexer's `t=caps` actually advertises — an indexer that
    /// does not advertise a mode gets the free-text fallback rather than
    /// parameters it will ignore or reject.
    ///
    /// `.general` additionally tries to recognize a season/episode pattern in
    /// the query text itself (`SeasonEpisodeQueryParser`), so typing
    /// `"The Expanse S03E05"` reaches `t=tvsearch` on indexers that support
    /// it, with no external metadata lookup.
    static func resolveMode(query: SearchQuery, caps: ProviderCapabilities) -> ResolvedQuery {
        switch query.mode {
        case .general:
            let extraction = SeasonEpisodeQueryParser.extract(from: query.text)
            if let season = extraction.season, let episode = extraction.episode,
               caps.supportedModes.contains(.tvsearch) {
                return ResolvedQuery(
                    mode: .tvsearch,
                    text: extraction.title,
                    params: [
                        URLQueryItem(name: "season", value: String(season)),
                        URLQueryItem(name: "ep", value: String(episode)),
                    ]
                )
            }
            // No recognizable pattern, or the indexer doesn't do tvsearch:
            // plain search with the ORIGINAL, unstripped text.
            return ResolvedQuery(mode: .search, text: query.text, params: [])

        case .tv(let season, let episode, let tvdbID):
            guard caps.supportedModes.contains(.tvsearch) else {
                return ResolvedQuery(mode: .search, text: query.text, params: [])
            }
            var params: [URLQueryItem] = []
            if let season { params.append(URLQueryItem(name: "season", value: String(season))) }
            if let episode { params.append(URLQueryItem(name: "ep", value: String(episode))) }
            if let tvdbID { params.append(URLQueryItem(name: "tvdbid", value: String(tvdbID))) }
            return ResolvedQuery(mode: .tvsearch, text: query.text, params: params)

        case .movie(let imdbID):
            guard caps.supportedModes.contains(.movie) else {
                return ResolvedQuery(mode: .search, text: query.text, params: [])
            }
            var params: [URLQueryItem] = []
            if let imdbID { params.append(URLQueryItem(name: "imdbid", value: imdbID)) }
            return ResolvedQuery(mode: .movie, text: query.text, params: params)

        case .music:
            let mode: SearchModeKind = caps.supportedModes.contains(.music) ? .music : .search
            return ResolvedQuery(mode: mode, text: query.text, params: [])

        case .book:
            let mode: SearchModeKind = caps.supportedModes.contains(.book) ? .book : .search
            return ResolvedQuery(mode: mode, text: query.text, params: [])
        }
    }

    // MARK: - Errors

    /// Torznab's web-UI roots answer `200` with an HTML login page (Prowlarr)
    /// rather than an error, so a status check alone lets HTML reach
    /// `XMLParser`, which reduces it to `NSXMLParserErrorDomain Code=76` —
    /// indistinguishable from an indexer genuinely sending bad XML. Catch it
    /// here, where the URL that produced it is still in hand.
    private func sendRaw(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await client.sendRaw(endpoint)
            if TorznabEndpoint.looksLikeHTML(data) {
                throw SearchError.notATorznabEndpoint(tried: [baseURL.absoluteString])
            }
            return (data, response)
        } catch let error as NetworkError {
            throw Self.mapNetworkError(error)
        }
    }

    static func mapNetworkError(_ error: NetworkError) -> SearchError {
        switch error {
        case .http(let status, _) where status == 401 || status == 403:
            return .unauthorized
        case .invalidURL:
            return .invalidEndpoint
        default:
            return .network(error)
        }
    }
}
