import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stage 7b: the first non-Torznab, non-debrid source.
///
/// Internet Archive is the honest proof of stage 7a — if these results
/// download with no debrid configured, `.direct` genuinely works rather than
/// being a path that happens to compile.
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

    // MARK: - Search

    @Test func searchMapsItemsToResults() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        let results = try await provider().search(SearchQuery(text: "dune"))

        #expect(results.count == 2)
        #expect(results.first?.title == "Dune")
        #expect(results.first?.size == 5_000_000)
    }

    /// Every result is reachable with no debrid at all. This is the assertion
    /// stage 7b exists for.
    @Test func everyResultCarriesADirectCandidate() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        let results = try await provider().search(SearchQuery(text: "dune"))

        for result in results {
            #expect(result.isUsable)
            #expect(result.candidates.contains { if case .direct = $0 { true } else { false } })
        }
    }

    /// An IA item is a *folder*, and its file list costs a second request. The
    /// search result therefore points at the item's details page, and the real
    /// files are fetched only when the user opens it — 50 results must not
    /// mean 50 extra round trips for candidates nobody opens.
    @Test func searchDoesNotFetchFileListsPerResult() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        _ = try await provider().search(SearchQuery(text: "dune"))
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    /// IA has no seeders and no infohash. Both must read as absent rather than
    /// as zero, or a book sorts below every 0-seed torrent and gets a cache
    /// badge it can never resolve.
    @Test func resultsReportNoSeedersAndNoInfoHash() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        let result = try #require(try await provider().search(SearchQuery(text: "d")).first)

        #expect(result.seeders == nil)
        #expect(result.infoHashHex == nil)
        #expect(result.magnetURI == nil)
    }

    /// `mediatype` is IA's own vocabulary and maps onto §8's `MediaKind`, so
    /// IA results rank and route through the same machinery as everything
    /// else rather than needing a special case.
    @Test func mediaTypeMapsOntoMediaKind() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        let results = try await provider().search(SearchQuery(text: "dune"))

        #expect(results.first?.metadata.mediaKind == .book)
        #expect(results.last?.metadata.mediaKind == .software)
    }

    /// A search that matches nothing is an empty list, not an error — the
    /// aggregator renders "no results", and an error would render a failure
    /// banner for a query that simply had no hits.
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

    // MARK: - Item files

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

    /// IA attaches derived and housekeeping files to every item — thumbnails,
    /// `_meta.xml`, `_files.xml`, the torrent. Showing eleven checkboxes for
    /// one book is the picker being useless, so these are filtered.
    @Test func housekeepingFilesAreExcluded() async throws {
        StubURLProtocol.reset([.json(metadataJSON)])
        let names = try await provider().files(inItem: "dune-1965").map(\.name)

        #expect(!names.contains("__ia_thumb.jpg"))
        #expect(!names.contains("dune_meta.xml"))
        #expect(!names.contains("dune_archive.torrent"))
        #expect(names.sorted() == ["dune.epub", "dune.pdf"])
    }

    /// Verified live on 2026-08-02: archive.org generates `<id>_archive.torrent`
    /// for every item, with webseeds back to IA's own servers. That makes an IA
    /// item genuinely multi-candidate — if a debrid already holds it, the file
    /// arrives at CDN speed instead of through IA's rate limiting.
    @Test func theItemsOwnTorrentIsAvailableSeparately() async throws {
        StubURLProtocol.reset([.json(metadataJSON)])
        let url = try await provider().torrentURL(forItem: "dune-1965")
        #expect(url?.absoluteString
                == "https://archive.org/download/dune-1965/dune_archive.torrent")
    }

    /// An item with no `.torrent` is still perfectly downloadable — the direct
    /// candidates are untouched. Only the debrid shortcut is unavailable.
    @Test func anItemWithNoTorrentIsNotAnError() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[{"name":"a.epub","format":"EPUB","size":"10"}]}
        """)])
        #expect(try await provider().torrentURL(forItem: "x") == nil)
    }

    /// IA reports sizes as strings. A file whose size is missing or unparseable
    /// keeps a nil size rather than 0 — `Content-Length` settles it at download
    /// time, and 0 would make the progress bar claim completion instantly.
    @Test func anUnparseableSizeIsNilNotZero() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[{"name":"a.epub","format":"EPUB","source":"original"}]}
        """)])
        #expect(try await provider().files(inItem: "x").first?.size == nil)
    }

    /// **Regression.** An IA item is a folder tree, not a flat list: a 1,786
    /// episode collection stores files as `Show/Season 01/Ep.mkv`. Rejecting
    /// every name containing "/" left one flat .zip out of 8,891 files and
    /// looked like the item only had one thing in it.
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

    /// The rule the previous check should have been: a name may nest, but no
    /// component may be `..` and it may not be absolute. Asserted on where the
    /// URL lands rather than on the string, because that is the property that
    /// actually matters.
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

    /// IA derives extra formats from each upload. Two very different things
    /// hide under that word, and they need different treatment.
    ///
    /// An h.264 `.mp4` beside a `.mkv` is a **real alternative** — often the
    /// one a user wants, since it plays anywhere. A thumbnail strip is not;
    /// it is 106 JPEGs per episode and belongs in no picker. Excluding both
    /// as "derived" is why the mp4s visible on archive.org were missing here.
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

    /// Thumbnails, waveforms and spectrograms are never alternatives. On the
    /// item that exposed this they outnumber the episodes two to one.
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

    /// A file with no `source` is kept. IA sets it on everything today, but an
    /// absent field must not silently empty the picker.
    @Test func aFileWithNoSourceFieldIsKept() async throws {
        StubURLProtocol.reset([.json("""
        {"files":[{"name":"a.epub","format":"EPUB","size":"10"}]}
        """)])
        #expect(try await provider().files(inItem: "x").map(\.name) == ["a.epub"])
    }



    // MARK: - Category scoping

    /// The outgoing `q` parameter, which is where IA scoping lives — it has no
    /// Torznab categories to intersect, so this is the only place a Books
    /// search stops returning films.
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
        // The title scoping must survive: a bare `q=dune` expands to
        // `text:dune OR text__reviews:dune` and returns podcasts.
        #expect(sentLuceneQuery().contains("title:"))
    }

    /// The All pill must not narrow anything.
    @Test func anUncategorisedSearchLeavesMediatypeAlone() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        _ = try await provider().search(SearchQuery(text: "dune"))
        #expect(!sentLuceneQuery().contains("mediatype"))
    }

    /// Anime's only plausible IA mediatype is `movies`, which would return
    /// live-action films under the Anime pill.
    @Test func animeDoesNotConstrainMediatype() async throws {
        StubURLProtocol.reset([.json(searchJSON)])
        _ = try await provider().search(SearchQuery(
            text: "cowboy bebop", categories: SearchCategory.anime.torznabCategories))
        #expect(!sentLuceneQuery().contains("mediatype"))
    }

    /// Pins the category → IA-mediatype mapping for every pill against the
    /// function that actually ships it. This used to be asserted a second
    /// way, against `SearchCategory.archiveMediatype` — a copy of the same
    /// rule with no production caller and nothing tying the two together.
    /// That copy is gone; `mediatype(for:)` is now the mapping's only home,
    /// and this is the one place the full table is pinned.
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
        // Adult is excluded on purpose rather than mapped to nothing: the
        // Internet Archive has no such mediatype, so the pill simply returns
        // nothing from this provider, which is the correct answer and not a
        // gap in the table.
        #expect(expected.map(\.0).sorted(by: { $0.rawValue < $1.rawValue })
                == SearchCategory.allCases.filter { $0 != .adult }
                    .sorted(by: { $0.rawValue < $1.rawValue }),
                "table must cover every pill")
        for (category, mediatype) in expected {
            #expect(InternetArchiveProvider.mediatype(for: category.torznabCategories)
                    == mediatype, "\(category)")
        }
    }

    // MARK: - Capabilities

    /// IA needs no key, so it is always usable — unlike a Torznab indexer,
    /// which cannot answer anything without one.
    @Test func capabilitiesNeedNoNetworkCall() async throws {
        StubURLProtocol.reset([])
        _ = try await provider().capabilities()
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }
}
