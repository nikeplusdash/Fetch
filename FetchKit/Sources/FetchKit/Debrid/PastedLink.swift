import Foundation
import FetchPluginAPI

/**
 What the user pasted into the add-link field (7e §5.1).

 Every case is a **different fact**, and the sheet says a different thing
 for each. Collapsing them into "invalid link" — which is what one boolean
 would do — leaves the user unable to tell whether the problem is the link,
 the host, or their account.

 Lives in `FetchKit` rather than in the sheet for the reason `Faceting`
 does: the app target has no test bundle, so a view is where a decision
 goes to stop being tested.
 */
public enum PastedLink: Sendable {
    case empty
    case magnet(MagnetLink)
    case hosted(url: URL, host: DebridHost, provider: DebridProviderID)
    case hostDown(url: URL, host: DebridHost)
    case unsupportedHost(url: URL, hostName: String)
    case checkingCoverage(url: URL)
    case noDebridConfigured(url: URL)
    case invalid

    public var isActionable: Bool {
        switch self {
        case .magnet, .hosted: true
        default: false
        }
    }

    /**
     Decides what a pasted string is.

     `configured` is the user's debrid preference order; `coverage` is what
     `SupportedHostsCache` has learned so far.
     */
    public static func resolve(
        _ text: String,
        configured: [DebridProviderID],
        coverage: [DebridProviderID: [DebridHost]]
    ) -> PastedLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        if let magnet = MagnetLink(trimmed) { return .magnet(magnet) }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let hostName = url.host()?.lowercased()
        else { return .invalid }

        guard !configured.isEmpty else { return .noDebridConfigured(url: url) }

        if let match = DebridRouter.provider(
            forHost: url, providers: configured, supportedBy: coverage) {
            return .hosted(url: url, host: match.host, provider: match.provider)
        }

        for provider in configured {
            if let hosts = coverage[provider],
               let host = DebridRouter.host(for: url, in: hosts) {
                return .hostDown(url: url, host: host)
            }
        }

        let answered = configured.contains { coverage[$0] != nil }
        return answered
            ? .unsupportedHost(url: url, hostName: hostName)
            : .checkingCoverage(url: url)
    }
}
