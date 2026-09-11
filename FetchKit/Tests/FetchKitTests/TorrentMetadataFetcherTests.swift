import Testing
import Foundation
@testable import FetchKit

@Suite(.serialized, .usesStubURLProtocol) struct TorrentMetadataFetcherTests {
    private func hash(for name: String, length: Int64) -> String {
        InfoHash.sha1Hex(Data(infoDict(name: name, length: length).utf8))
    }

    private func infoDict(name: String, length: Int64) -> String {
        "d" + "6:length" + "i\(length)e" + "4:name" + "\(name.utf8.count):\(name)" + "e"
    }

    private let unheldHash = "d56eb90c12e1cd269f1bff2e62523b0f46bf390b"

    private func makeFetcher() -> TorrentMetadataFetcher {
        TorrentMetadataFetcher(
            sources: ["https://cache.example/torrent/{HASH}.torrent"],
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private func torrent(name: String, length: Int64) -> Data {
        Data(("d" + "4:info" + infoDict(name: name, length: length) + "e").utf8)
    }

    @Test func aCachedTorrentYieldsItsFiles() async throws {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 200, body: torrent(name: "Show.mkv", length: 1400))
        ])

        let files = await makeFetcher().files(forInfoHash: hash(for: "Show.mkv", length: 1400))
        #expect(files?.count == 1)
        #expect(files?.first?.path == "Show.mkv")
    }

    @Test func theHashIsSentUppercased() async throws {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 200, body: torrent(name: "x", length: 1))
        ])
        let wanted = hash(for: "x", length: 1)
        _ = await makeFetcher().files(forInfoHash: wanted)

        let request = try #require(StubURLProtocol.recordedRequests().last)
        #expect(request.url?.absoluteString.contains(wanted.uppercased()) == true)
    }

    @Test func aMissReturnsNothingRatherThanThrowing() async {
        StubURLProtocol.reset([StubURLProtocol.Response(status: 404)])
        #expect(await makeFetcher().files(forInfoHash: unheldHash) == nil)
    }

    @Test func aBodyThatIsNotATorrentReturnsNothing() async {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 200, body: Data("not a torrent".utf8))
        ])
        #expect(await makeFetcher().files(forInfoHash: unheldHash) == nil)
    }

    @Test func anUnreachableHostReturnsNothing() async {
        StubURLProtocol.reset([
            StubURLProtocol.Response(error: URLError(.cannotConnectToHost))
        ])
        #expect(await makeFetcher().files(forInfoHash: unheldHash) == nil)
    }

    @Test func aHashOfTheWrongLengthIsNotRequested() async {
        StubURLProtocol.reset([StubURLProtocol.Response(status: 200)])
        #expect(await makeFetcher().files(forInfoHash: "abc") == nil)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    @Test func aTorrentWithNoUsableFilesIsAMiss() async {
        let file = "d" + "6:length" + "i1e" + "4:path" + "l" + "2:.." + "e" + "e"
        let info = "d" + "5:files" + "l" + file + "e" + "4:name" + "4:Pack" + "e"
        let traversal = "d" + "4:info" + info + "e"
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 200, body: Data(traversal.utf8))
        ])
        #expect(await makeFetcher().files(forInfoHash: unheldHash) == nil)
    }

    @Test func aWellFormedTorrentForADifferentHashIsRejected() async {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 200, body: torrent(name: "Decoy.exe", length: 999))
        ])
        #expect(await makeFetcher().files(forInfoHash: unheldHash) == nil)
    }
}
