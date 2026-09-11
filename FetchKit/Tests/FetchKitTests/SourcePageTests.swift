import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct SourcePageTests {
    private func result(sourceKey: String?, url: String) -> SearchResult {
        SearchResult(
            candidates: [.direct(url: URL(string: url)!)],
            title: "T", size: nil, seeders: nil, peers: nil, category: nil,
            publishDate: nil, sources: [SearchProviderID(rawValue: "s")],
            sourceKey: sourceKey, rawAttributes: [:])
    }

    @Test func anArchiveItemOpensItsDetailsPage() {
        let page = SourcePage.url(for: result(
            sourceKey: "internet-archive:goody",
            url: "https://archive.org/download/goody/goody.mp4"))
        #expect(page?.absoluteString == "https://archive.org/details/goody")
    }

    @Test func aGutenbergBookOpensItsEbookPage() {
        let page = SourcePage.url(for: result(
            sourceKey: "gutenberg:84",
            url: "https://www.gutenberg.org/ebooks/84.epub3.images"))
        #expect(page?.absoluteString == "https://www.gutenberg.org/ebooks/84")
    }

    @Test func aTorrentHasNoPage() {
        let torrent = SearchResult(
            infoHashHex: String(repeating: "a", count: 40), title: "T", size: 1,
            seeders: 1, peers: 0, grabs: nil, fileCount: nil, category: nil,
            publishDate: nil, magnetURI: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))",
            sources: [SearchProviderID(rawValue: "x")], rawAttributes: [:])
        #expect(SourcePage.url(for: torrent) == nil)
    }

    @Test func anUnknownProviderHasNoPage() {
        #expect(SourcePage.url(forSourceKey: "annas-archive:123") == nil)
        #expect(SourcePage.url(forSourceKey: "nocolon") == nil)
        #expect(SourcePage.url(forSourceKey: "gutenberg:") == nil)
    }

    @Test func anIdentifierIsEscaped() {
        let page = SourcePage.url(forSourceKey: "internet-archive:a b/c")
        #expect(page?.absoluteString.contains(" ") == false)
    }
}
