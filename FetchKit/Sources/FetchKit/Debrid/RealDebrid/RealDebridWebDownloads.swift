import Foundation
import FetchPluginAPI

/// Real-Debrid's web downloads (7e §3.7).
///
/// **The one place the three providers genuinely differ.** TorBox queues a
/// link and reports progress; Real-Debrid's `/unrestrict/link` is synchronous
/// — one POST returns the final link, and there is no queue to poll.
///
/// The async protocol shape subsumes the synchronous one rather than the other
/// way round, so this maps onto it:
///
/// - `submitLink` **validates** by unrestricting once, then discards the CDN
///   URL and returns a handle carrying the original hoster link. Validating at
///   submit is what turns "unsupported host" into an error the user sees while
///   they are still looking at the sheet, instead of a queued download that
///   never starts.
/// - `webDownload` reports `.completed` and makes **no request**: there is
///   nothing to poll.
/// - `downloadURL(web:)` unrestricts again, freshly. That is not waste — §6
///   forbids persisting a CDN URL because it is credentialed and expires, so
///   re-resolving at fetch time is the rule, not a workaround for it.
extension RealDebridProvider {
    /// Every host Real-Debrid can unrestrict.
    ///
    /// `/hosts` returns a domain-keyed object rather than a list, and carries
    /// no up/down flag — RD publishes status separately and this does not ask,
    /// so every host reports `isActive: true`. Claiming a host is up is the
    /// safe direction: the failure surfaces at submit with the service's own
    /// message, rather than Fetch refusing a link that would have worked.
    public func supportedHosts() async throws -> [DebridHost] {
        let raw = try await transport.send(
            transport.get("hosts"), as: [String: RealDebridHost].self)

        return raw.map { domain, host in
            DebridHost(
                id: HostID(rawValue: (host.id ?? domain).lowercased()),
                displayName: host.name ?? domain,
                domains: [domain],
                isActive: true)
        }
        // Dictionary order is not stable across launches, and the host list is
        // rendered in Settings — an unsorted list would reshuffle every time
        // it was opened.
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// `submitLink`, `webDownload`, `downloadURL(web:)` and
    /// `hostedLinksNeedPreparing` all come from `SynchronousHostedLinks`.
    /// This is the only part that is Real-Debrid's own.
    func resolveHostedLink(_ link: String) async throws -> URL {
        try await unrestrict(link: link)
    }
}

struct RealDebridHost: Decodable, Sendable {
    let id: String?
    let name: String?
}
