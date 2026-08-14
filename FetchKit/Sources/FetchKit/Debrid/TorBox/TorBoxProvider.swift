import Foundation
import FetchPluginAPI

public struct TorBoxProvider: DebridProvider {
    public static let providerID = DebridProviderID(rawValue: "torbox")
    public static let providerName = "TorBox"
    public static let reportsCacheStatus = true
    /// Where a user finds their key. Surfaced by Settings' "Get my API key".
    public static let apiKeyPageURL = URL(string: "https://torbox.app/settings")!

    public var id: DebridProviderID { Self.providerID }
    public var displayName: String { Self.providerName }

    public static let defaultBaseURL = URL(string: "https://api.torbox.app")!
    /// GET URL length caps how many hashes fit in one request.
    static let cacheChunkSize = 50
    /// Bounded concurrency keeps a large page well inside 300 req/min.
    static let maxConcurrentChunks = 4

    /// Internal rather than private so `TorBoxWebDownloads` can build the same
    /// requests from the same credentials.
    let transport: DebridTransport

    /// TorBox maps no status service-wide. Its one special case — 500 meaning
    /// "no such id" — is per-call, because a 500 from `createtorrent` is an
    /// outage rather than a missing torrent.
    static let idNotFound: [Int: DebridError] = [500: .fileNotFound]

    public init(
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol,
        baseURL: URL = TorBoxProvider.defaultBaseURL
    ) {
        self.transport = DebridTransport(
            apiKey: apiKey, client: client, baseURL: baseURL)
    }

    // MARK: - Cache

    private struct CachedTorrent: Decodable, Sendable {
        let hash: String
        let name: String?
        let size: Int64?
        let files: [TorBoxFile]?
    }

    struct TorBoxFile: Decodable, Sendable {
        let id: Int
        let name: String
        let short_name: String?
        let size: Int64
        let mimetype: String?

        var asDebridFile: DebridFile {
            DebridFile(
                id: DebridFileID(rawValue: String(id)),
                name: name,
                shortName: short_name ?? (name as NSString).lastPathComponent,
                size: size,
                mimeType: mimetype
            )
        }
    }

    public func checkCached(
        hashes: [String], listFiles: Bool
    ) async throws -> [String: CacheEntry] {
        guard !hashes.isEmpty else { return [:] }

        let normalized = hashes.map { $0.lowercased() }
        let chunks = normalized.chunked(into: Self.cacheChunkSize)

        var merged: [String: CacheEntry] = [:]

        // Bounded concurrency: never more than maxConcurrentChunks in flight.
        var index = 0
        try await withThrowingTaskGroup(of: [String: CacheEntry].self) { group in
            while index < chunks.count && index < Self.maxConcurrentChunks {
                let chunk = chunks[index]
                group.addTask { try await self.fetchChunk(chunk, listFiles: listFiles) }
                index += 1
            }
            while let partial = try await group.next() {
                merged.merge(partial) { current, _ in current }
                if index < chunks.count {
                    let chunk = chunks[index]
                    group.addTask { try await self.fetchChunk(chunk, listFiles: listFiles) }
                    index += 1
                }
            }
        }

        // Absent means "not cached" — fill misses so callers get a total map.
        for hash in normalized where merged[hash] == nil {
            merged[hash] = CacheEntry(infoHashHex: hash, name: "", size: 0, files: nil)
        }
        return merged
    }

    private func fetchChunk(
        _ hashes: [String], listFiles: Bool
    ) async throws -> [String: CacheEntry] {
        var items = hashes.map { URLQueryItem(name: "hash", value: $0) }
        items.append(URLQueryItem(name: "format", value: "object"))
        items.append(URLQueryItem(name: "list_files", value: listFiles ? "true" : "false"))

        let envelope = try await transport.send(
            transport.get("/v1/api/torrents/checkcached", query: items),
            as: TorBoxEnvelope<[String: CachedTorrent]>.self)
        try envelope.requireSuccess()

        var result: [String: CacheEntry] = [:]
        for (key, value) in envelope.data ?? [:] {
            let hash = value.hash.lowercased().isEmpty ? key.lowercased() : value.hash.lowercased()
            result[hash] = CacheEntry(
                infoHashHex: hash,
                name: value.name ?? "",
                size: value.size ?? 0,
                files: value.files?.map(\.asDebridFile)
            )
        }
        return result
    }

    // MARK: - Account

    private struct TorBoxUser: Decodable, Sendable {
        let email: String?
        let plan: Int?
        let premium_expires_at: String?
    }

    public func validateCredentials() async throws -> DebridAccount {
        let envelope = try await transport.send(
            transport.get("/v1/api/user/me"), as: TorBoxEnvelope<TorBoxUser>.self)
        let user = try envelope.requireData()
        return DebridAccount(
            email: user.email,
            plan: user.plan.map { String($0) },
            expiresAt: user.premium_expires_at.flatMap(ISO8601DateFormatter().date(from:))
        )
    }

    // MARK: - Submit

    private struct CreateTorrentResult: Decodable, Sendable {
        let torrent_id: Int?
        let hash: String?
    }

    public func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        // multipart/form-data is what createtorrent expects for the magnet
        // field, and it is never retried — a transient error must not submit
        // the same torrent twice.
        let envelope = try await transport.send(
            transport.multipart(
                "/v1/api/torrents/createtorrent", field: "magnet", value: rawMagnet),
            as: TorBoxEnvelope<CreateTorrentResult>.self)
        try envelope.requireSuccess()
        guard let id = envelope.data?.torrent_id else {
            throw DebridError.providerRejected(detail: envelope.failureDetail)
        }
        return DebridTorrentID(rawValue: String(id))
    }

    // MARK: - Poll

    private struct TorBoxTorrent: Decodable, Sendable {
        let id: Int
        let hash: String?
        let name: String?
        let size: Int64?
        let progress: Double?
        let download_state: DebridTorrentState?
        let download_present: Bool?
        let seeds: Int?
        let download_speed: Double?
        let eta: Double?
        let files: [TorBoxFile]?
    }

    public func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        // VERIFIED AGAINST THE LIVE API: `mylist?id=N` returns data as a
        // SINGLE OBJECT, while `mylist` with no id returns an ARRAY. Decoding
        // this as [TorBoxTorrent] fails at runtime. Do not "simplify" it back.
        //
        // `idNotFound` maps 500 and narrowly 500: that is the verified answer
        // for a nonexistent id. 502/503/504 mean an outage on an existing
        // torrent, and reporting those as fileNotFound would make a poller
        // drop a live download.
        let envelope = try await transport.send(
            transport.get(
                "/v1/api/torrents/mylist",
                query: [
                    URLQueryItem(name: "id", value: id.rawValue),
                    URLQueryItem(name: "bypass_cache", value: "true"),
                ]),
            as: TorBoxEnvelope<TorBoxTorrent>.self,
            extraStatusOverrides: Self.idNotFound)
        let raw = try envelope.requireData()

        return DebridTorrent(
            id: DebridTorrentID(rawValue: String(raw.id)),
            infoHashHex: (raw.hash ?? "").lowercased(),
            name: raw.name ?? "",
            size: raw.size ?? 0,
            progress: raw.progress ?? 0,
            state: raw.download_state ?? .unknown("missing"),
            files: (raw.files ?? []).map(\.asDebridFile),
            seeds: raw.seeds,
            downloadSpeed: raw.download_speed.map { Int64($0) },
            eta: raw.eta,
            // Decoded since this struct was written and never carried across.
            // TorBox flips `download_state` to "uploading" as soon as a
            // finished torrent starts seeding, so a poll waiting for
            // "completed" waits for something that will not come back — the
            // "keeps loading even though it has been queued" half of the
            // report. This is the field that says the files are there.
            filesArePresent: raw.download_present ?? false
        )
    }

    public func files(in id: DebridTorrentID) async throws -> [DebridFile] {
        try await torrent(id: id).files
    }

    // MARK: - Download link

    public func downloadURL(
        torrent: DebridTorrentID, file: DebridFileID
    ) async throws -> URL {
        // requestdl authenticates via `token` query param, NOT a Bearer header.
        // This URL must never be logged or persisted (global constraint).
        let envelope = try await transport.send(
            transport.unauthenticated(
                "/v1/api/torrents/requestdl",
                query: [
                    URLQueryItem(name: "token", value: transport.token),
                    URLQueryItem(name: "torrent_id", value: torrent.rawValue),
                    URLQueryItem(name: "file_id", value: file.rawValue),
                ]),
            as: TorBoxEnvelope<String>.self)
        let raw = try envelope.requireData("no link returned")
        guard let url = URL(string: raw) else {
            throw DebridError.providerRejected(detail: "no link returned")
        }
        return url
    }

    /// `controltorrent` returns no useful payload; this exists only so the
    /// envelope's `success` flag can be decoded and checked.
    private struct TorBoxDeleteResult: Decodable, Sendable {}

    public func delete(torrent: DebridTorrentID) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "torrent_id": Int(torrent.rawValue) ?? 0, "operation": "delete",
        ])
        // TorBox answers 200 with success:false for several conditions, so
        // sendRaw alone would silently report a failed delete as a success.
        let envelope = try await transport.send(
            transport.json("/v1/api/torrents/controltorrent", body: body),
            as: TorBoxEnvelope<TorBoxDeleteResult?>.self)
        try envelope.requireSuccess("delete failed")
    }
}
