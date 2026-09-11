import Foundation
import FetchPluginAPI

/**
 A Torznab (Jackett/Prowlarr) search indexer.

 Settings accepts the full Torznab base URL, so both shapes work without
 special-casing (§7):
 - Jackett aggregate: `http://localhost:9117/api/v2.0/indexers/all/results/torznab/api`
 - Prowlarr per-indexer: `http://localhost:9696/{id}/api`
 */
public struct TorznabProvider: SearchProvider {
    public let id: SearchProviderID
    public let displayName: String

    private let baseURL: URL
    private let apiKey: Redacted<String>
    private let client: any HTTPClientProtocol
    private let capsStore: TorznabCapsStore

    /**
     `capsStore` defaults to a fresh, private store when not given one, so
     every existing call site and test compiles unchanged and behaves
     exactly as before this store existed — a per-instance store caches
     nothing across searches, same as Task 3's per-instance cache did, but
     nothing regresses for a caller that never shares one. `AppModel`
     passes in a store that outlives a single search, which is the whole
     point of this type.
     */
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


    public func capabilities() async throws -> ProviderCapabilities {
        try await capsStore.capabilities(for: id) { try await fetchCapabilities() }
    }

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


    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        let caps = try await capabilities()
        let resolved = Self.resolveMode(query: query, caps: caps)

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
        items.append(URLQueryItem(
            name: "limit", value: String(min(query.limit, caps.maxLimit ?? query.limit))))
        if query.offset > 0 {
            items.append(URLQueryItem(name: "offset", value: String(query.offset)))
        }

        let endpoint = Endpoint(baseURL: baseURL, path: "", queryItems: items)
        let (data, _) = try await sendRaw(endpoint)

        let categoryNames = Dictionary(
            (TorznabCategory.standard + caps.categories).map { ($0.id, $0.name) },
            uniquingKeysWith: { _, indexerName in indexerName }
        )

        let parsed = try TorznabFeedParser.parseFeed(
            data, providerID: id, categoryNames: categoryNames)
        guard !parsed.unresolved.isEmpty else { return parsed.results }
        let recovered = await TorrentFileResolver.resolve(parsed.unresolved, client: client)
        return parsed.results + recovered
    }


    struct ResolvedQuery {
        let mode: SearchModeKind
        let text: String
        let params: [URLQueryItem]
    }

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
