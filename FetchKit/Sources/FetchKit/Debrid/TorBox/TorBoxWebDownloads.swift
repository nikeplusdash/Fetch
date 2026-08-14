import Foundation
import FetchPluginAPI

/// TorBox's web-download endpoints (amendment §5, 7e §3.7).
///
/// Deliberately the torrent family with different nouns: same
/// `TorBoxEnvelope` decoding, same `success: false` on HTTP 200 handling, same
/// `requestdl` token-in-query rule — and therefore the same **never log,
/// never persist** rule for the URL it returns.
extension TorBoxProvider {
    // MARK: - Supported hosts

    private struct TorBoxHoster: Decodable, Sendable {
        let name: String?
        let domain: String?
        let domains: [String]?
        let status: Bool?
    }

    public func supportedHosts() async throws -> [DebridHost] {
        let envelope = try await transport.send(
            transport.get("/v1/api/webdl/hosters"),
            as: TorBoxEnvelope<[TorBoxHoster]>.self)
        let raw = try envelope.requireData("no hosters returned")

        return raw.compactMap { hoster in
            guard let name = hoster.name, !name.isEmpty else { return nil }
            // `domains` where present, else the singular `domain`, else the
            // name itself — which for TorBox is usually the bare domain. A
            // host with no domain at all matches nothing, which is safer than
            // guessing one.
            let domains = hoster.domains ?? hoster.domain.map { [$0] } ?? []
            guard !domains.isEmpty else { return nil }

            return DebridHost(
                id: HostID(rawValue: name.lowercased()),
                displayName: name,
                domains: domains,
                // Carried, not filtered. "MediaFire, reported down" is a
                // different message from "unsupported host", and only the
                // first tells the user to try again later.
                isActive: hoster.status ?? true)
        }
    }

    // MARK: - Submit

    private struct CreateWebDownloadResult: Decodable, Sendable {
        let webdownload_id: TorBoxIdentifier?
        let hash: String?
    }

    public func submitLink(_ url: URL) async throws -> DebridDownloadID {
        // Never re-submit a link on a transient error, for a reason the
        // torrent path does not have: a retry can cost a second account slot.
        let envelope = try await transport.send(
            transport.multipart(
                "/v1/api/webdl/createwebdownload",
                field: "link", value: url.absoluteString),
            as: TorBoxEnvelope<CreateWebDownloadResult>.self)
        try envelope.requireSuccess("no download id returned")
        guard let id = envelope.data?.webdownload_id else {
            throw DebridError.providerRejected(detail: "no download id returned")
        }
        return DebridDownloadID(rawValue: id.stringValue)
    }

    // MARK: - Poll

    private struct TorBoxWebDownloadRaw: Decodable, Sendable {
        let id: TorBoxIdentifier
        let name: String?
        let size: Int64?
        let progress: Double?
        let download_state: DebridTorrentState?
        let files: [TorBoxFile]?
    }

    public func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
        // Unlike `torrents/mylist?id=N`, which returns a single object, the
        // webdl list has been observed returning an array even for one id.
        // Decoded permissively so a shape change on either side does not
        // become a runtime failure in the middle of a download.
        //
        // Same narrow 500 rule as the torrent path: it is the verified answer
        // for a nonexistent id, and 502/503/504 are not.
        let envelope = try await transport.send(
            transport.get(
                "/v1/api/webdl/mylist",
                query: [
                    URLQueryItem(name: "id", value: id.rawValue),
                    URLQueryItem(name: "bypass_cache", value: "true"),
                ]),
            as: TorBoxEnvelope<TorBoxEitherOne<TorBoxWebDownloadRaw>>.self,
            extraStatusOverrides: Self.idNotFound)
        try envelope.requireSuccess()
        // An empty list is an id the service does not know. Reporting a
        // zero-progress download instead would have the poller wait forever
        // on something that will never arrive.
        guard let raw = envelope.data?.first else { throw DebridError.fileNotFound }

        return DebridWebDownload(
            id: DebridDownloadID(rawValue: raw.id.stringValue),
            name: raw.name ?? "",
            size: raw.size,
            progress: raw.progress ?? 0,
            state: raw.download_state ?? .unknown("missing"),
            files: (raw.files ?? []).map(\.asDebridFile))
    }

    // MARK: - Download link

    public func downloadURL(web id: DebridDownloadID) async throws -> URL {
        // requestdl authenticates via `token` query param, NOT a Bearer
        // header — same as the torrent path. This URL must never be logged or
        // persisted (global constraint).
        let envelope = try await transport.send(
            transport.unauthenticated(
                "/v1/api/webdl/requestdl",
                query: [
                    URLQueryItem(name: "token", value: transport.token),
                    URLQueryItem(name: "web_id", value: id.rawValue),
                ]),
            as: TorBoxEnvelope<String>.self)
        let raw = try envelope.requireData("no link returned")
        guard let url = URL(string: raw) else {
            throw DebridError.providerRejected(detail: "no link returned")
        }
        return url
    }
}

/// One or many, decoded the same way.
///
/// TorBox returns a single object for `torrents/mylist?id=N` and an array for
/// the un-filtered call, and the webdl family has not been verified live to
/// pick one. Accepting both means a shape change is not a runtime decode
/// failure part-way through a download.
struct TorBoxEitherOne<Element: Decodable & Sendable>: Decodable, Sendable {
    let values: [Element]

    var first: Element? { values.first }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Element].self) {
            values = many
        } else {
            values = [try container.decode(Element.self)]
        }
    }
}

/// TorBox spells ids as bare integers in some responses and strings in others.
///
/// Decoding it as `Int` fails on the string form and vice versa; either
/// failure surfaces as "no download id returned" for a submit that actually
/// worked, leaving a queued download the app has lost the handle to.
struct TorBoxIdentifier: Decodable, Sendable {
    let stringValue: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            stringValue = String(number)
        } else {
            stringValue = try container.decode(String.self)
        }
    }
}
