import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol)
struct TorBoxCloudListingTests {
    private func torbox() -> TorBoxProvider {
        TorBoxProvider(
            apiKey: Redacted("test-token"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private let listJSON = """
    {"success":true,"data":[
      {"id":42,"hash":"AbC","name":"Sintel","size":100,"download_present":true,
       "files":[{"id":0,"name":"Sintel/sintel.mkv","short_name":"sintel.mkv","size":100,"mimetype":"video/x-matroska"}]},
      {"id":7,"hash":"def","name":"NotReady","size":50,"download_present":false,"files":[]}
    ]}
    """

    @Test("mylist maps present torrents to cloud items and drops absent ones")
    func mapsPresentTorrents() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let items = try await torbox().listAccountContents()

        #expect(items.count == 1)
        #expect(items[0].name == "Sintel")
        #expect(items[0].size == 100)
        if case .torrent(let id) = items[0].origin {
            #expect(id.rawValue == "42")
        } else {
            Issue.record("not a torrent origin")
        }
    }

    @Test("The infohash is lowercased, because it is the cross-service dedup key")
    func hashIsLowercased() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let items = try await torbox().listAccountContents()

        #expect(items[0].infoHashHex == "abc")
    }

    @Test("TorBox ships files in the listing, so they need no second fetch")
    func filesArrivePopulated() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let items = try await torbox().listAccountContents()

        #expect(items[0].files.count == 1)
        #expect(items[0].files[0].name == "Sintel/sintel.mkv")
    }

    @Test("A torrent TorBox calls completed counts as present even without the flag")
    func completedCountsAsReady() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"data":[
          {"id":1,"hash":"aa","name":"Done","size":10,"download_state":"completed","files":[]}
        ]}
        """)])
        let items = try await torbox().listAccountContents()

        #expect(items.count == 1)
        #expect(items[0].name == "Done")
    }

    @Test("An empty account is an empty list, not an error")
    func emptyAccountIsEmpty() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"data":[]}
        """)])
        let items = try await torbox().listAccountContents()

        #expect(items.isEmpty)
    }
}
