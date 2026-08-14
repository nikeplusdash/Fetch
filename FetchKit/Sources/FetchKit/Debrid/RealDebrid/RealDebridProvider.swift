import Foundation
import FetchPluginAPI

/// Real-Debrid.
///
/// **Not verified against the live API.** Written from `api.real-debrid.com`;
/// treat the response shapes as documented-but-unproven.
///
/// **Two ways it does not fit the protocol, both deliberate:**
///
/// 1. **It cannot answer cache questions at all.**
///    `/torrents/instantAvailability` was disabled and returns
///    `disabled_endpoint`. The only remaining way to learn whether RD holds a
///    torrent is to add it to the account, which §6 forbids for a badge check.
///    So `canReportCacheStatus` is false, `checkCached` reports every hash as a
///    miss, and the UI excludes RD from badges entirely rather than showing
///    that miss as fact. It follows that RD never reaches the cached-preview
///    branch of the file picker — every RD result routes through Prepare, which
///    is already the correct flow for an uncached torrent.
///
/// 2. **`selectFiles` is mandatory.** `addMagnet` leaves a torrent parked at
///    `waiting_files_selection` forever until files are selected. "Download
///    everything" must therefore *call* select-all, not skip the call — and
///    file ids only exist after the magnet has been added, which is the
///    underlying reason there is no preview.
public struct RealDebridProvider: SynchronousHostedLinks {
    public static let providerID = DebridProviderID(rawValue: "realdebrid")
    public static let providerName = "Real-Debrid"
    /// RD withdrew instant-availability; see the type doc.
    public static let reportsCacheStatus = true
    /// Where a user finds their key. Surfaced by Settings' "Get my API key".
    public static let apiKeyPageURL = URL(string: "https://real-debrid.com/apitoken")!

    public var id: DebridProviderID { Self.providerID }
    public var displayName: String { Self.providerName }

    public static let defaultBaseURL = URL(string: "https://api.real-debrid.com/rest/1.0")!

    /// Internal rather than private so `RealDebridWebDownloads` can build the
    /// same requests from the same credentials.
    let transport: DebridTransport

    public init(
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol,
        baseURL: URL = RealDebridProvider.defaultBaseURL
    ) {
        // Real-Debrid is the only provider that gives 404 a meaning beyond
        // "transport error": it is how the API says the torrent or link is
        // gone. TorBox and Premiumize get no such entry — inventing one would
        // make a poller treat an outage as a permanent loss.
        self.transport = DebridTransport(
            apiKey: apiKey, client: client, baseURL: baseURL,
            statusOverrides: [404: .fileNotFound])
    }

    // MARK: - Cache
    //
    // The stub that lived here returned a total map of misses and told callers
    // to gate on `canReportCacheStatus` instead — accurate when
    // `instantAvailability` went away, and it left an RD-only setup with a
    // column of nothing for ever. The real implementation is below: what the
    // account already holds.

    /// Always nil: file ids exist only after `addMagnet`, so there is no way
    /// to list a torrent's contents without adding it to the account — which
    /// §6 forbids for a preview. Every Real-Debrid result routes to Prepare.
    public func previewFiles(
        rawMagnet: String, infoHashHex: String
    ) async throws -> [DebridFile]? { nil }

    // MARK: - Account

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

    // MARK: - Submit

    private struct AddMagnetResponse: Decodable, Sendable {
        let id: String
        let uri: String?
    }

    /// Adds the magnet **and selects every file**, because an unselected
    /// torrent never starts. A caller wanting a subset re-selects afterwards
    /// via `selectFiles`; leaving it unselected here would look like a silent
    /// hang rather than a decision.
    public func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        let added = try await transport.send(
            transport.form(
                .post, "torrents/addMagnet",
                fields: [URLQueryItem(name: "magnet", value: rawMagnet)],
                // never re-submit a torrent on a transient error
                isRetryable: false),
            as: AddMagnetResponse.self)

        let id = DebridTorrentID(rawValue: added.id)
        try await selectFiles(torrent: id, fileIDs: nil)
        return id
    }

    /// `fileIDs == nil` selects everything. RD accepts the literal `all`.
    public func selectFiles(torrent: DebridTorrentID, fileIDs: [DebridFileID]?) async throws {
        let value = fileIDs.map { $0.map(\.rawValue).joined(separator: ",") } ?? "all"
        // 204 No Content on success, so there is no body to decode.
        try await transport.sendRaw(
            transport.form(
                .post, "torrents/selectFiles/\(torrent.rawValue)",
                fields: [URLQueryItem(name: "files", value: value)],
                isRetryable: false))
    }

    // MARK: - Poll

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

    /// What is already on this account and finished.
    ///
    /// **Not `instantAvailability` — Real-Debrid withdrew it**, which is why
    /// this provider reported no cache status at all and an RD-only setup
    /// showed a column of nothing. What RD will still answer is what the
    /// account itself holds, and a torrent already downloaded there *is*
    /// instantly available to this user, which is the question the badge is
    /// actually asking.
    ///
    /// **What a miss means, and what it does not.** A hash absent from the
    /// account is reported as not cached, because `CacheStatusStore` reads
    /// absence that way and a badge has to say something. It is the
    /// conservative error: RD may well be able to serve it instantly from its
    /// own global cache and the user is merely told it might take a while, and
    /// then it does not. The reverse — promising instant and delivering a
    /// half-hour fetch — is the one worth avoiding.
    ///
    /// Answering it properly for torrents *not* on the account needs a
    /// third-party hash-cache service, which means sending someone else every
    /// infohash the user searches. That is a decision about the user's
    /// privacy, not an implementation detail, so it is not made here.
    public func checkCached(
        hashes: [String], listFiles: Bool
    ) async throws -> [String: CacheEntry] {
        guard !hashes.isEmpty else { return [:] }

        struct AccountTorrent: Decodable, Sendable {
            let hash: String?
            let filename: String?
            let bytes: Int64?
            let status: String?
        }
        let mine = try await transport.send(
            transport.get(
                "torrents",
                query: [URLQueryItem(name: "limit", value: String(Self.accountListingLimit))]),
            as: [AccountTorrent].self)

        var held: [String: AccountTorrent] = [:]
        for torrent in mine where torrent.status?.lowercased() == "downloaded" {
            if let hash = torrent.hash?.lowercased() { held[hash] = torrent }
        }

        var results: [String: CacheEntry] = [:]
        for hash in hashes.map({ $0.lowercased() }) {
            let torrent = held[hash]
            results[hash] = CacheEntry(
                infoHashHex: hash,
                name: torrent?.filename ?? "",
                // Size is what `CacheStatusStore` reads as "cached": a zero
                // means no. Falling back to 1 for a held torrent that reports
                // no size keeps a real hit from reading as a miss.
                size: torrent == nil ? 0 : max(torrent?.bytes ?? 0, 1),
                // The account listing carries no file list, and asking for one
                // per torrent would be a request per result on screen.
                files: nil)
        }
        return results
    }

    /// One page, and a generous one. RD accepts far more, but a listing this
    /// long already covers any realistic account and the call is made per
    /// badge batch.
    static let accountListingLimit = 2500

    public func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        let info = try await transport.send(
            transport.get("torrents/info/\(id.rawValue)"), as: TorrentInfo.self)

        return DebridTorrent(
            id: id,
            infoHashHex: (info.hash ?? "").lowercased(),
            name: info.filename ?? "",
            size: info.bytes ?? 0,
            // RD reports 0–100; the protocol is 0–1.
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

    /// Documented statuses. `waiting_files_selection` maps to `.checking`
    /// rather than `.queued`: it means the torrent is stalled pending an action
    /// this client is responsible for taking, and `submitMagnet` takes it.
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

    // MARK: - Download link

    /// RD returns one restricted link per **selected** file, in selection
    /// order, and each must be unrestricted separately. The file id is not
    /// carried on the link, so this maps position-to-position — the same
    /// ordering assumption the rest of the RD ecosystem makes.
    public func downloadURL(
        torrent: DebridTorrentID, file: DebridFileID
    ) async throws -> URL {
        // One call, not two: this asked for the same `torrents/info` twice —
        // once through `torrent(id:)` for the files and once raw for the
        // links — which is two round trips and two chances for the two answers
        // to describe different states of the same torrent.
        let raw = try await transport.send(
            transport.get("torrents/info/\(torrent.rawValue)"), as: TorrentInfo.self)

        // `selected`, not `size > 0`. RD returns one link per **selected**
        // file and the flag saying which is right there in the response —
        // decoded, and until now never read. Size was standing in for it, and
        // the two part company the moment a torrent holds a zero-byte file or
        // anything is deselected, at which point every link after that point
        // is off by one and the download fetches the wrong file.
        let selected = (raw.files ?? []).filter { $0.selected == 1 }
        guard let position = selected.firstIndex(where: { String($0.id) == file.rawValue }),
              let links = raw.links, position < links.count
        else { throw DebridError.fileNotFound }
        return try await unrestrict(link: links[position])
    }

    private struct UnrestrictedLink: Decodable, Sendable {
        let download: String?
        /// Real-Debrid answers a refusal with a body, not only a status —
        /// `{"error":"hoster_unavailable","error_code":23}`. Decoded here so
        /// the reason reaches the user.
        let error: String?
        let error_code: Int?
    }

    func unrestrict(link: String) async throws -> URL {
        let unrestricted = try await transport.send(
            transport.form(
                .post, "unrestrict/link",
                fields: [URLQueryItem(name: "link", value: link)]),
            as: UnrestrictedLink.self)
        // This URL must never be logged or persisted (global constraint).
        guard let raw = unrestricted.download, let url = URL(string: raw) else {
            // **"no link returned" was all this ever said**, which describes
            // the symptom and none of the cause: Real-Debrid puts the reason
            // in the body — a dead hoster, a link that expired between the
            // torrent listing and this call, an account limit — and it was
            // being decoded away. A user resuming a download got a sentence
            // that told them nothing and gave them nothing to try.
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
