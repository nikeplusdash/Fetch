import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol)
struct RealDebridCloudListingTests {
    private func realDebrid() -> RealDebridProvider {
        RealDebridProvider(
            apiKey: Redacted("test-token"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private let listJSON = """
    [
      {"id":"ABC","hash":"DE","filename":"Movie","bytes":10,"status":"downloaded"},
      {"id":"XYZ","hash":"ff","filename":"Waiting","bytes":5,"status":"downloading"}
    ]
    """

    @Test("only downloaded torrents become cloud items")
    func onlyDownloaded() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let items = try await realDebrid().listAccountContents()

        #expect(items.count == 1)
        #expect(items[0].name == "Movie")
        #expect(items[0].infoHashHex == "de")
        if case .torrent(let id) = items[0].origin {
            #expect(id.rawValue == "ABC")
        } else {
            Issue.record("not a torrent origin")
        }
    }

    @Test("the listing carries no files, so they are left to be hydrated later")
    func filesAreLeftEmpty() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let items = try await realDebrid().listAccountContents()

        #expect(items[0].files.isEmpty)
    }

    @Test("checkCached still reads the same account fetch it always did")
    func checkCachedIsUnchanged() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let entries = try await realDebrid().checkCached(hashes: ["DE", "ff"], listFiles: false)

        #expect(entries["de"]?.name == "Movie")
        #expect(entries["de"]?.size == 10)
        #expect(entries["ff"]?.name == "")
        #expect(entries["ff"]?.size == 0)
    }

    @Test("an empty account lists nothing")
    func emptyAccount() async throws {
        StubURLProtocol.reset([.json("[]")])
        let items = try await realDebrid().listAccountContents()

        #expect(items.isEmpty)
    }
}
