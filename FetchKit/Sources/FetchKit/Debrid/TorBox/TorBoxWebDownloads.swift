import Foundation
import FetchPluginAPI

extension TorBoxProvider {

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
            let domains = hoster.domains ?? hoster.domain.map { [$0] } ?? []
            guard !domains.isEmpty else { return nil }

            return DebridHost(
                id: HostID(rawValue: name.lowercased()),
                displayName: name,
                domains: domains,
                isActive: hoster.status ?? true)
        }
    }


    private struct CreateWebDownloadResult: Decodable, Sendable {
        let webdownload_id: TorBoxIdentifier?
        let hash: String?
    }

    public func submitLink(_ url: URL) async throws -> DebridDownloadID {
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


    private struct TorBoxWebDownloadRaw: Decodable, Sendable {
        let id: TorBoxIdentifier
        let name: String?
        let size: Int64?
        let progress: Double?
        let download_state: DebridTorrentState?
        let files: [TorBoxFile]?
    }

    public func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
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
        guard let raw = envelope.data?.first else { throw DebridError.fileNotFound }

        return DebridWebDownload(
            id: DebridDownloadID(rawValue: raw.id.stringValue),
            name: raw.name ?? "",
            size: raw.size,
            progress: raw.progress ?? 0,
            state: raw.download_state ?? .unknown("missing"),
            files: (raw.files ?? []).map(\.asDebridFile))
    }


    public func downloadURL(web id: DebridDownloadID) async throws -> URL {
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
