import Foundation
import FetchPluginAPI

/**
 Real-Debrid.

 **Not verified against the live API.** Written from `api.real-debrid.com`;
 treat the response shapes as documented-but-unproven.

 **Two ways it does not fit the protocol, both deliberate:**

 1. **It cannot answer cache questions at all.**
    `/torrents/instantAvailability` was disabled and returns
    `disabled_endpoint`. The only remaining way to learn whether RD holds a
    torrent is to add it to the account, which §6 forbids for a badge check.
    So `canReportCacheStatus` is false, `checkCached` reports every hash as a
    miss, and the UI excludes RD from badges entirely rather than showing
    that miss as fact. It follows that RD never reaches the cached-preview
    branch of the file picker — every RD result routes through Prepare, which
    is already the correct flow for an uncached torrent.

 2. **`selectFiles` is mandatory.** `addMagnet` leaves a torrent parked at
    `waiting_files_selection` forever until files are selected. "Download
    everything" must therefore *call* select-all, not skip the call — and
    file ids only exist after the magnet has been added, which is the
    underlying reason there is no preview.
 */
public struct RealDebridProvider: SynchronousHostedLinks {
    public static let providerID = DebridProviderID(rawValue: "realdebrid")
    public static let providerName = "Real-Debrid"
    public static let reportsCacheStatus = true
    public static let apiKeyPageURL = URL(string: "https://real-debrid.com/apitoken")!
    public static let homePageURL = URL(string: "https://real-debrid.com")!

    public var id: DebridProviderID { Self.providerID }
    public var displayName: String { Self.providerName }

    public static let defaultBaseURL = URL(string: "https://api.real-debrid.com/rest/1.0")!

    let transport: DebridTransport

    public init(
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol,
        baseURL: URL = RealDebridProvider.defaultBaseURL
    ) {
        self.transport = DebridTransport(
            apiKey: apiKey, client: client, baseURL: baseURL,
            statusOverrides: [404: .fileNotFound])
    }


    /**
     Always nil: file ids exist only after `addMagnet`, so there is no way
     to list a torrent's contents without adding it to the account — which
     §6 forbids for a preview. Every Real-Debrid result routes to Prepare.
     */
    public func previewFiles(
        rawMagnet: String, infoHashHex: String
    ) async throws -> [DebridFile]? { nil }


    private struct User: Decodable, Sendable {
        let email: String?
        let type: String?
        let expiration: String?
    }

    public func validateCredentials() async throws -> DebridAccount {
        let user = try await transport.send(transport.get("user"), as: User.self)
        return DebridAccount(
            email: user.email,
            plan: user.type,
            expiresAt: user.expiration.flatMap(ISO8601DateFormatter().date(from:))
        )
    }


    private struct AddMagnetResponse: Decodable, Sendable {
        let id: String
        let uri: String?
    }

    /**
     Adds the magnet **and selects every file**, because an unselected
     torrent never starts. A caller wanting a subset re-selects afterwards
     via `selectFiles`; leaving it unselected here would look like a silent
     hang rather than a decision.
     */
    public func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        let added = try await transport.send(
            transport.form(
                .post, "torrents/addMagnet",
                fields: [URLQueryItem(name: "magnet", value: rawMagnet)],
                isRetryable: false),
            as: AddMagnetResponse.self)

        let id = DebridTorrentID(rawValue: added.id)
        try await selectFiles(torrent: id, fileIDs: nil)
        return id
    }

    /**
     `fileIDs == nil` selects everything. RD accepts the literal `all`.
     */
    public func selectFiles(torrent: DebridTorrentID, fileIDs: [DebridFileID]?) async throws {
        let value = fileIDs.map { $0.map(\.rawValue).joined(separator: ",") } ?? "all"
        try await transport.sendRaw(
            transport.form(
                .post, "torrents/selectFiles/\(torrent.rawValue)",
                fields: [URLQueryItem(name: "files", value: value)],
                isRetryable: false))
    }


    private struct TorrentInfo: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let id: Int
            let path: String
            let bytes: Int64
            let selected: Int
        }
        let id: String
        let hash: String?
        let filename: String?
        let bytes: Int64?
        let progress: Double?
        let status: String?
        let files: [File]?
        let links: [String]?
        let seeders: Int?
        let speed: Int64?
    }

    /**
     What is already on this account and finished.

     **Not `instantAvailability` — Real-Debrid withdrew it**, which is why
     this provider reported no cache status at all and an RD-only setup
     showed a column of nothing. What RD will still answer is what the
     account itself holds, and a torrent already downloaded there *is*
     instantly available to this user, which is the question the badge is
     actually asking.

     **What a miss means, and what it does not.** A hash absent from the
     account is reported as not cached, because `CacheStatusStore` reads
     absence that way and a badge has to say something. It is the
     conservative error: RD may well be able to serve it instantly from its
     own global cache and the user is merely told it might take a while, and
     then it does not. The reverse — promising instant and delivering a
     half-hour fetch — is the one worth avoiding.

     Answering it properly for torrents *not* on the account needs a
     third-party hash-cache service, which means sending someone else every
     infohash the user searches. That is a decision about the user's
     privacy, not an implementation detail, so it is not made here.
     */
    public func checkCached(
        hashes: [String], listFiles: Bool
    ) async throws -> [String: CacheEntry] {
        guard !hashes.isEmpty else { return [:] }

        var held: [String: AccountTorrent] = [:]
        for torrent in try await downloadedTorrents() {
            if let hash = torrent.hash?.lowercased() { held[hash] = torrent }
        }

        var results: [String: CacheEntry] = [:]
        for hash in hashes.map({ $0.lowercased() }) {
            let torrent = held[hash]
            results[hash] = CacheEntry(
                infoHashHex: hash,
                name: torrent?.filename ?? "",
                size: torrent == nil ? 0 : max(torrent?.bytes ?? 0, 1),
                files: nil)
        }
        return results
    }

    private struct AccountTorrent: Decodable, Sendable {
        let id: String?
        let hash: String?
        let filename: String?
        let bytes: Int64?
        let status: String?
    }

    /**
     Everything on the account that Real-Debrid has finished fetching.

     One fetch behind two callers. `checkCached` asks it which of a set of
     hashes the account already holds; `listAccountContents` shows the same
     rows as the Cloud list. Splitting them would be two requests for one
     answer, and two chances for the filter to drift apart.
     */
    private func downloadedTorrents() async throws -> [AccountTorrent] {
        let mine = try await transport.send(
            transport.get(
                "torrents",
                query: [URLQueryItem(name: "limit", value: String(Self.accountListingLimit))]),
            as: [AccountTorrent].self)
        return mine.filter { $0.status?.lowercased() == "downloaded" }
    }

    /**
     The account as Cloud rows.

     Files are left empty on purpose: Real-Debrid's listing does not carry
     them, and fetching them here would be one request per torrent on every
     open of the screen. The row hydrates the one item it needs, when it
     needs it.
     */
    public func listAccountContents() async throws -> [DebridCloudItem] {
        try await downloadedTorrents().map { torrent in
            DebridCloudItem(
                provider: id,
                origin: .torrent(DebridTorrentID(rawValue: torrent.id ?? "")),
                name: torrent.filename ?? "",
                size: torrent.bytes ?? 0,
                infoHashHex: torrent.hash?.lowercased(),
                addedAt: nil,
                files: [])
        }
    }

    static let accountListingLimit = 2500

    public func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        let info = try await transport.send(
            transport.get("torrents/info/\(id.rawValue)"), as: TorrentInfo.self)

        return DebridTorrent(
            id: id,
            infoHashHex: (info.hash ?? "").lowercased(),
            name: info.filename ?? "",
            size: info.bytes ?? 0,
            progress: (info.progress ?? 0) / 100,
            state: Self.state(from: info.status),
            files: (info.files ?? []).map { file in
                DebridFile(
                    id: DebridFileID(rawValue: String(file.id)),
                    name: file.path,
                    shortName: (file.path as NSString).lastPathComponent,
                    size: file.bytes, mimeType: nil)
            },
            seeds: info.seeders, downloadSpeed: info.speed, eta: nil
        )
    }

    static func state(from raw: String?) -> DebridTorrentState {
        switch raw?.lowercased() {
        case "magnet_conversion", "waiting_files_selection", "queued": .queued
        case "magnet_error", "error", "virus", "dead": .failed(reason: raw ?? "error")
        case "downloading": .downloading
        case "compressing", "uploading": .uploading
        case "downloaded": .completed
        case let other?: .unknown(other)
        case nil: .unknown("missing")
        }
    }

    public func files(in id: DebridTorrentID) async throws -> [DebridFile] {
        try await torrent(id: id).files
    }


    /**
     RD returns one restricted link per **selected** file, in selection
     order, and each must be unrestricted separately. The file id is not
     carried on the link, so this maps position-to-position — the same
     ordering assumption the rest of the RD ecosystem makes.
     */
    public func downloadURL(
        torrent: DebridTorrentID, file: DebridFileID
    ) async throws -> URL {
        let raw = try await transport.send(
            transport.get("torrents/info/\(torrent.rawValue)"), as: TorrentInfo.self)

        let selected = (raw.files ?? []).filter { $0.selected == 1 }
        guard let position = selected.firstIndex(where: { String($0.id) == file.rawValue }),
              let links = raw.links, position < links.count
        else { throw DebridError.fileNotFound }
        return try await unrestrict(link: links[position])
    }

    private struct UnrestrictedLink: Decodable, Sendable {
        let download: String?
        let error: String?
        let error_code: Int?
    }

    func unrestrict(link: String) async throws -> URL {
        let unrestricted = try await transport.send(
            transport.form(
                .post, "unrestrict/link",
                fields: [URLQueryItem(name: "link", value: link)]),
            as: UnrestrictedLink.self)
        guard let raw = unrestricted.download, let url = URL(string: raw) else {
            let reason = unrestricted.error.map { code -> String in
                unrestricted.error_code.map { "\(code) (\($0))" } ?? code
            } ?? "no link returned"
            throw DebridError.providerRejected(detail: reason)
        }
        return url
    }

    public func delete(torrent: DebridTorrentID) async throws {
        try await transport.sendRaw(
            transport.delete("torrents/delete/\(torrent.rawValue)"))
    }
}
