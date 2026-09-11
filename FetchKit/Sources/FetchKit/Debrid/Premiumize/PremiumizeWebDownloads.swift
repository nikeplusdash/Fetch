import Foundation
import FetchPluginAPI

extension PremiumizeProvider {
    private struct ServicesList: Decodable, Sendable {
        let directdl: [String]?
    }

    public func supportedHosts() async throws -> [DebridHost] {
        let services = try await transport.send(
            transport.get("services/list"), as: ServicesList.self)

        return (services.directdl ?? []).compactMap { domain in
            let domain = domain.lowercased()
            guard !domain.isEmpty else { return nil }
            let id = domain.split(separator: ".").first.map(String.init) ?? domain
            return DebridHost(
                id: HostID(rawValue: id), displayName: domain,
                domains: [domain], isActive: true)
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func resolveHostedLink(_ link: String) async throws -> URL {
        try await directDownloadLink(for: link)
    }

    private struct HostedDirectDL: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let path: String?
            let size: Int64?
            let link: String?
        }
        let status: String?
        let message: String?
        let content: [Item]?
    }

    private func directDownloadLink(for link: String) async throws -> URL {
        let response = try await transport.send(
            transport.form(
                .post, "transfer/directdl",
                fields: [URLQueryItem(name: "src", value: link)],
                isRetryable: false),
            as: HostedDirectDL.self)
        guard response.status == "success" else {
            throw DebridError.providerRejected(
                detail: response.message ?? "link not resolved")
        }
        guard let raw = response.content?.first?.link, let url = URL(string: raw) else {
            throw DebridError.providerRejected(detail: "no link returned")
        }
        return url
    }
}
