import Foundation
import FetchPluginAPI

/// Premiumize.me.
///
/// **Not verified against the live API.** Written from the published docs at
/// `premiumize.me/api`; the TorBox implementation carries "VERIFIED AGAINST THE
/// LIVE API" notes precisely because response shapes surprise you. Anything
/// here marked *documented* has not been exercised against a real account.
///
/// **How it differs from TorBox.** Premiumize is folder-based rather than
/// torrent-based: a transfer produces a folder, and files are listed from that
/// folder. The one genuine advantage is `/transfer/directdl`, which returns
/// direct links for *cached* content **without creating a transfer** — a real
/// side-effect-free preview, which is exactly the role
/// `checkCached(listFiles: true)` plays for TorBox (§6).
public struct PremiumizeProvider: SynchronousHostedLinks {
    public static let providerID = DebridProviderID(rawValue: "premiumize")
    public static let providerName = "Premiumize"
    public static let reportsCacheStatus = true
    /// Where a user finds their key. Surfaced by Settings' "Get my API key".
    public static let apiKeyPageURL = URL(string: "https://www.premiumize.me/account")!

    public var id: DebridProviderID { Self.providerID }
    public var displayName: String { Self.providerName }

    public static let defaultBaseURL = URL(string: "https://www.premiumize.me/api")!

    /// `/cache/check` takes repeated `items[]` params; keep a request well
    /// inside a sane URL length.
    static let cacheChunkSize = 50

    /// Internal rather than private so `PremiumizeWebDownloads` can build the
    /// same requests from the same credentials.
    let transport: DebridTransport

    public init(
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol,
        baseURL: URL = PremiumizeProvider.defaultBaseURL
    ) {
        // No status overrides: unlike Real-Debrid, Premiumize gives 404 no
        // meaning beyond a transport failure.
        self.transport = DebridTransport(
            apiKey: apiKey, client: client, baseURL: baseURL)
    }

    // MARK: - Cache

    /// Documented shape: parallel arrays, one entry per requested hash, in the
    /// order requested. `filename`/`filesize` are null for a miss.
    private struct CacheCheckResponse: Decodable, Sendable {
        let status: String
        let response: [Bool]?
        let filename: [String?]?
        let filesize: [PremiumizeSize?]?
        let message: String?
    }

    public func checkCached(
        hashes: [String], listFiles: Bool
    ) async throws -> [String: CacheEntry] {
        guard !hashes.isEmpty else { return [:] }

        let normalized = hashes.map { $0.lowercased() }
        var merged: [String: CacheEntry] = [:]

        // Serially, unlike TorBox's 4-way concurrent loop. Keep it that way:
        // making these concurrent changes how hard Fetch hits the service.
        for chunk in normalized.chunked(into: Self.cacheChunkSize) {
            merged.merge(try await checkChunk(chunk)) { current, _ in current }
        }

        // Total over its input, matching `TorBoxProvider.checkCached`: a caller
        // gets an entry for every hash it asked about, hit or miss.
        for hash in normalized where merged[hash] == nil {
            merged[hash] = CacheEntry(infoHashHex: hash, name: "", size: 0, files: nil)
        }
        return merged
    }

    private func checkChunk(_ hashes: [String]) async throws -> [String: CacheEntry] {
        let response = try await transport.send(
            transport.get(
                "cache/check",
                query: hashes.map { URLQueryItem(name: "items[]", value: $0) }),
            as: CacheCheckResponse.self)
        guard response.status == "success", let flags = response.response else {
            throw DebridError.providerRejected(detail: response.message ?? "cache/check failed")
        }

        var result: [String: CacheEntry] = [:]
        for (index, hash) in hashes.enumerated() {
            // Defensive: a short `response` array would otherwise trap. Treat a
            // missing flag as a miss rather than crashing on a provider change.
            guard index < flags.count, flags[index] else { continue }
            result[hash] = CacheEntry(
                infoHashHex: hash,
                name: response.filename?.indexIfPresent(index)?.flatMap { $0 } ?? "",
                size: response.filesize?.indexIfPresent(index)??.value ?? 0,
                // `/cache/check` carries no file list; `directdl` is what
                // provides one, and only when a caller actually wants it.
                files: nil
            )
        }
        return result
    }

    // MARK: - Account

    private struct AccountInfo: Decodable, Sendable {
        let status: String
        let customer_id: PremiumizeSize?
        let premium_until: Double?
        let limit_used: Double?
    }

    public func validateCredentials() async throws -> DebridAccount {
        let info = try await transport.send(
            transport.get("account/info"), as: AccountInfo.self)
        guard info.status == "success" else {
            throw DebridError.providerRejected(detail: "account/info failed")
        }
        return DebridAccount(
            // Premiumize does not return an email on this endpoint; the
            // customer id is the only stable identifier it offers.
            email: info.customer_id.map { String($0.value) },
            plan: info.premium_until != nil ? "premium" : "free",
            expiresAt: info.premium_until.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - Transfers

    private struct CreateResponse: Decodable, Sendable {
        let status: String
        let id: String?
        let name: String?
        let message: String?
    }

    public func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        let response = try await transport.send(
            transport.form(
                .post, "transfer/create",
                fields: [URLQueryItem(name: "src", value: rawMagnet)],
                // never re-submit a transfer on a transient error
                isRetryable: false),
            as: CreateResponse.self)
        guard response.status == "success", let id = response.id else {
            throw DebridError.providerRejected(detail: response.message ?? "transfer/create failed")
        }
        return DebridTorrentID(rawValue: id)
    }

    private struct TransferList: Decodable, Sendable {
        struct Transfer: Decodable, Sendable {
            let id: String
            let name: String?
            let status: String?
            let progress: Double?
            let folder_id: String?
            let file_id: String?
        }
        let status: String
        let transfers: [Transfer]?
    }

    public func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        let list = try await transport.send(
            transport.get("transfer/list"), as: TransferList.self)
        guard list.status == "success" else {
            throw DebridError.providerRejected(detail: "transfer/list failed")
        }
        // Premiumize has no per-id transfer endpoint, so this filters the list.
        guard let transfer = list.transfers?.first(where: { $0.id == id.rawValue }) else {
            throw DebridError.fileNotFound
        }

        // **This was `transfer.folder_id.map { _ in [DebridFile]() } ?? []`** —
        // which maps a present folder id to an *empty* array, always. So a
        // Premiumize torrent reported no files however finished it was, and
        // `DebridTorrent.isReady` requires a non-empty list: the poll never
        // ended, the row sat preparing for good, and nothing was ever queued.
        // The file list was one call away the whole time — `files(in:)` has
        // fetched it since the provider was written.
        //
        // Only once the transfer has a folder. Asking for one mid-transfer is
        // a round trip per poll for an answer that is not ready yet.
        var files: [DebridFile] = []
        if Self.state(from: transfer.status).isReady {
            if let folder = transfer.folder_id {
                // The *folder* id, not the transfer id. `files(in:)` takes a
                // `DebridTorrentID` and hands it to `folder/list`, which is a
                // long-standing type abuse in this provider — the two ids are
                // different things and Premiumize numbers them separately.
                files = (try? await self.files(in: DebridTorrentID(rawValue: folder))) ?? []
            } else if let single = transfer.file_id {
                // A single-file transfer has no folder. This is the commonest
                // shape there is — a book, one track — and `file_id` sat
                // decoded and unread, so every one of them reported nothing.
                files = [try? await self.file(withID: single)].compactMap { $0 }
            }
        }
        return DebridTorrent(
            id: id,
            // The transfer record does not carry the info hash back.
            infoHashHex: "",
            name: transfer.name ?? "",
            size: 0,
            progress: transfer.progress ?? 0,
            state: Self.state(from: transfer.status),
            files: files,
            seeds: nil, downloadSpeed: nil, eta: nil,
            // Premiumize says "finished" and means it: the folder exists and
            // its contents are servable. Without this the readiness check
            // leans entirely on `files`, which is a second round trip away.
            filesArePresent: (transfer.folder_id != nil || transfer.file_id != nil)
                && Self.state(from: transfer.status).isReady
        )
    }

    /// Documented statuses: waiting, queued, running, seeding, finished, error,
    /// timeout. Anything unrecognized round-trips as `.unknown` rather than
    /// being forced into a nearby case.
    static func state(from raw: String?) -> DebridTorrentState {
        switch raw?.lowercased() {
        case "waiting", "queued": .queued
        case "running": .downloading
        case "seeding": .uploading
        case "finished": .completed
        case "error", "timeout": .failed(reason: raw ?? "error")
        case let other?: .unknown(other)
        case nil: .unknown("missing")
        }
    }

    // MARK: - Files and links

    /// Documented: returns direct links for cached content **without creating a
    /// transfer**. This is both the file list and the download link source, so
    /// unlike TorBox there is no separate `requestdl` step.
    struct DirectDL: Decodable, Sendable {
        struct Content: Decodable, Sendable {
            let path: String?
            let size: PremiumizeSize?
            let link: String?
            let stream_link: String?
        }
        let status: String
        let content: [Content]?
        let message: String?
    }

    /// The side-effect-free preview (§6), satisfying `DebridProvider`.
    ///
    /// Takes a magnet rather than a hash because `directdl` accepts a magnet —
    /// and `/cache/check` returns no file list at all, so this is the only way
    /// Premiumize can preview.
    /// A preview, or nil when this service cannot give one.
    ///
    /// **A refusal is an answer, not a failure.** Premiumize replies
    /// "Unsupported link for direct download." to `transfer/directdl` for a
    /// magnet it does not already hold — which is not an error, it is
    /// Premiumize saying it cannot list a torrent it has not got. Rethrowing
    /// it put that sentence on screen in place of the file picker, when the
    /// caller has a perfectly good fallback: the torrent's own metadata, over
    /// plain HTTPS, with no account involved.
    ///
    /// `unauthorized` still propagates. A bad key is the user's problem to
    /// fix and must not be quietly downgraded to "no preview available".
    public func previewFiles(
        rawMagnet: String, infoHashHex: String
    ) async throws -> [DebridFile]? {
        do {
            let files = try await previewFiles(rawMagnet: rawMagnet)
            return files.isEmpty ? nil : files
        } catch DebridError.providerRejected {
            return nil
        }
    }

    public func previewFiles(rawMagnet: String) async throws -> [DebridFile] {
        try await directDL(rawMagnet: rawMagnet).enumerated().map { index, content in
            let path = content.path ?? "file-\(index)"
            return DebridFile(
                // `directdl` has no stable file id, so the index within the
                // response stands in. Selection is re-resolved by path anyway
                // (§6, "Two kinds of file list"), which is what makes this safe.
                id: DebridFileID(rawValue: String(index)),
                name: path,
                shortName: (path as NSString).lastPathComponent,
                size: content.size?.value ?? 0,
                mimeType: nil
            )
        }
    }

    /// Deliberately **not** merged with `directDownloadLink(for:)`, which
    /// POSTs the same path with the same `src` field: this one is retryable
    /// and decodes sizes leniently through `PremiumizeSize`, that one is not
    /// retryable and decodes `size: Int64?`. Merging them would change retry
    /// behaviour on the magnet-preview path.
    func directDL(rawMagnet: String) async throws -> [DirectDL.Content] {
        let response = try await transport.send(
            transport.form(
                .post, "transfer/directdl",
                fields: [URLQueryItem(name: "src", value: rawMagnet)]),
            as: DirectDL.self)
        guard response.status == "success" else {
            throw DebridError.providerRejected(detail: response.message ?? "directdl failed")
        }
        return response.content ?? []
    }

    private struct FolderList: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let id: String
            let name: String
            let size: PremiumizeSize?
            let link: String?
            let type: String?
        }
        let status: String
        let content: [Item]?
    }

    /// Every file under a folder, with its path relative to that folder.
    ///
    /// **It used to filter folders out rather than descend into them**, so a
    /// torrent with any directory structure listed only its subfolders,
    /// matched none of them against `type != "folder"`, and returned nothing —
    /// which the engine reads as "not ready yet" and polls for ever.
    ///
    /// Paths are joined with `/` because that is what every other list Fetch
    /// joins against uses: a `.torrent`'s own metadata, TorBox's names, and
    /// the selection the user made in the picker. A bare filename here would
    /// match nothing for a season pack.
    public func files(in id: DebridTorrentID) async throws -> [DebridFile] {
        try await files(inFolder: id.rawValue, prefix: "", depth: 0)
    }

    /// Premiumize nests as deeply as the torrent does. The cap is a
    /// backstop against a cycle in someone else's data, not a real limit —
    /// nothing legitimate is eight folders deep.
    private static let maxFolderDepth = 8

    private func files(
        inFolder folder: String, prefix: String, depth: Int
    ) async throws -> [DebridFile] {
        let list = try await transport.send(
            transport.get(
                "folder/list", query: [URLQueryItem(name: "id", value: folder)]),
            as: FolderList.self)
        guard list.status == "success" else {
            throw DebridError.providerRejected(detail: "folder/list failed")
        }

        var files: [DebridFile] = []
        for item in list.content ?? [] {
            let path = prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"
            if item.type == "folder" {
                guard depth < Self.maxFolderDepth else { continue }
                files += try await self.files(
                    inFolder: item.id, prefix: path, depth: depth + 1)
            } else {
                files.append(DebridFile(
                    id: DebridFileID(rawValue: item.id), name: path,
                    shortName: (item.name as NSString).lastPathComponent,
                    size: item.size?.value ?? 0, mimeType: nil))
            }
        }
        return files
    }

    /// The one file a single-file transfer produced.
    ///
    /// Premiumize sets `file_id` and leaves `folder_id` nil for these, and
    /// `file_id` was decoded and never read — so a one-file torrent (a book,
    /// a single album track) reported no files at all and its row polled for
    /// ever. It is the commonest shape there is.
    private func file(withID id: String) async throws -> DebridFile? {
        struct Details: Decodable, Sendable {
            let status: String
            let name: String?
            let size: Int64?
        }
        let details = try await transport.send(
            transport.get("item/details", query: [URLQueryItem(name: "id", value: id)]),
            as: Details.self)
        guard details.status == "success", let name = details.name else { return nil }
        return DebridFile(
            id: DebridFileID(rawValue: id), name: name,
            shortName: (name as NSString).lastPathComponent,
            size: details.size ?? 0, mimeType: nil)
    }

    /// Premiumize hands out the direct link with the listing rather than
    /// minting one per request, so this re-lists and picks the file out.
    public func downloadURL(
        torrent: DebridTorrentID, file: DebridFileID
    ) async throws -> URL {
        struct Details: Decodable, Sendable {
            let status: String
            let link: String?
        }
        let details = try await transport.send(
            transport.get(
                "item/details", query: [URLQueryItem(name: "id", value: file.rawValue)]),
            as: Details.self)
        guard details.status == "success", let raw = details.link, let url = URL(string: raw) else {
            throw DebridError.providerRejected(detail: "no link returned")
        }
        return url
    }

    public func delete(torrent: DebridTorrentID) async throws {
        struct Ack: Decodable, Sendable { let status: String; let message: String? }
        let ack = try await transport.send(
            transport.form(
                .post, "transfer/delete",
                fields: [URLQueryItem(name: "id", value: torrent.rawValue)],
                isRetryable: false),
            as: Ack.self)
        guard ack.status == "success" else {
            throw DebridError.providerRejected(detail: ack.message ?? "delete failed")
        }
    }
}

/// Premiumize returns sizes sometimes as a number and sometimes as a string,
/// depending on the endpoint. Decoding one shape would break on the other.
struct PremiumizeSize: Decodable, Sendable {
    let value: Int64

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            value = number
        } else if let double = try? container.decode(Double.self) {
            value = Int64(double)
        } else if let string = try? container.decode(String.self) {
            value = Int64(string) ?? Int64(Double(string) ?? 0)
        } else {
            value = 0
        }
    }
}

private extension Array {
    /// Bounds-checked subscript — a provider returning a shorter array than
    /// documented should degrade, not trap.
    func indexIfPresent(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
