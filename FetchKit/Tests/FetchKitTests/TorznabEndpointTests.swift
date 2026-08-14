import Testing
import Foundation
@testable import FetchKit

/// Users type the URL they know — the one in their browser's address bar,
/// which is the Jackett/Prowlarr *web UI* root, not a Torznab API path.
/// Those roots redirect to a dashboard or a login page, so the app receives
/// HTML (or a cookie error) and reports an XML parse failure. See
/// `TorznabEndpoint` for the candidate paths that turn a root into a real
/// endpoint.
@Suite struct TorznabEndpointTests {

    // MARK: - Service roots

    @Test func jackettRootOffersTheAggregateTorznabPathFirst() {
        let candidates = TorznabEndpoint.candidates(for: URL(string: "http://10.0.0.181:9117")!)

        #expect(candidates.first?.absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")
    }

    /// Prowlarr has **no** Torznab aggregate: `/all/api` redirects to the
    /// login page, and indexer id 0 is a built-in dummy that answers `t=caps`
    /// convincingly but returns a single fake "Test Release" for every query.
    /// Guessing a path for Prowlarr can only produce a silent wrong answer —
    /// its indexers must be discovered instead (`ProwlarrDirectory`).
    @Test func prowlarrRootNeverGuessesAnAggregatePath() {
        let candidates = TorznabEndpoint.candidates(for: URL(string: "http://10.0.0.181:9696")!)
            .map(\.absoluteString)

        #expect(!candidates.contains { $0.hasSuffix("/0/api") })
        #expect(!candidates.contains { $0.hasSuffix("/all/api") })
    }

    @Test func trailingSlashRootIsTreatedAsARoot() {
        let candidates = TorznabEndpoint.candidates(for: URL(string: "http://10.0.0.181:9117/")!)

        #expect(candidates.first?.absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")
    }

    /// A root behind a reverse proxy has no recognizable port, so the Jackett
    /// shape is still worth trying — it is the only one that can be derived
    /// from a path alone.
    @Test func unrecognizedRootStillOffersTheJackettShape() {
        let candidates = TorznabEndpoint.candidates(for: URL(string: "http://nas.local/jackett")!)
            .map(\.absoluteString)

        #expect(candidates.contains(
            "http://nas.local/jackett/api/v2.0/indexers/all/results/torznab/api"))
    }

    @Test func aRootIsRecognizedAsIncomplete() {
        #expect(TorznabEndpoint.isServiceRoot(URL(string: "http://10.0.0.181:9696")!))
        #expect(TorznabEndpoint.isServiceRoot(URL(string: "http://10.0.0.181:9696/")!))
        #expect(!TorznabEndpoint.isServiceRoot(URL(string: "http://10.0.0.181:9696/6/api")!))
        #expect(!TorznabEndpoint.isServiceRoot(URL(string:
            "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")!))
    }

    // MARK: - Already-complete endpoints

    /// The spec's documented shapes must survive untouched — a user who
    /// already pasted a working endpoint must not have paths appended to it.
    @Test func completeJackettEndpointIsUsedVerbatim() {
        let url = URL(string:
            "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")!

        #expect(TorznabEndpoint.candidates(for: url) == [url])
    }

    @Test func completeProwlarrPerIndexerEndpointIsUsedVerbatim() {
        let url = URL(string: "http://10.0.0.181:9696/6/api")!

        #expect(TorznabEndpoint.candidates(for: url) == [url])
    }

    @Test func prowlarrAggregateEndpointIsUsedVerbatim() {
        let url = URL(string: "http://10.0.0.181:9696/0/api")!

        #expect(TorznabEndpoint.candidates(for: url) == [url])
    }

    /// A Jackett *single-indexer* endpoint also ends in `/api` and is just as
    /// complete as the aggregate one.
    @Test func jackettSingleIndexerEndpointIsUsedVerbatim() {
        let url = URL(string:
            "http://10.0.0.181:9117/api/v2.0/indexers/rutor/results/torznab/api")!

        #expect(TorznabEndpoint.candidates(for: url) == [url])
    }

    // MARK: - Diagnosing what the server sent back

    @Test func aLoginPageIsRecognizedAsHTML() {
        let html = Data("""
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8" /></head><body>Prowlarr</body></html>
        """.utf8)

        #expect(TorznabEndpoint.looksLikeHTML(html))
    }

    @Test func aCapsDocumentIsNotHTML() {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <caps><server title="Prowlarr" /></caps>
        """.utf8)

        #expect(!TorznabEndpoint.looksLikeHTML(xml))
    }

    /// Leading whitespace/BOM must not defeat the sniff.
    @Test func htmlWithLeadingWhitespaceIsStillRecognized() {
        let html = Data("\n\n  <html><body>hi</body></html>".utf8)

        #expect(TorznabEndpoint.looksLikeHTML(html))
    }

    @Test func anRSSFeedIsNotHTML() {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel></channel></rss>
        """.utf8)

        #expect(!TorznabEndpoint.looksLikeHTML(xml))
    }
}
