import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite @MainActor struct CloudReAddSourceTests {
    private func makeStore() throws -> DownloadStore {
        try DownloadStore(inMemory: true)
    }

    private func makeRequest(
        name: String = "movie.mkv", size: Int64 = 1000, root: String = "/tmp/fetch-test"
    ) -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "torbox"),
            torrentID: DebridTorrentID(rawValue: "t1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "f1"), name: name,
                shortName: (name as NSString).lastPathComponent, size: size, mimeType: nil),
            infoHashHex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            subfolder: "Movies",
            destinationRoot: URL(fileURLWithPath: root, isDirectory: true))
    }

    @Test func aMagnetSurvivesARoundTrip() throws {
        let store = try makeStore()
        let id = DownloadID()
        try store.save(id: id, request: makeRequest(), state: .cloudQueued,
                       bytesDownloaded: 0,
                       cloudReAddSource: "magnet:?xt=urn:btih:abc")
        #expect(try store.loadAll().first?.cloudReAddSource == "magnet:?xt=urn:btih:abc")
    }

    @Test func aHosterURLSurvivesTheSameColumn() throws {
        let store = try makeStore()
        let id = DownloadID()
        try store.save(id: id, request: makeRequest(), state: .onCloud,
                       bytesDownloaded: 0,
                       cloudReAddSource: "https://example.com/file.mkv")
        #expect(try store.loadAll().first?.cloudReAddSource == "https://example.com/file.mkv")
    }

    @Test func anOrdinaryDownloadHasNone() throws {
        let store = try makeStore()
        let id = DownloadID()
        try store.save(id: id, request: makeRequest(), state: .downloading,
                       bytesDownloaded: 10)
        #expect(try store.loadAll().first?.cloudReAddSource == nil)
    }

    /**
     Re-saving a row must not wipe what it already had — the promotion poll
     re-saves a row it did not mint.
     */
    @Test func resavingWithoutOneKeepsTheStoredValue() throws {
        let store = try makeStore()
        let id = DownloadID()
        try store.save(id: id, request: makeRequest(), state: .cloudQueued,
                       bytesDownloaded: 0, cloudReAddSource: "magnet:?xt=urn:btih:abc")
        try store.save(id: id, request: makeRequest(), state: .onCloud, bytesDownloaded: 0)
        #expect(try store.loadAll().first?.cloudReAddSource == "magnet:?xt=urn:btih:abc")
    }
}
