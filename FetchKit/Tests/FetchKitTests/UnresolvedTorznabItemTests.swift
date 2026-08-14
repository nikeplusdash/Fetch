import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Feed items whose only pointer is a `.torrent` URL.
///
/// **The result the user was looking for was silently missing.** RuTracker
/// requires a login, so Jackett publishes its items with no `magneturl`, no
/// `infohash` attribute, and a `<link>` at its own `/dl/rutracker/…` endpoint —
/// verified live. The parser dropped every one of them, and a search for
/// "3 Body Problem" returned nine results with the soundtrack absent.
@Suite struct UnresolvedTorznabItemTests {
    private let provider = SearchProviderID(rawValue: "rutracker")

    private func feed(link: String, extra: String = "") -> Data {
        Data("""
        <rss xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel><item>
          <title>[TR24][OF][FM] Ramin Djawadi - 3 Body Problem</title>
          <link>\(link)</link>
          <size>649871360</size>
          <torznab:attr name="seeders" value="5" />
          <torznab:attr name="peers" value="6" />
          <torznab:attr name="category" value="3000" />
          \(extra)
        </item></channel></rss>
        """.utf8)
    }

    private let jackettDownload =
        "http://10.0.0.181:9117/dl/rutracker/?jackett_apikey=abc&amp;path=xyz&amp;file=t.torrent"

    @Test func anItemWithOnlyATorrentURLIsCarriedOutRatherThanDropped() throws {
        let parsed = try TorznabFeedParser.parseFeed(
            feed(link: jackettDownload), providerID: provider)
        #expect(parsed.results.isEmpty)
        #expect(parsed.unresolved.count == 1)

        let item = try #require(parsed.unresolved.first)
        // Everything the feed said is kept, so resolving costs one fetch and
        // nothing is parsed twice.
        #expect(item.title.contains("Ramin Djawadi"))
        #expect(item.size == 649_871_360)
        #expect(item.seeders == 5)
        #expect(item.peers == 6)
        #expect(item.category?.id == 3000)
        #expect(item.torrentURL.absoluteString.contains("/dl/rutracker/"))
    }

    /// An item that *does* carry a hash must not be diverted into the slow
    /// path — that would turn every ordinary result into an extra request.
    @Test func anItemWithAnInfohashIsStillAnOrdinaryResult() throws {
        let parsed = try TorznabFeedParser.parseFeed(
            feed(
                link: jackettDownload,
                extra: #"<torznab:attr name="infohash" value="\#(String(repeating: "a", count: 40))" />"#),
            providerID: provider)
        #expect(parsed.results.count == 1)
        #expect(parsed.unresolved.isEmpty)
    }

    @Test func aMagnetLinkIsStillAnOrdinaryResult() throws {
        let parsed = try TorznabFeedParser.parseFeed(
            feed(link: "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))"),
            providerID: provider)
        #expect(parsed.results.count == 1)
        #expect(parsed.unresolved.isEmpty)
    }

    /// Origins are attacker-controlled strings. A `file:` link naming a path on
    /// the user's own disk must not become something Fetch will go and fetch.
    @Test func aNonHTTPLinkIsNotSomethingToGoAndFetch() throws {
        let parsed = try TorznabFeedParser.parseFeed(
            feed(link: "file:///etc/passwd"), providerID: provider)
        #expect(parsed.results.isEmpty)
        #expect(parsed.unresolved.isEmpty)
    }

    /// `parse` is the old entry point and keeps its old contract, so nothing
    /// that only wants results has to learn about the second list.
    @Test func theResultsOnlyEntryPointIgnoresTheUnresolved() throws {
        let results = try TorznabFeedParser.parse(
            feed(link: jackettDownload), providerID: provider)
        #expect(results.isEmpty)
    }

    // MARK: - Becoming a result

    /// Built here so the bytes are known, the same way `TorrentFileTests`
    /// builds its fixtures.
    private func bencode(_ value: Any) -> Data {
        switch value {
        case let n as Int:
            return Data("i\(n)e".utf8)
        case let s as String:
            let bytes = Data(s.utf8)
            return Data("\(bytes.count):".utf8) + bytes
        case let dict as [(String, Any)]:
            return Data("d".utf8)
                + dict.map { bencode($0.0) + bencode($0.1) }.reduce(Data(), +)
                + Data("e".utf8)
        case let list as [Any]:
            return Data("l".utf8) + list.map(bencode).reduce(Data(), +) + Data("e".utf8)
        default:
            fatalError("unbencodable fixture")
        }
    }

    /// A real, tiny torrent: one file, one tracker.
    private var torrentBytes: Data {
        bencode([
            ("announce", "udp://tracker.opentrackr.org:1337/announce"),
            ("info", [
                ("length", 649_871_360),
                ("name", "Ramin Djawadi - 3 Body Problem"),
                ("piece length", 262_144),
                ("pieces", "0123456789abcdefghij"),
            ] as [(String, Any)]),
        ] as [(String, Any)])
    }

    @Test func aResolvedItemKeepsTheFeedsFactsAndGainsTheTorrentsHash() throws {
        let parsed = try TorznabFeedParser.parseFeed(
            feed(link: jackettDownload), providerID: provider)
        let item = try #require(parsed.unresolved.first)
        let torrent = try #require(TorrentFile.parse(torrentBytes))

        let result = try #require(item.resolved(with: torrent))
        #expect(result.infoHashHex == torrent.infoHash.hex)
        #expect(result.infoHashHex?.count == 40)
        #expect(result.magnetURI?.contains(torrent.infoHash.hex) == true)
        // The feed's facts, not the torrent's: the tracker knows the seeder
        // count and the release name it publishes under.
        #expect(result.title.contains("Ramin Djawadi"))
        #expect(result.size == 649_871_360)
        #expect(result.seeders == 5)
        #expect(result.category?.id == 3000)
        #expect(result.sources == [provider])
    }

    /// The cap keeps the results most likely to be wanted, rather than
    /// whichever the tracker happened to list first.
    @Test func theFetchBudgetIsSpentOnTheBestSeededItems() {
        #expect(TorrentFileResolver.maxItems > 0)
        #expect(TorrentFileResolver.maxConcurrent > 0)
        // The fan-out already runs every indexer at once, so this multiplies.
        // Eleven indexers times this is what one server sees.
        #expect(TorrentFileResolver.maxConcurrent <= 4)
    }
}
