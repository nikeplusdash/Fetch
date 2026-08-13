import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Category scoping, and the caps cache that makes it cheap.
@Suite(.serialized, .usesStubURLProtocol) struct TorznabCategoryScopingTests {
    /// Advertises Movies (with an HD subcategory) and TV. No Books.
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

    /// Answers `t=caps` with capabilities and everything else with an empty
    /// feed, so a test can count each kind of request separately.
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

    /// One caps fetch per indexer *per store*, not per search and not per
    /// provider instance. `AppModel.torznabProviders()` builds a fresh
    /// `TorznabProvider` for every search — one instance really is one
    /// search in production — so a cache living on the provider (Task 3's
    /// `TorznabCapsCache`) caches nothing across searches. This builds a new
    /// provider per search sharing one `TorznabCapsStore`, which is what the
    /// app actually does, and checks the shared store is what makes the
    /// second search's caps fetch free. Both search requests are also
    /// asserted, so a regression that turned both searches into `.skip`
    /// (zero RSS requests, also zero caps requests) could not read as green.
    @Test func capabilitiesAreFetchedOnceAcrossProviderInstancesSharingAStore() async throws {
        stubCapsAndSearch()
        let store = TorznabCapsStore()

        _ = try await provider(capsStore: store).search(SearchQuery(text: "dune"))
        _ = try await provider(capsStore: store).search(SearchQuery(text: "arrival"))

        #expect(requests { $0.contains("t=caps") }.count == 1)
        #expect(requests { !$0.contains("t=caps") }.count == 2)
    }

    /// A request for 2000 reaches an indexer that only advertises 2040.
    @Test func aTopLevelRequestIsSentAsItsAdvertisedDescendants() async throws {
        stubCapsAndSearch()
        _ = try await provider().search(SearchQuery(
            text: "dune", categories: SearchCategory.movies.torznabCategories))

        let search = requests { !$0.contains("t=caps") }.first
        let cat = URLComponents(url: search!.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "cat" }?.value
        #expect(cat == "2040")
    }

    /// Asking a movie-and-TV indexer for books returns nothing *without*
    /// making the request — and the caller sees an empty success, not a
    /// failure, because "does not carry this" is not an error to report.
    @Test func anUncoveredCategorySkipsTheRequestEntirely() async throws {
        stubCapsAndSearch()
        let results = try await provider().search(SearchQuery(
            text: "dune", categories: SearchCategory.books.torznabCategories))

        #expect(results.isEmpty)
        #expect(requests { !$0.contains("t=caps") }.isEmpty)
    }

    /// `participates` is what keeps a skipped indexer out of the fan-out, so
    /// the progress readout counts only providers that were actually asked.
    @Test func participationMatchesTheSkipDecision() async {
        stubCapsAndSearch()
        let subject = provider()
        #expect(await subject.participates(in: SearchCategory.movies.torznabCategories))
        #expect(await subject.participates(in: SearchCategory.books.torznabCategories) == false)
        #expect(await subject.participates(in: []))
    }

    /// A failed caps fetch must not be memoized — an indexer that was briefly
    /// unreachable must be retried on the next search, not silently treated
    /// as capability-less for the rest of the app's lifetime. The queue below
    /// scripts the exact three requests this scenario produces in order:
    /// t=caps fails, the first `search` throws before any RSS request is
    /// made, then a second `search` retries t=caps, succeeds, and reaches
    /// the RSS request.
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

    /// Two callers racing against the same in-flight, failing caps fetch must
    /// both see the failure — not one seeing it while the other silently
    /// gets a cached success (there is none to get) or hangs. This also pins
    /// the coalescing itself: only one `t=caps` request goes out for the
    /// pair, proving the second caller joined the first's in-flight task
    /// rather than starting its own.
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
}
