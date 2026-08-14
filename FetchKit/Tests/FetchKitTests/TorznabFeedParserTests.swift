import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct TorznabFeedParserTests {
    static let providerID = SearchProviderID(rawValue: "jackett-local")
    static let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    static let hashB = "aa1155ecdc7ca55fb0bbf81323d87062db1f6d99"

    static func rss(_ items: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
          <channel>
            <title>Jackett</title>
            \(items)
          </channel>
        </rss>
        """
    }

    @Test func infohashAttrPreferredWhenMagneturlAgrees() throws {
        let xml = Self.rss("""
        <item>
          <title>The Expanse S03E05 1080p BluRay x265-GROUP</title>
          <link>magnet:?xt=urn:btih:\(Self.hashA)&amp;tr=udp://tracker.example:80</link>
          <pubDate>Wed, 01 Jan 2025 00:00:00 +0000</pubDate>
          <torznab:attr name="seeders" value="42"/>
          <torznab:attr name="peers" value="50"/>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
          <torznab:attr name="magneturl" value="magnet:?xt=urn:btih:\(Self.hashA)&amp;tr=udp://tracker.example:80"/>
          <torznab:attr name="size" value="1234567"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.infoHashHex == Self.hashA)
        #expect(result.seeders == 42)
        #expect(result.peers == 50)
        #expect(result.size == 1_234_567)
        #expect(result.magnetURI?.contains("tracker.example") == true)   // preserved the indexer's own magnet
        #expect(result.sources == [Self.providerID])
    }

    @Test func missingInfohashFallsBackToMagneturl() throws {
        let xml = Self.rss("""
        <item>
          <title>Some Movie 2019 1080p WEB-DL</title>
          <torznab:attr name="magneturl" value="magnet:?xt=urn:btih:\(Self.hashB)&amp;dn=Some+Movie"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.count == 1)
        #expect(results.first?.infoHashHex == Self.hashB)
    }

    @Test func linkAsBareMagnetIsUsedWhenNoAttrsPresent() throws {
        let xml = Self.rss("""
        <item>
          <title>Bare Link Release</title>
          <link>magnet:?xt=urn:btih:\(Self.hashA)</link>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.count == 1)
        #expect(results.first?.infoHashHex == Self.hashA)
    }

    @Test func itemWithNeitherInfohashNorMagnetIsDropped() throws {
        let xml = Self.rss("""
        <item>
          <title>Torrent-file-only release</title>
          <link>https://indexer.example/download/123.torrent</link>
          <torznab:attr name="seeders" value="10"/>
        </item>
        <item>
          <title>Good release</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.count == 1)
        #expect(results.first?.title == "Good release")
    }

    @Test func infohashOnlyResultSynthesizesAMagnet() throws {
        let xml = Self.rss("""
        <item>
          <title>Synth Magnet Release</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        let result = try #require(results.first)
        #expect(result.magnetURI?.hasPrefix("magnet:?xt=urn:btih:\(Self.hashA)") == true)
        #expect(result.magnetURI?.contains("dn=") == true)
        #expect(MagnetLink(result.magnetURI ?? "")?.infoHash.hex == Self.hashA)
    }

    @Test func missingSeedersDefaultsToZeroRatherThanFailing() throws {
        let xml = Self.rss("""
        <item>
          <title>No seeders attr</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.first?.seeders == 0)
    }

    @Test func peersFallsBackToLeechersWhenPeersAbsent() throws {
        let xml = Self.rss("""
        <item>
          <title>Leechers only</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
          <torznab:attr name="leechers" value="7"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.first?.peers == 7)
    }

    @Test func sizeReadFromElementWhenAttrAbsent() throws {
        let xml = Self.rss("""
        <item>
          <title>Size as RSS element</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
          <size>999888</size>
        </item>
        <item>
          <title>Size as torznab attr</title>
          <torznab:attr name="infohash" value="\(Self.hashB)"/>
          <torznab:attr name="size" value="111222"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.first(where: { $0.title == "Size as RSS element" })?.size == 999_888)
        #expect(results.first(where: { $0.title == "Size as torznab attr" })?.size == 111_222)
    }

    @Test func attrSizeTakesPrecedenceOverElementWhenBothPresent() throws {
        let xml = Self.rss("""
        <item>
          <title>Both present</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
          <torznab:attr name="size" value="500"/>
          <size>999</size>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.first?.size == 500)
    }

    @Test func unconsumedAttributesLandInRawAttributesVerbatim() throws {
        let xml = Self.rss("""
        <item>
          <title>Rich attrs</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
          <torznab:attr name="team" value="GROUP"/>
          <torznab:attr name="imdb" value="tt1234567"/>
          <torznab:attr name="resolution" value="1080p"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        let raw = try #require(results.first?.rawAttributes)
        #expect(raw["team"] == "GROUP")
        #expect(raw["imdb"] == "tt1234567")
        #expect(raw["resolution"] == "1080p")
    }

    @Test func categoryResolvedFromSuppliedLookupTable() throws {
        let xml = Self.rss("""
        <item>
          <title>Categorized</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
          <torznab:attr name="category" value="5000"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(
            Data(xml.utf8), providerID: Self.providerID, categoryNames: [5000: "TV"]
        )
        #expect(results.first?.category == TorznabCategory(id: 5000, name: "TV"))
    }

    @Test func categoryFallsBackToSyntheticNameWhenNotInLookup() throws {
        let xml = Self.rss("""
        <item>
          <title>Unknown category</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
          <torznab:attr name="category" value="9999"/>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.first?.category?.id == 9999)
    }

    @Test func pubDateParsesRFC822() throws {
        let xml = Self.rss("""
        <item>
          <title>Dated</title>
          <torznab:attr name="infohash" value="\(Self.hashA)"/>
          <pubDate>Wed, 01 Jan 2025 12:30:00 +0000</pubDate>
        </item>
        """)
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        let date = try #require(results.first?.publishDate)
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        #expect(components.year == 2025)
        #expect(components.month == 1)
        #expect(components.day == 1)
    }

    @Test func malformedXMLSurfacesAsMalformedFeed() {
        let malformed = Data("<rss><channel><item><title>oops".utf8)
        #expect(throws: SearchError.self) {
            _ = try TorznabFeedParser.parse(malformed, providerID: Self.providerID)
        }
    }

    @Test func emptyChannelYieldsEmptyResultsNotAnError() throws {
        let xml = Self.rss("")
        let results = try TorznabFeedParser.parse(Data(xml.utf8), providerID: Self.providerID)
        #expect(results.isEmpty)
    }
}
