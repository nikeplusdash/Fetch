import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

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

    @Test func sizeAndSeedersAreAbsentRatherThanZero() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let book = try #require(try await provider().search(SearchQuery(text: "f")).first)

        #expect(book.size == nil)
        #expect(book.seeders == nil)
        #expect(book.peers == nil)
    }

    @Test func everyCandidateIsDirect() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let book = try #require(try await provider().search(SearchQuery(text: "f")).first)

        #expect(!book.candidates.isEmpty)
        #expect(book.candidates.allSatisfy { if case .direct = $0 { true } else { false } })
        #expect(book.infoHashHex == nil)
    }

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

    @Test func aBookStillRoutesToBooksAfterTheAggregatorParsesIt() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let fromProvider = try await provider().search(SearchQuery(text: "frankenstein"))

        let aggregated = try #require(SearchAggregator.pipeline(fromProvider, matching: "").accepted.first)
        #expect(aggregated.metadata.mediaKind == .book)
        #expect(aggregated.metadata.author == "Mary Wollstonecraft Shelley")
        #expect(Routing.subfolder(for: aggregated.metadata, rules: RoutingRule.defaults) == "Books")
    }


    @Test func requestUsesTheTrailingSlashAndSendsTheQuery() async throws {
        StubURLProtocol.reset([.json(onePage)])
        _ = try await provider().search(SearchQuery(text: "frankenstein"))

        let url = try #require(StubURLProtocol.recordedRequests().first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/books/")
        let items = try #require(components.queryItems)
        #expect(items.contains(URLQueryItem(name: "search", value: "frankenstein")))
    }

    @Test func languagesAreSentOnlyWhenAFilterIsActive() async throws {
        StubURLProtocol.reset([.json(onePage)])
        _ = try await provider().search(SearchQuery(text: "f"))
        var url = try #require(StubURLProtocol.recordedRequests().first?.url)
        let sent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!sent.contains { $0.name == "languages" })

        StubURLProtocol.reset([.json(onePage)])
        _ = try await provider(languages: ["en", "fr"]).search(SearchQuery(text: "f"))
        url = try #require(StubURLProtocol.recordedRequests().first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "languages", value: "en,fr")))
    }

    @Test func aBlankQueryMakesNoRequest() async throws {
        StubURLProtocol.reset([.json(onePage)])
        let results = try await provider().search(SearchQuery(text: "   "))

        #expect(results.isEmpty)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }


    @Test func aSecondPageIsFetchedButNeverAThird() async throws {
        StubURLProtocol.reset(handler: { _ in .json(Self.fullPage) })
        let results = try await provider().search(SearchQuery(text: "shakespeare", limit: 50))

        #expect(StubURLProtocol.recordedRequests().count == 2)
        #expect(results.count == 50)
    }

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

    @Test func anOffsetInsideAPageDoesNotRepeatThePreviousWindow() async throws {
        StubURLProtocol.reset(handler: Self.pagedCatalogue())

        let results = try await provider().search(
            SearchQuery(text: "book", limit: 32, offset: 40))

        #expect(results.first?.title == "Book 41")
        #expect(results.count == 32)
        #expect(results.last?.title == "Book 72")
    }

    @Test func consecutivePagesDoNotOverlap() async throws {
        StubURLProtocol.reset(handler: Self.pagedCatalogue())
        let first = try await provider().search(SearchQuery(text: "book", limit: 50, offset: 0))

        StubURLProtocol.reset(handler: Self.pagedCatalogue())
        let second = try await provider().search(SearchQuery(text: "book", limit: 50, offset: 50))

        let overlap = Set(first.map(\.title)).intersection(second.map(\.title))
        #expect(overlap.isEmpty)
        #expect(second.first?.title == "Book 51")
    }

    @Test func anAlignedFirstPageStillCostsTwoRequests() async throws {
        StubURLProtocol.reset(handler: Self.pagedCatalogue())
        let results = try await provider().search(SearchQuery(text: "book", limit: 50))

        #expect(StubURLProtocol.recordedRequests().count == 2)
        #expect(results.first?.title == "Book 1")
        #expect(results.count == 50)
    }


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
        #expect(book.choices.map(\.format) == [.epub, .text])

        let url = try #require(StubURLProtocol.recordedRequests().first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
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

    @Test func anUnrankedFormatSortsLast() {
        let ordered = book().ordered(by: [.html])
        #expect(ordered.choices.first?.format == .html)
    }

    @Test func anEmptyOrderChangesNothing() {
        #expect(book().ordered(by: []).choices.map(\.format) == book().choices.map(\.format))
    }
}
