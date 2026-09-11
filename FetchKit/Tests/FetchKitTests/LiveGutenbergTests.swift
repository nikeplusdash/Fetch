import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

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

    @Test func aRealEPUBDownloadsToDisk() async throws {
        let results = try await provider().search(SearchQuery(text: "frankenstein"))
        let book = try #require(results.first)
        let url = try #require(book.candidates.first?.url)

        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
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

        #expect(file.deletingLastPathComponent().path == destination.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

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
