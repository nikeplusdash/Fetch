import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Real requests to gutendex.com and gutenberg.org. Gated on `FETCH_LIVE=1`
/// like every other live suite, so a normal run stays hermetic.
///
/// Run: `FETCH_LIVE=1 swift test --filter LiveGutenbergTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FETCH_LIVE"] == "1"))
struct LiveGutenbergTests {
    private func provider() -> GutenbergProvider {
        GutenbergProvider(
            client: HTTPClient(allowedHosts: [
                GutenbergProvider.apiHost, GutenbergProvider.fileHost,
            ]))
    }

    @Test func aRealSearchReturnsBooksWithDirectCandidates() async throws {
        let results = try await provider().search(SearchQuery(text: "frankenstein"))

        #expect(!results.isEmpty)
        let book = try #require(results.first)
        #expect(book.metadata.mediaKind == .book)
        #expect(book.candidates.allSatisfy { if case .direct = $0 { true } else { false } })
        #expect(book.rawAttributes["gutenbergID"] != nil)
    }

    /// The acceptance test for this stage: no debrid anywhere in the path,
    /// and a real file on disk with the name Fetch invented for it.
    @Test func aRealEPUBDownloadsToDisk() async throws {
        let results = try await provider().search(SearchQuery(text: "frankenstein"))
        let book = try #require(results.first)
        let url = try #require(book.candidates.first?.url)

        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        // An EPUB is a zip: "PK". A 200 carrying an error page would pass a
        // status check and fail this one.
        #expect(data.prefix(2) == Data([0x50, 0x4B]))

        let name = BookFilename.make(
            title: book.title, author: book.rawAttributes["author"], format: .epub)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetch-live-gutenberg", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        let file = destination.appendingPathComponent(name)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: destination) }

        // Where it landed, not what the name contains.
        #expect(file.deletingLastPathComponent().path == destination.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// The redirect the trailing slash exists to avoid, asserted against the
    /// live server rather than assumed.
    ///
    /// `URLSession.shared.data(for:)` follows redirects transparently with no
    /// delegate installed, so `HTTPURLResponse.statusCode` alone reflects only
    /// the *terminal* hop — a 200 there proves nothing about whether a
    /// redirect happened on the way. `response.url` is the actual final URL
    /// after following any redirect chain, so comparing it to the URL that
    /// was requested is what actually tells the two cases apart: equal means
    /// no hop occurred, different means one did.
    ///
    /// Both directions are asserted so the test can't pass no matter which
    /// spelling is given — the negative half (no trailing slash) proves this
    /// mechanism can detect a redirect at all, by triggering one on purpose.
    @Test func theTrailingSlashAvoidsARedirect() async throws {
        let withSlash = URL(string: "https://gutendex.com/books/?search=dune")!
        let (_, slashResponse) = try await URLSession.shared.data(from: withSlash)
        #expect((slashResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(slashResponse.url == withSlash, "the trailing-slash URL redirected after all")

        let withoutSlash = URL(string: "https://gutendex.com/books?search=dune")!
        let (_, bareResponse) = try await URLSession.shared.data(from: withoutSlash)
        #expect((bareResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(
            bareResponse.url != withoutSlash,
            "no redirect occurred without the trailing slash — this mechanism can no longer tell the two cases apart"
        )
    }
}
