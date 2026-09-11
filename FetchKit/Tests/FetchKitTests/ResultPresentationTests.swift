import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

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

    @Test func internetArchiveOutranksGutenbergWhenAResultClaimsBoth() {
        let both = SearchResult(
            candidates: [.direct(url: URL(string: "https://archive.org/details/dune-1965")!)],
            title: "A Result", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil,
            sources: [GutenbergProvider.providerID, InternetArchiveProvider.providerID],
            rawAttributes: [:], metadata: .unparsed)

        #expect(ResultPresentation.of(both) == .archiveItem)
    }

    @Test func anUnknownDirectSourceDownloadsRatherThanOpeningAnotherSourcesSheet() {
        let hosted = direct(
            "https://example.com/file.bin",
            source: SearchProviderID(rawValue: "some-future-hoster"))

        #expect(ResultPresentation.of(hosted) == .directDownload)
    }

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
