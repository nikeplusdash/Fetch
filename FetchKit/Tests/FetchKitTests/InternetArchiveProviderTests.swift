import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct InternetArchiveProviderTests {
    private func provider() -> InternetArchiveProvider {
        InternetArchiveProvider(client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private let searchJSON = """
    {"response":{"numFound":2,"start":0,"docs":[
      {"identifier":"dune-1965","title":"Dune","mediatype":"texts",
       "item_size":5000000,"creator":"Frank Herbert","year":1965,"downloads":99406},
      {"identifier":"msdos_Dune_1992","title":"Dune (1992)","mediatype":"software",
       "item_size":8000000,"creator":"Cryo","year":1992,"downloads":313445}
    ]}}
    """


    @Test func searchMapsItemsToResults() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        let results = try await provider().search(SearchQuery(text: "dune"))

        #expect(results.count == 2)
        #expect(results.first?.title == "Dune")
        #expect(results.first?.size == 5_000_000)
    }

    @Test func everyResultCarriesADirectCandidate() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        let results = try await provider().search(SearchQuery(text: "dune"))

        for result in results {
            #expect(result.isUsable)
            #expect(result.candidates.contains { if case .direct = $0 { true } else { false } })
        }
    }

    @Test func searchDoesNotFetchFileListsPerResult() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        _ = try await provider().search(SearchQuery(text: "dune"))
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func resultsReportNoSeedersAndNoInfoHash() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        let result = try #require(try await provider().search(SearchQuery(text: "d")).first)

        #expect(result.seeders == nil)
        #expect(result.infoHashHex == nil)
        #expect(result.magnetURI == nil)
    }

    @Test func mediaTypeMapsOntoMediaKind() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        let results = try await provider().search(SearchQuery(text: "dune"))

        #expect(results.first?.metadata.mediaKind == .book)
        #expect(results.last?.metadata.mediaKind == .software)
    }

    @Test func noHitsIsNotAFailure() async throws {
        StubURLProtocol.reset([.json("""
        {"response":{"numFound":0,"start":0,"docs":[]}}
        """)])
        #expect(try await provider().search(SearchQuery(text: "zzz")).isEmpty)
    }

    @Test func malformedJSONFails() async {
        StubURLProtocol.reset([.json("not json")])
        await #expect(throws: (any Error).self) {
            _ = try await self.provider().search(SearchQuery(text: "x"))
        }
    }


    private let metadataJSON = """
    {"server":"ia600700.us.archive.org","dir":"/7/items/dune-1965",
     "files":[
      {"name":"__ia_thumb.jpg","format":"Item Tile","size":"12994","source":"original"},
      {"name":"dune.epub","format":"EPUB","size":"6089045","source":"original"},
      {"name":"dune.pdf","format":"Text PDF","size":"5544581","source":"original"},
      {"name":"dune_archive.torrent","format":"Archive BitTorrent","size":"6961","source":"original"},
      {"name":"dune_meta.xml","format":"Metadata","size":"800","source":"metadata"}
     ]}
    """

    @Test func itemFilesAreListedWithDownloadURLs() async throws {
        StubURLProtocol.reset([.json(metadataJSON)])
        let files = try await provider().files(inItem: "dune-1965")

        #expect(files.contains { $0.name == "dune.epub" })
        #expect(files.first { $0.name == "dune.epub" }?.size == 6_089_045)
        #expect(files.first { $0.name == "dune.epub" }?.url.absoluteString
                == "https://archive.org/download/dune-1965/dune.epub")
    }

    @Test func housekeepingFilesAreExcluded() async throws {
        StubURLProtocol.reset([.json(metadataJSON)])
        let names = try await provider().files(inItem: "dune-1965").map(\.name)

        #expect(!names.contains("__ia_thumb.jpg"))
        #expect(!names.contains("dune_meta.xml"))
        #expect(!names.contains("dune_archive.torrent"))
        #expect(names.sorted() == ["dune.epub", "dune.pdf"])
    }

    @Test func theItemsOwnTorrentIsAvailableSeparately() async throws {
        StubURLProtocol.reset([.json(metadataJSON)])
        let url = try await provider().torrentURL(forItem: "dune-1965")
        #expect(url?.absoluteString
                == "https://archive.org/download/dune-1965/dune_archive.torrent")
    }

    @Test func anItemWithNoTorrentIsNotAnError() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[{"name":"a.epub","format":"EPUB","size":"10"}]}
        """)])
        #expect(try await provider().torrentURL(forItem: "x") == nil)
    }

    @Test func anUnparseableSizeIsNilNotZero() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[{"name":"a.epub","format":"EPUB","source":"original"}]}
        """)])
        #expect(try await provider().files(inItem: "x").first?.size == nil)
    }

    @Test func nestedPathsAreKept() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[{"name":"Show/Season 01/Ep01.mkv","format":"Matroska",
                   "size":"100","source":"original"}]}
        """)])
        let file = try #require(try await provider().files(inItem: "x").first)

        #expect(file.name == "Show/Season 01/Ep01.mkv")
        #expect(file.url.absoluteString
                == "https://archive.org/download/x/Show/Season%2001/Ep01.mkv")
    }

    @Test func aPathEscapingItsItemIsRejected() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[{"name":"../../etc/passwd","format":"X","size":"1","source":"original"},
                  {"name":"/etc/passwd","format":"X","size":"1","source":"original"},
                  {"name":"a/../../b.mkv","format":"X","size":"1","source":"original"},
                  {"name":"ok/fine.epub","format":"EPUB","size":"1","source":"original"}]}
        """)])
        let files = try await provider().files(inItem: "x")

        #expect(files.map(\.name) == ["ok/fine.epub"])
        for file in files {
            #expect(file.url.absoluteString.hasPrefix("https://archive.org/download/x/"))
        }
    }

    @Test func derivedMediaIsKeptButMarked() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[
          {"name":"Ep01.mkv","format":"Matroska","size":"100","source":"original"},
          {"name":"Ep01.mp4","format":"h.264","size":"120","source":"derivative",
           "original":"Ep01.mkv"},
          {"name":"Ep01.thumbs/Ep01_000001.jpg","format":"Thumbnail","size":"9",
           "source":"derivative","original":"Ep01.mkv"}
        ]}
        """)])
        let files = try await provider().files(inItem: "x")

        #expect(files.map(\.name).sorted() == ["Ep01.mkv", "Ep01.mp4"])
        #expect(files.first { $0.name == "Ep01.mkv" }?.isDerived == false)
        #expect(files.first { $0.name == "Ep01.mp4" }?.isDerived == true)
    }

    @Test func previewArtefactsAreAlwaysExcluded() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[
          {"name":"a.mkv","format":"Matroska","size":"100","source":"original"},
          {"name":"a.thumbs/x.jpg","format":"Thumbnail","size":"9","source":"derivative"},
          {"name":"a.png","format":"Spectrogram","size":"9","source":"derivative"},
          {"name":"a_peaks.json","format":"Columbia Peaks","size":"9","source":"derivative"},
          {"name":"a.gif","format":"Animated GIF","size":"9","source":"derivative"}
        ]}
        """)])
        #expect(try await provider().files(inItem: "x").map(\.name) == ["a.mkv"])
    }

    @Test func aFileWithNoSourceFieldIsKept() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[{"name":"a.epub","format":"EPUB","size":"10"}]}
        """)])
        #expect(try await provider().files(inItem: "x").map(\.name) == ["a.epub"])
    }


    private func sentLuceneQuery() -> String {
        guard let url = StubURLProtocol.recordedRequests().last?.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return "" }
        return components.queryItems?.first { $0.name == "q" }?.value ?? ""
    }

    @Test func aCategorisedSearchConstrainsMediatype() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        _ = try await provider().search(SearchQuery(
            text: "dune", categories: SearchCategory.books.torznabCategories))

        #expect(sentLuceneQuery().contains("mediatype:(texts)"))
        #expect(sentLuceneQuery().contains("title:"))
    }

    @Test func anUncategorisedSearchLeavesMediatypeAlone() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        _ = try await provider().search(SearchQuery(text: "dune"))
        #expect(!sentLuceneQuery().contains("mediatype"))
    }

    @Test func animeDoesNotConstrainMediatype() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        _ = try await provider().search(SearchQuery(
            text: "cowboy bebop", categories: SearchCategory.anime.torznabCategories))
        #expect(!sentLuceneQuery().contains("mediatype"))
    }

    @Test func mediatypeMatchesEveryPill() {
        let expected: [(SearchCategory, String?)] = [
            (.all, nil),
            (.movies, "movies"),
            (.tv, "movies"),
            (.anime, nil),
            (.music, "audio"),
            (.books, "texts"),
            (.software, "software"),
            (.games, "software"),
        ]
        #expect(expected.map(\.0).sorted(by: { $0.rawValue < $1.rawValue })
                == SearchCategory.allCases.filter { $0 != .adult }
                    .sorted(by: { $0.rawValue < $1.rawValue }),
                "table must cover every pill")
        for (category, mediatype) in expected {
            #expect(InternetArchiveProvider.mediatype(for: category.torznabCategories)
                    == mediatype, "\(category)")
        }
    }


    @Test func capabilitiesNeedNoNetworkCall() async throws {
        StubURLProtocol.reset([])
        _ = try await provider().capabilities()
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }
}
