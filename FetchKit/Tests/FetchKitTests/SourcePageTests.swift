import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Opening the page a result came from.
@Suite struct SourcePageTests {
    private func result(sourceKey: String?, url: String) -> SearchResult {
        SearchResult(
            candidates: [.direct(url: URL(string: url)!)],
            title: "T", size: nil, seeders: nil, peers: nil, category: nil,
            publishDate: nil, sources: [SearchProviderID(rawValue: "s")],
            sourceKey: sourceKey, rawAttributes: [:])
    }

    /// The item page, not the file. Opening the candidate URL would download
    /// the same file again in Safari, which is the one thing a browse action
    /// must not do.
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

    /// A torrent's "source" is an indexer, and its listing URL is not
    /// something a result carries. Better no menu item than one that guesses
    /// at a tracker's URL scheme.
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

    /// Identifiers come from upstream. An unescaped one would quietly build a
    /// URL pointing somewhere other than the item.
    @Test func anIdentifierIsEscaped() {
        let page = SourcePage.url(forSourceKey: "internet-archive:a b/c")
        #expect(page?.absoluteString.contains(" ") == false)
    }
}
