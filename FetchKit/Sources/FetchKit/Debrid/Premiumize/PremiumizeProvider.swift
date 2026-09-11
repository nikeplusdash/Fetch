import Foundation
import FetchPluginAPI

/**
 Premiumize.me.

 **Not verified against the live API.** Written from the published docs at
 `premiumize.me/api`; the TorBox implementation carries "VERIFIED AGAINST THE
 LIVE API" notes precisely because response shapes surprise you. Anything
 here marked *documented* has not been exercised against a real account.

 **How it differs from TorBox.** Premiumize is folder-based rather than
 torrent-based: a transfer produces a folder, and files are listed from that
 folder. The one genuine advantage is `/transfer/directdl`, which returns
 direct links for *cached* content **without creating a transfer** — a real
 side-effect-free preview, which is exactly the role
 `checkCached(listFiles: true)` plays for TorBox (§6).
 */
public struct PremiumizeProvider: SynchronousHostedLinks {
    public static let providerID = DebridProviderID(rawValue: "premiumize")
    public static let providerName = "Premiumize"
    public static let reportsCacheStatus = true
    public static let apiKeyPageURL = URL(string: "https://www.premiumize.me/account")!
    public static let homePageURL = URL(string: "https://www.premiumize.me")!

    public var id: DebridProviderID { Self.providerID }
    public var displayName: String { Self.providerName }

    public static let defaultBaseURL = URL(string: "https://www.premiumize.me/api")!

    static let cacheChunkSize = 50

    let transport: DebridTransport

    public init(
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol,
        baseURL: URL = PremiumizeProvider.defaultBaseURL
    ) {
        self.transport = DebridTransport(
            apiKey: apiKey, client: client, baseURL: baseURL)
    }


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

        for chunk in normalized.chunked(into: Self.cacheChunkSize) {
            merged.merge(try await checkChunk(chunk)) { current, _ in current }
        }

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
            guard index < flags.count, flags[index] else { continue }
            result[hash] = CacheEntry(
                infoHashHex: hash,
                name: response.filename?.indexIfPresent(index)?.flatMap { $0 } ?? "",
                size: response.filesize?.indexIfPresent(index)??.value ?? 0,
                files: nil
            )
        }
        return result
    }


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
            email: info.customer_id.map { String($0.value) },
            plan: info.premium_until != nil ? "premium" : "free",
            expiresAt: info.premium_until.map { Date(timeIntervalSince1970: $0) }
        )
    }


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
        guard let transfer = list.transfers?.first(where: { $0.id == id.rawValue }) else {
            throw DebridError.fileNotFound
        }

        var files: [DebridFile] = []
        if Self.state(from: transfer.status).isReady {
            if let folder = transfer.folder_id {
                files = (try? await self.files(in: DebridTorrentID(rawValue: folder))) ?? []
            } else if let single = transfer.file_id {
                files = [try? await self.file(withID: single)].compactMap { $0 }
            }
        }
        return DebridTorrent(
            id: id,
            infoHashHex: "",
            name: transfer.name ?? "",
            size: 0,
            progress: transfer.progress ?? 0,
            state: Self.state(from: transfer.status),
            files: files,
            seeds: nil, downloadSpeed: nil, eta: nil,
            filesArePresent: (transfer.folder_id != nil || transfer.file_id != nil)
                && Self.state(from: transfer.status).isReady
        )
    }

    /**
     The account, as the transfers Premiumize has finished.

     **`transfer/list`, not `item/listall`.** The flat item listing returns
     every file in the account, which would be one Cloud row per episode of
     a season pack; transfers are the unit the user added and the unit this
     provider already models as a torrent in `torrent(id:)`.

     **The id is the folder, not the transfer.** Nothing downstream looks a
     transfer up: `files(in:)` takes a folder id, and `downloadURL(torrent:
     file:)` here ignores its torrent argument entirely and resolves from
     the file id through `item/details`. Carrying the transfer id would name
     something no later call can use.

     A single-file transfer has no folder to list, so its one file is built
     from what the transfer already says — the alternative is an
     `item/details` round trip per row, for a name the listing has.

     Size is left at zero: `transfer/list` does not report one, and the
     honest zero is filled in when the row's files are hydrated. There is no
     infohash either, so these rows never dedup against another service's.
     */
    public func listAccountContents() async throws -> [DebridCloudItem] {
        let list = try await transport.send(
            transport.get("transfer/list"), as: TransferList.self)
        guard list.status == "success" else {
            throw DebridError.providerRejected(detail: "transfer/list failed")
        }

        return (list.transfers ?? []).compactMap { transfer in
            guard Self.state(from: transfer.status).isReady else { return nil }
            let name = transfer.name ?? ""

            if let folder = transfer.folder_id {
                return DebridCloudItem(
                    provider: id, origin: .torrent(DebridTorrentID(rawValue: folder)),
                    name: name, size: 0, infoHashHex: nil, addedAt: nil, files: [])
            }
            guard let file = transfer.file_id else { return nil }
            return DebridCloudItem(
                provider: id, origin: .torrent(DebridTorrentID(rawValue: file)),
                name: name, size: 0, infoHashHex: nil, addedAt: nil,
                files: [DebridFile(
                    id: DebridFileID(rawValue: file), name: name,
                    shortName: (name as NSString).lastPathComponent,
                    size: 0, mimeType: nil)])
        }
    }

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

    /**
     The side-effect-free preview (§6), satisfying `DebridProvider`.

     Takes a magnet rather than a hash because `directdl` accepts a magnet —
     and `/cache/check` returns no file list at all, so this is the only way
     Premiumize can preview.
     A preview, or nil when this service cannot give one.

     **A refusal is an answer, not a failure.** Premiumize replies
     "Unsupported link for direct download." to `transfer/directdl` for a
     magnet it does not already hold — which is not an error, it is
     Premiumize saying it cannot list a torrent it has not got. Rethrowing
     it put that sentence on screen in place of the file picker, when the
     caller has a perfectly good fallback: the torrent's own metadata, over
     plain HTTPS, with no account involved.

     `unauthorized` still propagates. A bad key is the user's problem to
     fix and must not be quietly downgraded to "no preview available".
     */
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
                id: DebridFileID(rawValue: String(index)),
                name: path,
                shortName: (path as NSString).lastPathComponent,
                size: content.size?.value ?? 0,
                mimeType: nil
            )
        }
    }

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

    /**
     Every file under a folder, with its path relative to that folder.

     **It used to filter folders out rather than descend into them**, so a
     torrent with any directory structure listed only its subfolders,
     matched none of them against `type != "folder"`, and returned nothing —
     which the engine reads as "not ready yet" and polls for ever.

     Paths are joined with `/` because that is what every other list Fetch
     joins against uses: a `.torrent`'s own metadata, TorBox's names, and
     the selection the user made in the picker. A bare filename here would
     match nothing for a season pack.
     */
    public func files(in id: DebridTorrentID) async throws -> [DebridFile] {
        try await files(inFolder: id.rawValue, prefix: "", depth: 0)
    }

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

    /**
     Premiumize hands out the direct link with the listing rather than
     minting one per request, so this re-lists and picks the file out.
     */
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
    func indexIfPresent(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
