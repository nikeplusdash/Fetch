import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct PerKindRankingTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    private func book(
        _ title: String, format: DocumentFormat = .epub, downloads: Int? = nil,
        key: String? = nil
    ) -> SearchResult {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .book
        m.title = title
        m.documentFormat = format
        return SearchResult(
            candidates: [.direct(url: url("https://g/\(title).\(format)"), format: format)],
            title: title, size: nil, seeders: nil, peers: nil, grabs: downloads,
            category: nil, publishDate: nil,
            sources: [SearchProviderID(rawValue: "gutenberg")],
            sourceKey: key ?? "gutenberg:\(title)", rawAttributes: [:], metadata: m)
    }

    private func torrent(
        _ title: String, seeders: Int = 100, resolution: Resolution? = .r1080p,
        source: ReleaseSource? = .webdl, kind: MediaKind = .movie
    ) -> SearchResult {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = kind
        m.resolution = resolution
        m.source = source
        let hash = String(title.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
            .padding(toLength: 40, withPad: "0", startingAt: 0))
        return SearchResult(
            infoHashHex: hash, title: title, size: 1_000_000_000, seeders: seeders,
            peers: 0, grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [SearchProviderID(rawValue: "ix")], rawAttributes: [:], metadata: m)
    }


    @Test func aBookIsNotOutrankedByAnUnrelatedTorrentWithSeeders() {
        let ranked = QualityProfile.default.rank(
            [torrent("Some Other Film 1080p", seeders: 5_000), book("Dune")],
            matching: "Dune")

        #expect(ranked.first?.title == "Dune")
    }

    @Test func aLowerNameBucketNeverOutranksAHigherOne() {
        let ranked = QualityProfile.default.rank(
            [torrent("Dune Part Two 2160p", seeders: 9_000, resolution: .r2160p, source: .remux),
             book("Dune")],
            matching: "Dune")

        #expect(ranked.first?.title == "Dune")
    }

    @Test func withinABucketQualityStillDecides() {
        let remux = torrent("Dune", seeders: 40, resolution: .r1080p, source: .remux)
        let rip = torrent("Dune", seeders: 400, resolution: .r720p, source: .webrip)

        let ranked = QualityProfile.default.rank([rip, remux], matching: "Dune")
        #expect(ranked.first?.metadata.source == .remux)
    }


    @Test func aBookRanksOnItsFormat() {
        let ranked = QualityProfile.default.rank(
            [book("Dune", format: .pdf, key: "a"), book("Dune", format: .epub, key: "b")],
            matching: "Dune")

        #expect(ranked.first?.metadata.documentFormat == .epub)
    }

    @Test func musicRanksOnItsCodec() {
        func album(_ title: String, codec: AudioCodec) -> SearchResult {
            var m = ReleaseMetadata.unparsed
            m.mediaKind = .music
            m.audioCodec = codec
            return SearchResult(
                candidates: [.direct(url: url("https://m/\(title)"))],
                title: title, size: nil, seeders: nil, peers: nil,
                category: nil, publishDate: nil, sources: [],
                sourceKey: title, rawAttributes: [:], metadata: m)
        }
        let ranked = QualityProfile.default.rank(
            [album("mp3", codec: .mp3), album("flac", codec: .flac)], matching: "")

        #expect(ranked.first?.title == "flac")
    }

    @Test func videoOrderingIsUnchangedByNormalisation() {
        let uhd = torrent("a", seeders: 10, resolution: .r2160p, source: .webdl)
        let hd = torrent("b", seeders: 10, resolution: .r1080p, source: .webdl)

        #expect(QualityProfile.default.rank([hd, uhd], matching: "").first?.title == "a")
    }

    @Test func anUnmappedKindRanksOnPopularityRatherThanSinking() {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .software
        func app(_ title: String, downloads: Int) -> SearchResult {
            SearchResult(
                candidates: [.direct(url: url("https://s/\(title)"))],
                title: title, size: nil, seeders: nil, peers: nil, grabs: downloads,
                category: nil, publishDate: nil, sources: [], sourceKey: title,
                rawAttributes: [:], metadata: m)
        }
        let ranked = QualityProfile.default.rank(
            [app("quiet", downloads: 3), app("popular", downloads: 90_000)], matching: "")

        #expect(ranked.first?.title == "popular")
    }


    @Test func downloadsStandInForSeeders() {
        let ranked = QualityProfile.default.rank(
            [book("Dune", downloads: 5, key: "a"), book("Dune", downloads: 80_000, key: "b")],
            matching: "Dune")

        #expect(ranked.first?.grabs == 80_000)
    }

    @Test func popularityDoesNotOverwhelmFormat() {
        let ranked = QualityProfile.default.rank(
            [book("Dune", format: .pdf, downloads: 500_000, key: "a"),
             book("Dune", format: .epub, downloads: 10, key: "b")],
            matching: "Dune")

        #expect(ranked.first?.metadata.documentFormat == .epub)
    }


    @Test func rejectedTokensStillFilterAndAreStillSurfaced() {
        let cam = torrent("Dune", seeders: 10, resolution: .r1080p, source: .cam)
        let outcome = QualityProfile.default.apply(to: [cam], matching: "Dune")

        #expect(outcome.accepted.isEmpty)
        #expect(outcome.rejected.count == 1)
    }


    @Test func tiesAreBrokenReproducibly() {
        let a = book("Dune", key: "gutenberg:1")
        let b = book("Dune", key: "gutenberg:2")

        let first = QualityProfile.default.rank([a, b], matching: "Dune").map(\.id)
        let second = QualityProfile.default.rank([b, a], matching: "Dune").map(\.id)
        #expect(first == second)
    }
}

@Suite(.serialized, .usesStubURLProtocol) struct ProviderRankingInputsTests {

    private let onePage = """
    {"count":1,"next":null,"previous":null,"results":[
      {"id":84,"title":"Frankenstein","download_count":91234,
       "authors":[{"name":"Shelley, Mary"}],"languages":["en"],
       "formats":{
         "application/epub+zip":"https://www.gutenberg.org/ebooks/84.epub3.images",
         "application/x-mobipocket-ebook":"https://www.gutenberg.org/ebooks/84.kf8.images",
         "text/plain; charset=utf-8":"https://www.gutenberg.org/ebooks/84.txt.utf-8"}}
    ]}
    """

    private func gutenbergBook() async throws -> SearchResult {
        StubURLProtocol.reset([.json(onePage)])
        let provider = GutenbergProvider(client: HTTPClient(session: StubURLProtocol.makeSession()))
        return try #require(try await provider.search(SearchQuery(text: "frank")).first)
    }

    @Test func gutenbergPublishesItsDownloadCountAsGrabs() async throws {
        #expect(try await gutenbergBook().grabs == 91_234)
    }

    @Test func gutenbergSuppliesAStableSourceKey() async throws {
        #expect(try await gutenbergBook().sourceKey == "gutenberg:84")
    }

    @Test func gutenbergLabelsEachCandidateWithItsFormat() async throws {
        let formats = try await gutenbergBook().candidates.map(\.documentFormat)

        #expect(formats.allSatisfy { $0 != nil })
        #expect(Set(formats.compactMap { $0 }) == [.epub, .azw3, .text])
    }


    private let oneItem = """
    {"response":{"numFound":1,"start":0,"docs":[
      {"identifier":"goody","title":"Goody","mediatype":"movies",
       "downloads":54321,"item_size":1234}]}}
    """

    private func archiveItem() async throws -> SearchResult {
        StubURLProtocol.reset([.json(oneItem)])
        let provider = InternetArchiveProvider(
            client: HTTPClient(session: StubURLProtocol.makeSession()))
        return try #require(try await provider.search(SearchQuery(text: "goody")).first)
    }

    @Test func archivePublishesItsDownloadCountAsGrabs() async throws {
        #expect(try await archiveItem().grabs == 54_321)
    }

    @Test func archiveSuppliesAStableSourceKey() async throws {
        #expect(try await archiveItem().sourceKey == "internet-archive:goody")
    }
}
