import Foundation
import FetchPluginAPI

/// Premiumize's web downloads (7e §3.7).
///
/// Synchronous like Real-Debrid rather than queued like TorBox:
/// `/transfer/directdl` takes a hoster link and answers with the resolved one.
/// So `submitLink` validates, `webDownload` reports completed without a
/// request, and `downloadURL(web:)` re-resolves at fetch time — §6's rule that
/// no CDN URL is persisted, satisfied by never holding one.
///
/// **Unverified against the live service.** Every decode here is permissive
/// for that reason: a shape Fetch does not recognise yields *no hosts*, which
/// makes Premiumize lose host routing and stay invisible. That is §5's
/// designed failure mode, and it is much better than an exception surfacing
/// while the user is pasting a link.
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
            // Premiumize names coverage by domain and publishes no per-host
            // id, so the first label is the id — "mediafire.com" → "mediafire".
            // It reports no up/down flag either, so every host is active:
            // claiming a host is up is the safe direction, since the failure
            // then surfaces at submit with the service's own message rather
            // than Fetch refusing a link that would have worked.
            let id = domain.split(separator: ".").first.map(String.init) ?? domain
            return DebridHost(
                id: HostID(rawValue: id), displayName: domain,
                domains: [domain], isActive: true)
        }
        // Dictionary and array order from the service is not guaranteed
        // stable, and this list is rendered in Settings.
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// `submitLink`, `webDownload`, `downloadURL(web:)` and
    /// `hostedLinksNeedPreparing` all come from `SynchronousHostedLinks`.
    /// This is the only part that is Premiumize's own.
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

    /// Same path and field as `directDL(rawMagnet:)`, deliberately kept
    /// separate: this one is **not** retryable and decodes `size: Int64?`,
    /// that one is retryable and decodes leniently via `PremiumizeSize`.
    private func directDownloadLink(for link: String) async throws -> URL {
        let response = try await transport.send(
            transport.form(
                .post, "transfer/directdl",
                fields: [URLQueryItem(name: "src", value: link)],
                isRetryable: false),
            as: HostedDirectDL.self)
        // `status: error` on HTTP 200 is Premiumize's failure shape — the same
        // trap as TorBox's `success: false`.
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
