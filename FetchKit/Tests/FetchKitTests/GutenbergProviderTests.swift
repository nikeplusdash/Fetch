import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stage 7c §2. The second keyless source, and the cleanest test of `.direct`:
/// one file per result, no debrid, no account, no picker required.
@Suite(.serialized, .usesStubURLProtocol) struct GutenbergProviderTests {
    private func provider(
        languages: [String] = [],
        includesSupplementary: Bool = false
    ) -> GutenbergProvider {
        GutenbergProvider(
            client: HTTPClient(session: StubURLProtocol.makeSession()),
            languages: languages,
            includesSupplementary: includesSupplementary)
    }

    /// Book 84 as the live API returns it, trimmed to the fields Fetch reads.
    private let onePage = """
    {"count":1,"next":null,"previous":null,"results":[
      {"id":84,"title":"Frankenstein; or, the Modern Prometheus",
       "authors":[{"name":"Shelley, Mary Wollstonecraft","birth_year":1797,"death_year":1851}],
       "languages":["en"],"download_count":58824,
       "formats":{
         "text/html":"https://www.gutenberg.org/ebooks/84.html.images",
         "application/epub+zip":"https://www.gutenberg.org/ebooks/84.epub3.images",
         "application/x-mobipocket-ebook":"https://www.gutenberg.org/ebooks/84.kf8.images",
         "application/rdf+xml":"https://www.gutenberg.org/ebooks/84.rdf",
         "image/jpeg":"https://www.gutenberg.org/cache/epub/84/pg84.cover.medium.jpg",
         "application/octet-stream":"https://www.gutenberg.org/cache/epub/84/pg84-h.zip",
         "text/plain; charset=utf-8":"https://www.gutenberg.org/ebooks/84.txt.utf-8"}}
    ]}
    """

    // MARK: - Mapping

    @Test func searchMapsBooksToResults() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let results = try await provider().search(SearchQuery(text: "frankenstein"))

        let book = try #require(results.first)
        #expect(results.count == 1)
        #expect(book.title == "Frankenstein; or, the Modern Prometheus")
        #expect(book.metadata.mediaKind == .book)
        #expect(book.metadata.author == "Mary Wollstonecraft Shelley")
        #expect(book.metadata.languages == ["en"])
    }

    /// Absent, not zero. The catalogue publishes no size and a book has no
    /// seeders; `0` would sort it below every torrent and make a progress bar
    /// claim completion before a byte arrived.
    @Test func sizeAndSeedersAreAbsentRatherThanZero() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let book = try #require(try await provider().search(SearchQuery(text: "f")).first)

        #expect(book.size == nil)
        #expect(book.seeders == nil)
        #expect(book.peers == nil)
    }

    /// The assertion this stage exists for: reachable with no debrid at all.
    @Test func everyCandidateIsDirect() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let book = try #require(try await provider().search(SearchQuery(text: "f")).first)

        #expect(!book.candidates.isEmpty)
        #expect(book.candidates.allSatisfy { if case .direct = $0 { true } else { false } })
        #expect(book.infoHashHex == nil)
    }

    /// Seven entries in, five candidates out; seven when the user opts in,
    /// with the cover and the RDF last in both.
    @Test func supplementaryFilesAreOptionalAndNeverFirst() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let withoutExtras = try #require(try await provider().search(SearchQuery(text: "f")).first)
        #expect(withoutExtras.candidates.count == 5)

        StubURLProtocol.reset([.json(onePage)])
        let withExtras = try #require(
            try await provider(includesSupplementary: true)
                .search(SearchQuery(text: "f")).first)
        #expect(withExtras.candidates.count == 7)
        #expect(withExtras.candidates.first?.url?.absoluteString.hasSuffix(".epub3.images") == true)
        #expect(withExtras.candidates.last?.url?.absoluteString.hasSuffix(".rdf") == true)
    }

    /// `candidates[0]` is what a download with no UI takes, and since 7d the
    /// *profile* decides it, not the provider — end to end, through the same
    /// pipeline the app runs. This replaces a test of the provider's own
    /// `formatPriority`, which no longer exists: preference applied at parse
    /// time is exactly what stopped a settings change from reordering results
    /// already on screen.
    @Test func candidateOrderFollowsTheProfileNotTheProvider() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let fromProvider = try await provider().search(SearchQuery(text: "f"))

        var plainTextFirst = QualityProfile.default
        plainTextFirst.documentFormatOrder = [.text, .epub, .azw3, .html]

        let ranked = try #require(SearchAggregator.pipeline(
            fromProvider, profile: plainTextFirst, matching: "").accepted.first)

        #expect(ranked.candidates.first?.url?.absoluteString.hasSuffix(".txt.utf-8") == true)
        #expect(ranked.metadata.documentFormat == .text)
    }

    /// And the same results, re-ranked by a different profile, put a
    /// different candidate first — without either run changing the book's
    /// identity.
    @Test func rerankingTheSameResultsChangesTheWinnerButNotTheID() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let fromProvider = try await provider().search(SearchQuery(text: "f"))

        var epubFirst = QualityProfile.default
        epubFirst.documentFormatOrder = [.epub, .text]
        var textFirst = QualityProfile.default
        textFirst.documentFormatOrder = [.text, .epub]

        let a = try #require(SearchAggregator.pipeline(
            fromProvider, profile: epubFirst, matching: "").accepted.first)
        let b = try #require(SearchAggregator.pipeline(
            fromProvider, profile: textFirst, matching: "").accepted.first)

        #expect(a.metadata.documentFormat == .epub)
        #expect(b.metadata.documentFormat == .text)
        #expect(a.id == b.id)
    }

    /// The claim `searchMapsBooksToResults` only makes at the provider layer,
    /// carried to where it is spent. Between the two sits
    /// `SearchAggregator.parse`, which used to rebuild metadata from the title
    /// parse — "Frankenstein" has no year, no season and no format token, so
    /// it parsed as `.other` and the EPUB routed to `Other/`. This asserts the
    /// value `AppModel.subfolder(for:)` actually reads.
    @Test func aBookStillRoutesToBooksAfterTheAggregatorParsesIt() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let fromProvider = try await provider().search(SearchQuery(text: "frankenstein"))

        let aggregated = try #require(SearchAggregator.pipeline(fromProvider, matching: "").accepted.first)
        #expect(aggregated.metadata.mediaKind == .book)
        #expect(aggregated.metadata.author == "Mary Wollstonecraft Shelley")
        #expect(Routing.subfolder(for: aggregated.metadata, rules: RoutingRule.defaults) == "Books")
    }

    // MARK: - The request

    /// `/books` 301s to `/books/`; paying a redirect on every search is a
    /// round trip for nothing.
    @Test func requestUsesTheTrailingSlashAndSendsTheQuery() async throws {
        StubURLProtocol.reset([.json(onePage)])
        _ = try await provider().search(SearchQuery(text: "frankenstein"))

        let url = try #require(StubURLProtocol.recordedRequests().first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        // URL.path drops a trailing slash, so it cannot see the property
        // under test — URLComponents.path does not, and that is the whole
        // point being asserted here.
        #expect(components.path == "/books/")
        let items = try #require(components.queryItems)
        #expect(items.contains(URLQueryItem(name: "search", value: "frankenstein")))
    }

    /// A filter the user did not set must not be sent — an empty
    /// `languages=` would filter to nothing.
    @Test func languagesAreSentOnlyWhenAFilterIsActive() async throws {
        StubURLProtocol.reset([.json(onePage)])
        _ = try await provider().search(SearchQuery(text: "f"))
        var url = try #require(StubURLProtocol.recordedRequests().first?.url)
        // The parsed query items, not a substring of the URL: this repo has
        // shipped three bugs from asking what a string contains instead of
        // what it resolves to, and `?search=languages` would satisfy the
        // substring while the filter was correctly absent.
        let sent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!sent.contains { $0.name == "languages" })

        StubURLProtocol.reset([.json(onePage)])
        _ = try await provider(languages: ["en", "fr"]).search(SearchQuery(text: "f"))
        url = try #require(StubURLProtocol.recordedRequests().first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "languages", value: "en,fr")))
    }

    /// An empty query must not become a request for the whole catalogue.
    @Test func aBlankQueryMakesNoRequest() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let results = try await provider().search(SearchQuery(text: "   "))

        #expect(results.isEmpty)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    // MARK: - Paging

    /// Page size is fixed at 32 and the default limit is 50, so filling one
    /// page of results takes two requests — and no more, however many pages
    /// exist. An unbounded fetch-until-full turns one search into fourteen.
    @Test func aSecondPageIsFetchedButNeverAThird() async throws {
        StubURLProtocol.reset(handler: { _ in .json(Self.fullPage) })
        let results = try await provider().search(SearchQuery(text: "shakespeare", limit: 50))

        #expect(StubURLProtocol.recordedRequests().count == 2)
        #expect(results.count == 50)
    }

    /// `next: null` is the catalogue saying there is no more. Asking anyway
    /// is a wasted round trip on every narrow search.
    @Test func aNullNextStopsPaging() async throws {
        StubURLProtocol.reset([.json(onePage)])
        _ = try await provider().search(SearchQuery(text: "frankenstein", limit: 50))

        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func offsetSelectsThePage() async throws {
        StubURLProtocol.reset([.json(onePage)])
        _ = try await provider().search(SearchQuery(text: "f", limit: 32, offset: 64))

        let url = try #require(StubURLProtocol.recordedRequests().first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "page", value: "3")))
    }

    /// A catalogue whose book at position *n* is titled "Book n", so a test can
    /// say which books came back rather than only how many.
    private static func catalogue(page: Int) -> String {
        let first = (page - 1) * pageSize + 1
        let books = (first..<(first + pageSize)).map { index in
            """
            {"id":\(index),"title":"Book \(index)","authors":[],"languages":["en"],
             "download_count":1,
             "formats":{"application/epub+zip":"https://www.gutenberg.org/ebooks/\(index).epub3.images"}}
            """
        }
        return """
        {"count":10000,"next":"https://gutendex.com/books/?page=\(page + 1)","previous":null,
         "results":[\(books.joined(separator: ","))]}
        """
    }

    private static let pageSize = 32

    private static func pagedCatalogue() -> @Sendable (URLRequest) -> StubURLProtocol.Response {
        { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }
                .flatMap { $0.value }
                .flatMap(Int.init) ?? 1
            return .json(catalogue(page: page))
        }
    }

    /// **The remainder bug.** Gutendex pages in fixed 32s and takes no `limit`;
    /// Fetch asks in 50s. So a window almost never starts on a page boundary,
    /// and `page = offset / 32 + 1` on its own threw the remainder away and
    /// served the tail of the previous window over again.
    ///
    /// Recorded as a known gap and true — latent for as long as nothing paged.
    /// Infinite scroll makes it real on the first scroll, which is why it is
    /// fixed rather than still recorded.
    @Test func anOffsetInsideAPageDoesNotRepeatThePreviousWindow() async throws {
        StubURLProtocol.reset(handler: Self.pagedCatalogue())

        let results = try await provider().search(
            SearchQuery(text: "book", limit: 32, offset: 40))

        // Books 41–72. Dropping the remainder gives 33–64 — eight books the
        // caller has already seen, and eight it never will.
        #expect(results.first?.title == "Book 41")
        #expect(results.count == 32)
        #expect(results.last?.title == "Book 72")
    }

    /// Two consecutive pages of a real search share nothing.
    @Test func consecutivePagesDoNotOverlap() async throws {
        StubURLProtocol.reset(handler: Self.pagedCatalogue())
        let first = try await provider().search(SearchQuery(text: "book", limit: 50, offset: 0))

        StubURLProtocol.reset(handler: Self.pagedCatalogue())
        let second = try await provider().search(SearchQuery(text: "book", limit: 50, offset: 50))

        let overlap = Set(first.map(\.title)).intersection(second.map(\.title))
        #expect(overlap.isEmpty)
        #expect(second.first?.title == "Book 51")
    }

    /// An aligned window is what a first search always is, and it must still
    /// cost the two round trips it always did.
    @Test func anAlignedFirstPageStillCostsTwoRequests() async throws {
        StubURLProtocol.reset(handler: Self.pagedCatalogue())
        let results = try await provider().search(SearchQuery(text: "book", limit: 50))

        #expect(StubURLProtocol.recordedRequests().count == 2)
        #expect(results.first?.title == "Book 1")
        #expect(results.count == 50)
    }

    // MARK: - One book

    /// The sheet's call. Made when a sheet opens, never per search hit.
    @Test func bookByIDReturnsItsFormatsInPriorityOrder() async throws {
        let single = """
        {"id":84,"title":"Frankenstein; or, the Modern Prometheus",
         "authors":[{"name":"Shelley, Mary Wollstonecraft"}],
         "languages":["en"],"download_count":58824,
         "formats":{
           "application/epub+zip":"https://www.gutenberg.org/ebooks/84.epub3.images",
           "text/plain; charset=utf-8":"https://www.gutenberg.org/ebooks/84.txt.utf-8",
           "image/jpeg":"https://www.gutenberg.org/cache/epub/84/pg84.cover.medium.jpg"}}
        """
        StubURLProtocol.reset([.json(single)])
        let book = try await provider().book(id: 84)

        #expect(book.title == "Frankenstein; or, the Modern Prometheus")
        #expect(book.author == "Mary Wollstonecraft Shelley")
        #expect(book.downloadCount == 58824)
        // The cover is excluded here too — the sheet asks for it explicitly.
        #expect(book.choices.map(\.format) == [.epub, .text])

        let url = try #require(StubURLProtocol.recordedRequests().first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        // URL.path drops a trailing slash, so it cannot see the property
        // under test — URLComponents.path does not.
        #expect(components.path == "/books/84/")
    }

    @Test func bookByIDIncludesSupplementaryFilesWhenEnabled() async throws {
        let single = """
        {"id":84,"title":"Frankenstein","authors":[],"languages":["en"],
         "formats":{
           "application/epub+zip":"https://www.gutenberg.org/ebooks/84.epub3.images",
           "image/jpeg":"https://www.gutenberg.org/cache/epub/84/pg84.cover.medium.jpg"}}
        """
        StubURLProtocol.reset([.json(single)])
        let book = try await provider(includesSupplementary: true).book(id: 84)

        #expect(book.choices.map(\.format) == [.epub, .cover])
        #expect(book.author == nil)
    }

    /// 32 books with a `next`, built once so the paging tests read clearly.
    private static let fullPage: String = {
        let books = (1...32).map { index in
            """
            {"id":\(index),"title":"Book \(index)","authors":[{"name":"Author, An"}],
             "languages":["en"],"download_count":1,
             "formats":{"application/epub+zip":"https://www.gutenberg.org/ebooks/\(index).epub3.images"}}
            """
        }.joined(separator: ",")
        return """
        {"count":432,"next":"https://gutendex.com/books/?page=2","previous":null,
         "results":[\(books)]}
        """
    }()
}

/// Stage 7d §4.7. The provider stops choosing a format; the profile does. The
/// sheet has to offer the same order the list ranked by, or the row and the
/// sheet disagree about which format is preferred.
@Suite struct GutenbergBookOrderingTests {
    private func book() -> GutenbergBook {
        GutenbergBook(
            id: 84, title: "Frankenstein", author: "Mary Shelley",
            languages: ["en"], downloadCount: 58_824,
            choices: [
                BookFormatChoice(format: .html, url: URL(string: "https://g/84.html")!),
                BookFormatChoice(format: .epub, url: URL(string: "https://g/84.epub")!),
                BookFormatChoice(format: .kindle, url: URL(string: "https://g/84.kf8")!),
            ])
    }

    @Test func choicesFollowTheProfilesFormatOrder() {
        let ordered = book().ordered(by: [.azw3, .epub, .html])
        #expect(ordered.choices.map(\.format) == [.kindle, .epub, .html])
    }

    /// A format the profile does not rank keeps its place after the ranked
    /// ones rather than jumping the queue.
    @Test func anUnrankedFormatSortsLast() {
        let ordered = book().ordered(by: [.html])
        #expect(ordered.choices.first?.format == .html)
    }

    /// An empty order is not a reordering. Every format ranks equally, so the
    /// provider's own stable order stands.
    @Test func anEmptyOrderChangesNothing() {
        #expect(book().ordered(by: []).choices.map(\.format) == book().choices.map(\.format))
    }
}
