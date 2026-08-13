import Foundation

public enum SearchError: Error, Sendable {
    case invalidEndpoint
    case unauthorized
    case malformedFeed(reason: String)
    case providerTimeout
    case network(NetworkError)
    /// The URL answered, but with a web page rather than a Torznab feed —
    /// almost always a Jackett/Prowlarr web-UI root instead of its API path.
    /// Carries every URL that was tried so the message can name them.
    case notATorznabEndpoint(tried: [String])
}

extension SearchError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidEndpoint:        "invalidEndpoint"
        case .unauthorized:           "unauthorized"
        case .malformedFeed(let why): "malformedFeed(\(why))"
        case .providerTimeout:        "providerTimeout"
        case .network(let e):         "network(\(e))"
        case .notATorznabEndpoint(let tried):
            "notATorznabEndpoint(tried: \(tried.joined(separator: ", ")))"
        }
    }
}

/// Every one of these reaches a text field in Settings or the search banner.
/// `String(describing:)` on the raw case leaked things like
/// `malformedFeed(reason: "Error Domain=NSXMLParserErrorDomain Code=76 …")`,
/// which tells the user nothing about what to change.
extension SearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "That URL isn't valid. Include the scheme, e.g. http://10.0.0.181:9696."

        case .unauthorized:
            "The indexer rejected the API key. Copy it again from "
            + "Prowlarr's Settings → General, or Jackett's dashboard header."

        case .malformedFeed(let reason):
            "The indexer replied with something this app couldn't read (\(reason))."

        case .providerTimeout:
            "The indexer didn't respond in time. Check that it's running and reachable."

        case .network(let error):
            Self.reachabilityAdvice(for: error)

        case .notATorznabEndpoint(let tried):
            "That URL serves the indexer's web interface, not its Torznab API"
            + (tried.count > 1 ? ", and no API path was found under it" : "")
            + ". Use the Torznab endpoint instead — Prowlarr: copy it from the "
            + "indexer's ⋮ menu, or use http://host:9696/0/api to search all of "
            + "them. Jackett: http://host:9117/api/v2.0/indexers/all/results/torznab/api."
            + (tried.isEmpty ? "" : "\nTried: " + tried.joined(separator: "\n       "))
        }
    }

    /// Turns a transport code into the thing the user has to go change.
    ///
    /// `-1009` is the one that matters here. macOS reports a LAN address the
    /// app has no local-network permission for as "not connected to the
    /// internet", even while the same request from `curl` — and the app's own
    /// HTTPS traffic — succeeds. Rendered as the raw code, it sends people to
    /// check a network that is working fine.
    static func reachabilityAdvice(for error: NetworkError) -> String {
        guard case .transport(let urlError) = error else {
            return "Couldn't reach the indexer: \(error)."
        }
        switch urlError.code {
        case .notConnectedToInternet:
            return "Couldn't reach the indexer. If it's on your local network, "
                + "macOS may be blocking this app: open System Settings → "
                + "Privacy & Security → Local Network and switch Fetch on."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Nothing answered at that address. Check the host and port, "
                + "and that the indexer is running."
        case .timedOut:
            return "The indexer didn't respond in time. Check that it's running "
                + "and reachable."
        case .appTransportSecurityRequiresSecureConnection:
            return "macOS blocked this plain-HTTP request. Use https://, or "
                + "reach the indexer over your local network."
        default:
            return "Couldn't reach the indexer: \(error)."
        }
    }
}
