import Foundation

/// Turns the URL a user actually knows into the Torznab API URL the protocol
/// actually needs.
///
/// The spec (§7) says Settings "accepts the full Torznab base URL", which is
/// true but assumes the user can construct one. In practice they paste the URL
/// from their browser's address bar — the *web UI* root — and both indexers
/// answer that with something that is not a feed:
///
/// - Jackett `http://host:9117` → 301 → `/UI/Dashboard` → `/UI/TestCookie`,
///   which answers **400 `Cookies required`**.
/// - Prowlarr `http://host:9696` → 302 → `/login?returnUrl=…`, which answers
///   **200 with an HTML login page** — and leaks the API key into the
///   `returnUrl` query while doing it.
///
/// `URLSession` follows both redirects silently, so the app sees a cookie
/// error or an XML parse failure on a `<!DOCTYPE html>` document, and reports
/// exactly that. Nothing in the chain says "this is a web UI, not an API".
public enum TorznabEndpoint {
    /// Jackett's aggregate: query every configured indexer at once.
    ///
    /// Prowlarr deliberately has no equivalent here. `/all/api` redirects to
    /// its login page, and indexer id **0** is a built-in dummy that answers
    /// `t=caps` with a full, convincing capability set but returns a single
    /// fake `Test Release` item for every query — verified against a live
    /// instance. Guessing a Prowlarr path can therefore only ever produce a
    /// silent wrong answer, which is worse than the failure it replaces, so
    /// Prowlarr is handled by discovery instead (`ProwlarrDirectory`).
    static let jackettAggregate = "api/v2.0/indexers/all/results/torznab/api"

    /// Every URL worth trying for `url`, best guess first.
    ///
    /// A URL that is already a complete Torznab endpoint is returned alone and
    /// untouched — a user who pasted a working endpoint must never have paths
    /// appended to it.
    public static func candidates(for url: URL) -> [URL] {
        guard let root = normalizedRoot(of: url) else { return [url] }
        if !isServiceRoot(root) { return [root] }

        // The original URL stays as a last resort so this can only ever add
        // reachable candidates, never remove the one behaviour that worked
        // before.
        return [root.appendingPathComponent(jackettAggregate), root]
    }

    /// True when `url` is a bare server address rather than a complete Torznab
    /// endpoint — i.e. something that needs resolving before it can be saved.
    public static func isServiceRoot(_ url: URL) -> Bool {
        guard let root = normalizedRoot(of: url) else { return false }
        return !isComplete(root)
    }

    /// Strips the query and fragment: a user copying from the address bar can
    /// bring `?apikey=…` or `#/settings` along, and those belong to the page,
    /// not the endpoint.
    private static func normalizedRoot(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }

    /// A Torznab endpoint's last path segment is `api`, preceded by at least
    /// one more segment — `/6/api`, `/0/api`, `…/torznab/api`. A bare `/api`
    /// does not qualify: on Prowlarr that is the API *version* document
    /// (`{"current":"v1"}`), not an indexer.
    private static func isComplete(_ url: URL) -> Bool {
        let segments = url.path.split(separator: "/")
        return segments.count >= 2 && segments.last == "api"
    }

    /// True when `data` is an HTML document rather than a Torznab feed.
    ///
    /// Distinguishes "you pointed me at a login page" from "this indexer sent
    /// malformed XML" — two failures that are indistinguishable once
    /// `XMLParser` has reduced both to `NSXMLParserErrorDomain Code=76`.
    public static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }
}
