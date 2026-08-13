import Foundation
import FetchPluginAPI

/// What the user pasted into the add-link field (7e §5.1).
///
/// Every case is a **different fact**, and the sheet says a different thing
/// for each. Collapsing them into "invalid link" — which is what one boolean
/// would do — leaves the user unable to tell whether the problem is the link,
/// the host, or their account.
///
/// Lives in `FetchKit` rather than in the sheet for the reason `Faceting`
/// does: the app target has no test bundle, so a view is where a decision
/// goes to stop being tested.
public enum PastedLink: Sendable {
    case empty
    case magnet(MagnetLink)
    /// Downloadable: this host, through this debrid.
    case hosted(url: URL, host: DebridHost, provider: DebridProviderID)
    /// A configured debrid covers it but reports it down. Distinct from
    /// `unsupportedHost` because it tells the user to try later rather than
    /// to give up.
    case hostDown(url: URL, host: DebridHost)
    /// No configured debrid covers this host. Carries the host name so the
    /// message can name it.
    case unsupportedHost(url: URL, hostName: String)
    /// There are debrids configured but their coverage has not arrived yet.
    /// Not a refusal — refusing here would reject a link that is about to
    /// become downloadable a moment later.
    case checkingCoverage(url: URL)
    /// Nothing to ask.
    case noDebridConfigured(url: URL)
    case invalid

    /// Whether this is something the user can act on.
    public var isActionable: Bool {
        switch self {
        case .magnet, .hosted: true
        default: false
        }
    }

    /// Decides what a pasted string is.
    ///
    /// `configured` is the user's debrid preference order; `coverage` is what
    /// `SupportedHostsCache` has learned so far.
    public static func resolve(
        _ text: String,
        configured: [DebridProviderID],
        coverage: [DebridProviderID: [DebridHost]]
    ) -> PastedLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Magnets first: a magnet is never a hoster link, and this is the
        // path that already worked.
        if let magnet = MagnetLink(trimmed) { return .magnet(magnet) }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              // `http` stays allowed for the same reason §13 permits it for
              // LAN indexers. `file:` must never get this far: origins are
              // attacker-controlled text, and a file URL would name a path on
              // the user's own disk.
              scheme == "https" || scheme == "http",
              let hostName = url.host()?.lowercased()
        else { return .invalid }

        guard !configured.isEmpty else { return .noDebridConfigured(url: url) }

        // Preference order, first match wins — `DebridRouter` owns that rule
        // for both the torrent and the hosted case, so it is stated once.
        if let match = DebridRouter.provider(
            forHost: url, providers: configured, supportedBy: coverage) {
            return .hosted(url: url, host: match.host, provider: match.provider)
        }

        // Nobody has it up. If somebody *knows* the host, that is a different
        // message from nobody covering it at all — and worth keeping separate,
        // because one says try later and the other says give up.
        for provider in configured {
            if let hosts = coverage[provider],
               let host = DebridRouter.host(for: url, in: hosts) {
                return .hostDown(url: url, host: host)
            }
        }

        // Distinguish "asked, and nobody covers it" from "have not asked
        // yet": a configured provider with no coverage entry has not answered,
        // and refusing the link would reject something about to become
        // downloadable.
        let answered = configured.contains { coverage[$0] != nil }
        return answered
            ? .unsupportedHost(url: url, hostName: hostName)
            : .checkingCoverage(url: url)
    }
}
