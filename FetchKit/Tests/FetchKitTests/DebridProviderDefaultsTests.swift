import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

private struct BareProvider: DebridProvider {
    let id = DebridProviderID(rawValue: "bare")
    let displayName = "Bare"

    func validateCredentials() async throws -> DebridAccount {
        DebridAccount(email: nil, plan: nil, expiresAt: nil)
    }
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        DebridTorrentID(rawValue: "0")
    }
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        DebridTorrent(
            id: id, infoHashHex: "", name: "", size: 0, progress: 0,
            state: .unknown("n/a"), files: [], seeds: nil, downloadSpeed: nil, eta: nil)
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        URL(string: "https://example.com")!
    }
    func delete(torrent: DebridTorrentID) async throws {}
}

@Suite("Debrid provider defaults")
struct DebridProviderDefaultsTests {
    @Test("A provider that does not implement listing returns nothing, not an error")
    func defaultListingIsEmpty() async throws {
        let items = try await BareProvider().listAccountContents()
        #expect(items.isEmpty)
    }

    @Test("The provider that stands in for no provider at all lists nothing")
    func noDebridProviderListsNothing() async throws {
        let items = try await NoDebridProvider().listAccountContents()
        #expect(items.isEmpty)
    }
}
