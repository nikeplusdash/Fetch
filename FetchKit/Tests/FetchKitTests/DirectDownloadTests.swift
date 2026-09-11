import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct DirectDownloadTests {
    private struct ExplodingProvider: DebridProvider {
        let id = DebridProviderID(rawValue: "must-not-be-called")
        let displayName = "Must not be called"
        struct Called: Error {}
        func validateCredentials() async throws -> DebridAccount { throw Called() }
        func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] {
            throw Called()
        }
        func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID { throw Called() }
        func torrent(id: DebridTorrentID) async throws -> DebridTorrent { throw Called() }
        func files(in id: DebridTorrentID) async throws -> [DebridFile] { throw Called() }
        func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
            throw Called()
        }
        func delete(torrent: DebridTorrentID) async throws { throw Called() }
    }

    private func makeRequest(url: URL, into root: URL, size: Int64) -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "none"),
            torrentID: DebridTorrentID(rawValue: "none"),
            file: DebridFile(id: DebridFileID(rawValue: "none"), name: "book.epub", shortName: "book.epub", size: size, mimeType: nil),
            infoHashHex: "",
            subfolder: nil,
            destinationRoot: root,
            directURL: url)
    }

    @Test func aDirectRequestCarriesItsURL() {
        let url = URL(string: "https://archive.org/download/x/book.epub")!
        let request = makeRequest(url: url, into: URL(fileURLWithPath: "/tmp"), size: 10)

        #expect(request.directURL == url)
        #expect(request.source == .directHTTP(url: url))
    }

    @Test func aTorrentRequestIsUnchanged() {
        var request = makeRequest(
            url: URL(string: "https://x/y")!, into: URL(fileURLWithPath: "/tmp"), size: 1)
        request = DownloadRequest(
            providerID: request.providerID, torrentID: request.torrentID,
            file: request.file, infoHashHex: "abc",
            subfolder: nil, destinationRoot: request.destinationRoot)

        #expect(request.directURL == nil)
        #expect(request.source.needsPreparing)
    }

    @Test func aDirectDownloadNeverAsksTheDebridForALink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = Data("Once upon a time.".utf8)
        StubURLProtocol.reset { _ in
            StubURLProtocol.Response(status: 200, headers: [:], body: body)
        }

        let engine = DownloadEngine(
            provider: ExplodingProvider(),
            transfer: RangeTransfer(
                body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())))

        let url = URL(string: "https://archive.org/download/x/book.epub")!
        let id = await engine.enqueue(
            makeRequest(url: url, into: root, size: Int64(body.count)))

        var landed: URL?
        for await event in await engine.events {
            if case .finished(let completedID, let at) = event, completedID == id {
                landed = at
                break
            }
            if case .failed(_, let error) = event {
                Issue.record("direct download failed: \(error)")
                break
            }
        }

        let final = try #require(landed)
        #expect(try Data(contentsOf: final) == body)
    }

    @Test func directRequestsCarryTheirOwnGroupKey() {
        let root = URL(fileURLWithPath: "/tmp")
        let courage = DownloadGroupKey(content: "courage")
        let dune = DownloadGroupKey(content: "dune")

        func request(item: DownloadGroupKey, file: String) -> DownloadRequest {
            DownloadRequest(
                providerID: DebridProviderID(rawValue: "direct"),
                torrentID: DebridTorrentID(rawValue: "direct"),
                file: DebridFile(
                    id: DebridFileID(rawValue: file), name: file,
                    shortName: file, size: 1, mimeType: nil),
                infoHashHex: "", subfolder: nil, destinationRoot: root,
                directURL: URL(
                    string: "https://archive.org/download/\(item.content)/\(file)")!,
                groupKey: item)
        }

        let a = request(item: courage, file: "S01E01.mkv")
        let b = request(item: courage, file: "S01E02.mkv")
        let c = request(item: dune, file: "dune.epub")

        #expect(a.groupKey == b.groupKey, "files from one item belong together")
        #expect(a.groupKey != c.groupKey, "different items are different rows")
    }

    @Test func aTorrentRequestGroupsByItsInfoHash() {
        let request = DownloadRequest(
            providerID: DebridProviderID(rawValue: "t"),
            torrentID: DebridTorrentID(rawValue: "1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "f"), name: "a.mkv",
                shortName: "a.mkv", size: 1, mimeType: nil),
            infoHashHex: "abc123", subfolder: nil,
            destinationRoot: URL(fileURLWithPath: "/tmp"))

        #expect(request.groupKey == .unattempted("abc123"))
        #expect(request.groupKey.content == "abc123")
    }
}
