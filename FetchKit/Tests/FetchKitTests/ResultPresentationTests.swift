import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stage 7c §7. `SearchView` chose its sheet with `infoHashHex == nil`, which
/// every Gutenberg result and every future hoster result also satisfies — so
/// a book opened the Internet Archive picker and failed on a missing
/// identifier. The condition tested the absence of a field instead of what the
/// result is.
@Suite struct ResultPresentationTests {
    private func direct(
        _ urlString: String, source: SearchProviderID, attributes: [String: String] = [:]
    ) -> SearchResult {
        SearchResult(
            candidates: [.direct(url: URL(string: urlString)!)],
            title: "A Result", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [source],
            rawAttributes: attributes, metadata: .unparsed)
    }

    @Test func aTorrentOpensTheFilePicker() {
        let torrent = SearchResult(
            infoHashHex: String(repeating: "a", count: 40),
            title: "Some Release", size: 100, seeders: 1, peers: 1,
            grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))",
            sources: [SearchProviderID(rawValue: "jackett")], rawAttributes: [:])

        #expect(ResultPresentation.of(torrent) == .torrentPicker)
    }

    @Test func anInternetArchiveItemOpensTheArchiveSheet() {
        let item = direct(
            "https://archive.org/details/dune-1965",
            source: InternetArchiveProvider.providerID,
            attributes: ["identifier": "dune-1965"])

        #expect(ResultPresentation.of(item) == .archiveItem)
    }

    @Test func aGutenbergBookOpensTheFormatPanel() {
        let book = direct(
            "https://www.gutenberg.org/ebooks/84.epub3.images",
            source: GutenbergProvider.providerID,
            attributes: ["gutenbergID": "84"])

        #expect(ResultPresentation.of(book) == .bookFormats)
    }

    /// Pins the IA-before-Gutenberg branch order in `of(_:)`. `sources` lists
    /// Gutenberg first here on purpose: if the two `if` branches were ever
    /// swapped, this would flip to `.bookFormats` and catch it, whereas
    /// checking IA-then-Gutenberg with IA listed first in `sources` would
    /// pass either way and prove nothing about which branch actually ran.
    @Test func internetArchiveOutranksGutenbergWhenAResultClaimsBoth() {
        let both = SearchResult(
            candidates: [.direct(url: URL(string: "https://archive.org/details/dune-1965")!)],
            title: "A Result", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil,
            sources: [GutenbergProvider.providerID, InternetArchiveProvider.providerID],
            rawAttributes: [:], metadata: .unparsed)

        #expect(ResultPresentation.of(both) == .archiveItem)
    }

    /// The case that makes this a decision rather than a lookup: a direct
    /// result from a source with no sheet of its own is still downloadable.
    /// Opening someone else's picker is what the old condition did.
    @Test func anUnknownDirectSourceDownloadsRatherThanOpeningAnotherSourcesSheet() {
        let hosted = direct(
            "https://example.com/file.bin",
            source: SearchProviderID(rawValue: "some-future-hoster"))

        #expect(ResultPresentation.of(hosted) == .directDownload)
    }

    /// A torrent candidate decides the presentation even when a direct
    /// candidate sorts ahead of it — the picker is the only sheet that can
    /// choose a file inside a torrent.
    @Test func aTorrentCandidateWinsEvenWhenItSortsLast() {
        let mixed = SearchResult(
            candidates: [
                .direct(url: URL(string: "https://example.com/a.bin")!),
                .torrent(
                    infoHash: InfoHash(String(repeating: "b", count: 40))!,
                    magnet: MagnetLink("magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))")!,
                    targetPath: nil),
            ],
            title: "Both", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil,
            sources: [InternetArchiveProvider.providerID],
            rawAttributes: [:], metadata: .unparsed)

        #expect(ResultPresentation.of(mixed) == .torrentPicker)
    }
}
