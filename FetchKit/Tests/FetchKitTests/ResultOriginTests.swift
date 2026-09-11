import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct ResultOriginTests {
    private func magnet(_ hex: String) -> MagnetLink {
        MagnetLink("magnet:?xt=urn:btih:\(hex)")!
    }
    private let hex = String(repeating: "ab", count: 20)


    @Test func aTorrentIsIdentifiedByItsInfoHash() {
        let id = ResultID(origin: .torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil))
        #expect(id.rawValue == "btih:\(hex)")
    }

    @Test func theSameTorrentFromTwoIndexersSharesAnID() {
        let lower = ResultID(origin: .torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil))
        let upper = ResultID(origin: .torrent(
            infoHash: InfoHash(hex.uppercased())!,
            magnet: magnet(hex.uppercased()), targetPath: nil))
        #expect(lower == upper)
    }

    @Test func twoTargetPathsInOneTorrentAreDifferentResults() {
        let a = ResultID(origin: .torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: "a.epub"))
        let b = ResultID(origin: .torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: "b.epub"))
        #expect(a != b)
    }

    @Test func aDirectURLIsIdentifiedByItsURL() {
        let id = ResultID(origin: .direct(url: URL(string: "https://archive.org/x/y.epub")!))
        #expect(id.rawValue.hasPrefix("url:"))
    }

    @Test func urlIdentityIsNormalised() {
        let a = ResultID(origin: .direct(url: URL(string: "https://Archive.ORG/x/y.epub")!))
        let b = ResultID(origin: .direct(url: URL(string: "https://archive.org/x/y.epub")!))
        #expect(a == b)
    }

    @Test func differentURLsGetDifferentIDs() {
        let a = ResultID(origin: .direct(url: URL(string: "https://archive.org/a.epub")!))
        let b = ResultID(origin: .direct(url: URL(string: "https://archive.org/b.epub")!))
        #expect(a != b)
    }

    @Test func hostedAndDirectShareIdentityForTheSameURL() {
        let url = URL(string: "https://mediafire.com/file/x")!
        #expect(ResultID(origin: .direct(url: url))
                == ResultID(origin: .hosted(url: url, host: HostID(rawValue: "mediafire"))))
    }


    @Test func directOutranksHosted() {
        let direct = ResultOrigin.direct(url: URL(string: "https://archive.org/a")!)
        let hosted = ResultOrigin.hosted(
            url: URL(string: "https://mediafire.com/a")!, host: HostID(rawValue: "mediafire"))
        #expect(direct.preferenceRank < hosted.preferenceRank)
    }

    @Test func anUncheckedTorrentRanksBelowDirect() {
        let direct = ResultOrigin.direct(url: URL(string: "https://archive.org/a")!)
        let torrent = ResultOrigin.torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil)
        #expect(direct.preferenceRank < torrent.preferenceRank)
    }


    @Test func aNonHTTPSchemeIsRefused() {
        #expect(ResultOrigin.direct(url: URL(string: "file:///etc/passwd")!).isUsable == false)
        #expect(ResultOrigin.direct(url: URL(string: "ftp://example.com/x")!).isUsable == false)
    }

    @Test func httpsIsUsable() {
        #expect(ResultOrigin.direct(url: URL(string: "https://archive.org/x")!).isUsable)
    }

    @Test func plainHTTPIsUsable() {
        #expect(ResultOrigin.direct(url: URL(string: "http://10.0.0.181/x")!).isUsable)
    }
}

@Suite struct DownloadSourceTests {
    @Test func debridSourcesDoNotCarryAURL() throws {
        let source = DownloadSource.debridTorrent(
            provider: DebridProviderID(rawValue: "torbox"),
            torrent: DebridTorrentID(rawValue: "1"),
            file: DebridFileID(rawValue: "2"))

        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        #expect(!encoded.contains("http"))
    }

    @Test func aDirectSourceRoundTripsItsURL() throws {
        let url = URL(string: "https://archive.org/download/x/y.epub")!
        let source = DownloadSource.directHTTP(url: url)
        let decoded = try JSONDecoder().decode(
            DownloadSource.self, from: try JSONEncoder().encode(source))
        #expect(decoded == source)
    }

    @Test func onlyDebridSourcesNeedPreparing() {
        #expect(DownloadSource.directHTTP(
            url: URL(string: "https://archive.org/x")!).needsPreparing == false)
        #expect(DownloadSource.debridTorrent(
            provider: DebridProviderID(rawValue: "t"),
            torrent: DebridTorrentID(rawValue: "1"),
            file: DebridFileID(rawValue: "2")).needsPreparing)
        #expect(DownloadSource.debridHosted(
            provider: DebridProviderID(rawValue: "t"),
            download: DebridDownloadID(rawValue: "1")).needsPreparing)
    }
}

@Suite struct PolymorphicSearchResultTests {
    private let hex = String(repeating: "cd", count: 20)

    private func torrentResult(hex: String, title: String = "T") -> SearchResult {
        SearchResult(
            infoHashHex: hex, title: title, size: 1, seeders: 1, peers: 0,
            grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hex)", sources: [], rawAttributes: [:])
    }

    @Test func theTorrentInitialiserProducesATorrentCandidate() {
        let result = torrentResult(hex: hex)
        #expect(result.candidates.count == 1)
        #expect(result.infoHashHex == hex)
        #expect(result.magnetURI?.contains(hex) == true)
    }

    @Test func aTorrentResultKeepsItsInfoHashIdentity() {
        #expect(torrentResult(hex: hex).id.rawValue == "btih:\(hex)")
    }

    @Test func aDirectResultHasNoInfoHash() {
        let result = SearchResult(
            candidates: [.direct(url: URL(string: "https://archive.org/x.epub")!)],
            title: "Book", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [], rawAttributes: [:])

        #expect(result.infoHashHex == nil)
        #expect(result.magnetURI == nil)
        #expect(result.id.rawValue.hasPrefix("url:"))
    }

    @Test func aResultWithNoUsableCandidateIsNotUsable() {
        let result = SearchResult(
            candidates: [.direct(url: URL(string: "file:///etc/passwd")!)],
            title: "Nope", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [], rawAttributes: [:])
        #expect(!result.isUsable)
    }

    @Test func aResultWithOneUsableCandidateIsUsable() {
        #expect(torrentResult(hex: hex).isUsable)
    }

    @Test func candidatesAreOrderedBestFirst() {
        let result = SearchResult(
            candidates: [
                .hosted(url: URL(string: "https://mediafire.com/a")!,
                        host: HostID(rawValue: "mediafire")),
                .direct(url: URL(string: "https://archive.org/a")!),
            ],
            title: "Book", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [], rawAttributes: [:])

        #expect(result.candidates.first?.preferenceRank == 0)
    }

    @Test func aTorrentCandidateDefinesIdentityEvenWhenNotRankedFirst() {
        let result = SearchResult(
            candidates: [
                .direct(url: URL(string: "https://archive.org/a")!),
                .torrent(infoHash: InfoHash(hex)!,
                         magnet: MagnetLink("magnet:?xt=urn:btih:\(hex)")!,
                         targetPath: nil),
            ],
            title: "Book", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [], rawAttributes: [:])

        #expect(result.id.rawValue == "btih:\(hex)")
        #expect(result.infoHashHex == hex)
    }

    @Test func twoUnreachableResultsDoNotCollapseIntoOne() {
        func broken(_ title: String) -> SearchResult {
            SearchResult(
                candidates: [], title: title, size: nil, seeders: nil, peers: nil,
                category: nil, publishDate: nil, sources: [], rawAttributes: [:])
        }
        #expect(broken("A").id != broken("B").id)
    }
}

@Suite struct CandidateFormatAndIdentityTests {
    private func magnet(_ hex: String) -> MagnetLink {
        MagnetLink("magnet:?xt=urn:btih:\(hex)")!
    }
    private let hex = String(repeating: "cd", count: 20)

    private func url(_ s: String) -> URL { URL(string: s)! }


    @Test func aDirectCandidateCarriesItsDocumentFormat() {
        let candidate = ResultOrigin.direct(url: url("https://x/84.epub"), format: .epub)
        #expect(candidate.documentFormat == .epub)
    }

    @Test func aTorrentCandidateHasNoDocumentFormat() {
        let candidate = ResultOrigin.torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil)
        #expect(candidate.documentFormat == nil)
    }


    @Test func aSourceKeyedResultKeepsItsIDWhenCandidatesReorder() {
        let epubFirst = SearchResult(
            candidates: [
                .direct(url: url("https://x/84.epub"), format: .epub),
                .direct(url: url("https://x/84.pdf"), format: .pdf),
            ],
            title: "Frankenstein", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [SearchProviderID(rawValue: "gutenberg")],
            sourceKey: "gutenberg:84", rawAttributes: [:])

        let pdfFirst = SearchResult(
            candidates: [
                .direct(url: url("https://x/84.pdf"), format: .pdf),
                .direct(url: url("https://x/84.epub"), format: .epub),
            ],
            title: "Frankenstein", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [SearchProviderID(rawValue: "gutenberg")],
            sourceKey: "gutenberg:84", rawAttributes: [:])

        #expect(epubFirst.id == pdfFirst.id)
    }

    @Test func differentSourceKeysAreDifferentResults() {
        func book(_ key: String) -> SearchResult {
            SearchResult(
                candidates: [.direct(url: url("https://x/\(key).epub"), format: .epub)],
                title: "Book", size: nil, seeders: nil, peers: nil,
                category: nil, publishDate: nil, sources: [], sourceKey: key,
                rawAttributes: [:])
        }
        #expect(book("gutenberg:84").id != book("gutenberg:1342").id)
    }

    @Test func aTorrentCandidateStillOutranksASourceKeyForIdentity() {
        let item = SearchResult(
            candidates: [
                .direct(url: url("https://archive.org/download/goody/goody.mp4")),
                .torrent(infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil),
            ],
            title: "Goody", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [],
            sourceKey: "internet-archive:goody", rawAttributes: [:])

        #expect(item.id.rawValue == "btih:\(hex)")
    }

    @Test func withoutASourceKeyIdentityIsUnchanged() {
        let withKey = SearchResult(
            candidates: [.direct(url: url("https://x/a.epub"), format: .epub)],
            title: "A", size: nil, seeders: nil, peers: nil, category: nil,
            publishDate: nil, sources: [], rawAttributes: [:])

        #expect(withKey.id == ResultID(origin: .direct(url: url("https://x/a.epub"))))
    }

    @Test func formatDoesNotAffectAnOriginsIdentity() {
        let labelled = ResultID(origin: .direct(url: url("https://x/a.epub"), format: .epub))
        let bare = ResultID(origin: .direct(url: url("https://x/a.epub")))
        #expect(labelled == bare)
    }
}
