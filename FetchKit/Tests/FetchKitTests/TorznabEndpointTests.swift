import Testing
import Foundation
@testable import FetchKit

@Suite struct TorznabEndpointTests {


    @Test func jackettRootOffersTheAggregateTorznabPathFirst() {
        let candidates = TorznabEndpoint.candidates(for: URL(string: "http://10.0.0.181:9117")!)

        #expect(candidates.first?.absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")
    }

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

    @Test func jackettSingleIndexerEndpointIsUsedVerbatim() {
        let url = URL(string:
            "http://10.0.0.181:9117/api/v2.0/indexers/rutor/results/torznab/api")!

        #expect(TorznabEndpoint.candidates(for: url) == [url])
    }


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
