import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct TorznabCategoryScopingTests {
    static let capsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps>
      <searching><search available="yes" supportedParams="q"/></searching>
      <categories>
        <category id="2040" name="Movies/HD"/>
        <category id="5000" name="TV"/>
      </categories>
    </caps>
    """

    static let emptyRSS = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel></channel></rss>
    """

    private func stubCapsAndSearch() {
        StubURLProtocol.reset { request in
            let query = request.url?.query ?? ""
            return query.contains("t=caps")
                ? .init(status: 200, headers: [:], body: Data(Self.capsXML.utf8))
                : .init(status: 200, headers: [:], body: Data(Self.emptyRSS.utf8))
        }
    }

    private func provider(capsStore: TorznabCapsStore? = nil) -> TorznabProvider {
        TorznabProvider(
            id: SearchProviderID(rawValue: "test"),
            displayName: "Test",
            baseURL: URL(string: "https://indexer.example/api")!,
            apiKey: Redacted("key"),
            client: HTTPClient(session: StubURLProtocol.makeSession()),
            capsStore: capsStore)
    }

    private func requests(matching predicate: (String) -> Bool) -> [URLRequest] {
        StubURLProtocol.recordedRequests().filter { predicate($0.url?.query ?? "") }
    }

    @Test func capabilitiesAreFetchedOnceAcrossProviderInstancesSharingAStore() async throws {
        stubCapsAndSearch()
        let store = TorznabCapsStore()

        _ = try await provider(capsStore: store).search(SearchQuery(text: "dune"))
        _ = try await provider(capsStore: store).search(SearchQuery(text: "arrival"))

        #expect(requests { $0.contains("t=caps") }.count == 1)
        #expect(requests { !$0.contains("t=caps") }.count == 2)
    }

    @Test func aTopLevelRequestIsSentAsItsAdvertisedDescendants() async throws {
        stubCapsAndSearch()
        _ = try await provider().search(SearchQuery(
            text: "dune", categories: SearchCategory.movies.torznabCategories))

        let search = requests { !$0.contains("t=caps") }.first
        let cat = URLComponents(url: search!.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "cat" }?.value
        #expect(cat == "2040")
    }

    @Test func anUncoveredCategorySkipsTheRequestEntirely() async throws {
        stubCapsAndSearch()
        let results = try await provider().search(SearchQuery(
            text: "dune", categories: SearchCategory.books.torznabCategories))

        #expect(results.isEmpty)
        #expect(requests { !$0.contains("t=caps") }.isEmpty)
    }

    @Test func participationMatchesTheSkipDecision() async {
        stubCapsAndSearch()
        let subject = provider()
        #expect(await subject.participates(in: SearchCategory.movies.torznabCategories))
        #expect(await subject.participates(in: SearchCategory.books.torznabCategories) == false)
        #expect(await subject.participates(in: []))
    }

    @Test func aFailedCapsFetchIsNotMemoizedAndCanBeRetried() async throws {
        StubURLProtocol.reset([
            .init(error: URLError(.badServerResponse)),
            .init(status: 200, headers: [:], body: Data(Self.capsXML.utf8)),
            .init(status: 200, headers: [:], body: Data(Self.emptyRSS.utf8)),
        ])
        let subject = provider()

        await #expect(throws: SearchError.self) {
            _ = try await subject.search(SearchQuery(text: "dune"))
        }

        let results = try await subject.search(SearchQuery(text: "dune"))
        #expect(results.isEmpty)
        #expect(requests { $0.contains("t=caps") }.count == 2)
    }

    @Test func aFailingInFlightFetchIsCoalescedAndReportedToBothCallers() async throws {
        StubURLProtocol.reset([.init(error: URLError(.badServerResponse))])
        let subject = provider()

        async let first = subject.capabilities()
        async let second = subject.capabilities()

        var firstThrew = false
        var secondThrew = false
        do { _ = try await first } catch { firstThrew = true }
        do { _ = try await second } catch { secondThrew = true }

        #expect(firstThrew)
        #expect(secondThrew)
        #expect(requests { $0.contains("t=caps") }.count == 1)
    }


    @Test("The four kinds the name parser could not find")
    func theKindsTheParserMissed() {
        #expect(TorznabKind.mediaKind(forCategory: 4000) == .software)
        #expect(TorznabKind.mediaKind(forCategory: 4030) == .software)
        #expect(TorznabKind.mediaKind(forCategory: 7000) == .book)
        #expect(TorznabKind.mediaKind(forCategory: 7020) == .book)
        #expect(TorznabKind.mediaKind(forCategory: 1000) == .game)
    }

    @Test("A subcategory beats its parent where they disagree")
    func subcategoriesWin() {
        #expect(TorznabKind.mediaKind(forCategory: 4050) == .game)
        #expect(TorznabKind.mediaKind(forCategory: 5070) == .anime)
        #expect(TorznabKind.mediaKind(forCategory: 3030) == .book)
    }

    @Test("The kinds that already worked still map")
    func theEasyOnes() {
        #expect(TorznabKind.mediaKind(forCategory: 2000) == .movie)
        #expect(TorznabKind.mediaKind(forCategory: 2040) == .movie)
        #expect(TorznabKind.mediaKind(forCategory: 5000) == .tv)
        #expect(TorznabKind.mediaKind(forCategory: 3000) == .music)
        #expect(TorznabKind.mediaKind(forCategory: 3010) == .music)
    }

    @Test("An unmodelled category leaves the parse alone")
    func unmodelledCategoriesDefer() {
        #expect(TorznabKind.mediaKind(forCategory: 6000) == nil)
        #expect(TorznabKind.mediaKind(forCategory: 8000) == nil)
        #expect(TorznabKind.mediaKind(forCategory: 0) == nil)
        #expect(TorznabKind.mediaKind(for: nil) == nil)
    }
}
