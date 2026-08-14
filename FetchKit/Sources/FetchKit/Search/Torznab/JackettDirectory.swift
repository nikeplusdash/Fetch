import Foundation
import FetchPluginAPI

/// Asks a Jackett server which indexers it has configured, and what each of
/// them carries.
///
/// **Jackett has an aggregate and Prowlarr does not, which is why this arrived
/// late.** `/api/v2.0/indexers/all/results/torznab/api` answers every query
/// with every tracker's results in one feed, so a Jackett server worked from
/// day one as a single endpoint and needed no discovery. It also meant the
/// whole server was one row in Settings, one entry in "3 of 7 indexers", and
/// one thing to reserve for an area — eleven trackers wearing one name.
///
/// Splitting them apart buys three things the aggregate cannot:
/// - **A tracker can be reserved for the areas it is good for.** That is what
///   `SubIndexer.areas` is for, and it means nothing against a row that stands
///   for everything.
/// - **Fetch's own per-provider timeout starts applying per tracker.** Measured
///   on the reporting install: one indexer inside the aggregate stalls until
///   Jackett's internal 100-second HTTP timeout fires, and because the
///   aggregate cannot answer before its slowest member does, every other
///   tracker's results wait behind it — a 100-second search whose parts took
///   between 72ms and 27s. Asked separately, that one fails on its own.
/// - **Failures name the tracker.** "1 of 11 indexers failed: EBookBay"
///   instead of one row that either worked or did not.
///
/// **`t=indexers` is a Torznab call, not a dashboard one.** That distinction is
/// the whole reason this is cheap: Jackett's `/api/v2.0/indexers` REST route
/// belongs to its web UI and 302s to `/UI/Login` on any server with an admin
/// password — the API key does not open it. `t=indexers` sits on the same
/// aggregate endpoint Fetch already searches, takes the same API key, and on a
/// live server answered in **52ms** with all eleven indexers and their full
/// `<caps>` inline. Both were measured; the REST route is not used.
public enum JackettDirectory {
    public struct Indexer: Sendable, Equatable {
        /// Jackett's own string id — `thepiratebay`, `nyaasi`, `1337x`. Stable
        /// across restarts, unlike Prowlarr's integer ids, which are database
        /// rows.
        public let id: String
        public let name: String
        /// What this indexer's own `<caps>` advertises, flattened the same way
        /// `TorznabCapsParser` flattens them.
        ///
        /// Carried out of discovery because it arrives free: the roster embeds
        /// each indexer's caps, so asking eleven endpoints for what one reply
        /// already said would be eleven round trips for nothing.
        public let categories: [TorznabCategory]

        public init(id: String, name: String, categories: [TorznabCategory] = []) {
            self.id = id
            self.name = name
            self.categories = categories
        }

        /// This indexer's own Torznab endpoint — the aggregate's shape with the
        /// id in place of `all`. Verified: `t=caps` there answers in 13ms.
        public func torznabURL(root: URL) -> URL {
            JackettDirectory.serviceRoot(of: root)
                .appendingPathComponent("api/v2.0/indexers/\(id)/results/torznab/api")
        }
    }

    /// The bare server address, whatever was handed in.
    ///
    /// **A configured Jackett server's `rootURL` is the aggregate endpoint**,
    /// not the host: that is what `IndexerSetup` resolved and saved before
    /// discovery existed, and it is what every server configured until now has
    /// stored. Appending an API path to it would produce
    /// `…/torznab/api/api/v2.0/…`, so the Jackett-shaped tail is trimmed first.
    ///
    /// Trimming path *components* rather than a string suffix, because a host
    /// named `torznab.example.com` and a path ending `/torznab/api` are
    /// different things and only one of them should be cut.
    public static func serviceRoot(of url: URL) -> URL {
        let tail: Set<String> = ["api", "torznab", "results", "all", "v2.0", "indexers"]
        var components = url.pathComponents.filter { $0 != "/" }
        while let last = components.last, tail.contains(last) {
            components.removeLast()
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        parts.query = nil
        parts.fragment = nil
        parts.path = components.isEmpty ? "" : "/" + components.joined(separator: "/")
        return parts.url ?? url
    }

    /// Whether this URL is already a Jackett API path.
    ///
    /// Used to recognise a saved aggregate endpoint — a *complete* Torznab URL
    /// that `IndexerSetup` would otherwise take at its word — as a server worth
    /// asking for a roster. Matched on Jackett's own two path components, which
    /// nothing else serves.
    public static func isJackettShaped(_ url: URL) -> Bool {
        let components = Set(url.pathComponents)
        return components.contains("v2.0") && components.contains("indexers")
    }

    /// Whether this URL is the `all` aggregate rather than one indexer.
    ///
    /// Used to retire it: once a server's indexers are known individually, the
    /// row standing for all of them is not missing, it is **superseded** — and
    /// the two need telling apart, because "no longer on this server" is a
    /// warning about the user's Jackett and this is a note about Fetch.
    public static func isAggregate(_ url: URL) -> Bool {
        isJackettShaped(url) && url.pathComponents.contains("all")
    }

    /// The endpoint `t=indexers` lives on — the aggregate, which every Jackett
    /// serves whether or not the user has ever visited it.
    static func rosterEndpoint(root: URL, apiKey: Redacted<String>) -> Endpoint {
        Endpoint(
            baseURL: serviceRoot(of: root),
            path: "api/v2.0/indexers/all/results/torznab/api",
            queryItems: [
                URLQueryItem(name: "apikey", value: apiKey.exposedValue),
                URLQueryItem(name: "t", value: "indexers"),
                // Only the ones the user has actually set up. Without this,
                // Jackett lists its entire catalogue of ~600 definitions.
                URLQueryItem(name: "configured", value: "true"),
            ],
            // Not retryable: on a non-Jackett server this is how the caller
            // learns to stop asking, and a retry only delays that.
            isRetryable: false
        )
    }

    public static func discover(
        root: URL, apiKey: Redacted<String>, client: any HTTPClientProtocol
    ) async throws -> [Indexer] {
        do {
            let (data, _) = try await client.sendRaw(rosterEndpoint(root: root, apiKey: apiKey))
            // A Prowlarr root answers this path with its login page, and an
            // HTML document reduces to `NSXMLParserErrorDomain Code=76` —
            // indistinguishable from a Jackett sending bad XML. Catch it while
            // the URL that produced it is still in hand.
            if TorznabEndpoint.looksLikeHTML(data) {
                throw SearchError.notATorznabEndpoint(
                    tried: [serviceRoot(of: root).absoluteString])
            }
            return try JackettIndexersParser.parse(data)
        } catch let error as NetworkError {
            throw TorznabProvider.mapNetworkError(error)
        }
    }
}

/// Parses Jackett's `t=indexers` document.
///
/// The shape is one `<indexer id="…" configured="true">` per tracker, each
/// wrapping a `<title>` and a full `<caps>` — the same `<categories>` tree
/// `TorznabCapsParser` reads, nested one level deeper. Categories are collected
/// per indexer rather than globally for exactly that reason: a single flat
/// accumulator would hand every tracker the union of all of them, which is the
/// aggregate's answer and the thing this exists to stop giving.
enum JackettIndexersParser {
    static func parse(_ data: Data) throws -> [JackettDirectory.Indexer] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError.map(String.init(describing:)) ?? "unknown XML error"
            throw SearchError.malformedFeed(reason: reason)
        }
        // **The empty roster is usually a rejected key, not an empty Jackett.**
        // A wrong key answers this endpoint with 200 and an `<error code="100">`
        // document, which parsed to zero indexers — and `IndexerSetup.plan`
        // read that as "not a Jackett" and silently saved the aggregate. The
        // user then sees one row called Jackett and no error anywhere.
        if let error = delegate.errorDocument { throw error }
        return delegate.indexers
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var indexers: [JackettDirectory.Indexer] = []
        var errorDocument: SearchError?

        private var currentID: String?
        private var currentCategories: [TorznabCategory] = []
        private var title = ""
        /// `<title>` appears inside `<caps><server>` as an attribute and as a
        /// child of `<indexer>`; only the latter is the tracker's name, so
        /// character data is only kept while the element is open.
        private var isReadingTitle = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            switch elementName {
            case "error":
                errorDocument = TorznabErrorDocument.error(from: attributes)
            case "indexer":
                currentID = attributes["id"]
                currentCategories = []
                title = ""
            case "title":
                isReadingTitle = true
            case "category", "subcat":
                if let raw = attributes["id"], let id = Int(raw), let name = attributes["name"] {
                    currentCategories.append(TorznabCategory(id: id, name: name))
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard isReadingTitle else { return }
            title += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch elementName {
            case "title":
                isReadingTitle = false
            case "indexer":
                guard let id = currentID, !id.isEmpty else { return }
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                indexers.append(JackettDirectory.Indexer(
                    id: id,
                    // Falling back to the id keeps a nameless entry usable
                    // rather than dropping a tracker the user configured.
                    name: name.isEmpty ? id : name,
                    categories: currentCategories))
                currentID = nil
                currentCategories = []
                title = ""
            default:
                break
            }
        }
    }
}
