import Testing
import Foundation
@testable import FetchKit

/// Fetching a file list by infohash from a public `.torrent` cache.
///
/// The whole point is that it never makes anything worse: a miss, a timeout, a
/// truncated body or a hostile one all return nil, and the caller carries on as
/// if the feature did not exist.
@Suite(.serialized, .usesStubURLProtocol) struct TorrentMetadataFetcherTests {
    /// Derived from the fixture rather than fixed, because the fetcher now
    /// verifies that the body's infohash is the one requested — an arbitrary
    /// constant would be rejected, correctly.
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

    /// Built rather than hand-written, for the same reason as BencodeTests:
    /// one miscounted length prefix or stray terminator and the test fails for
    /// a reason that has nothing to do with what it is checking.
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

    /// Caches key on uppercase hex; sending lowercase would 404 on every hash.
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

    /// Bytes from a third party: garbage must be declined, not parsed
    /// hopefully.
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

    /// A malformed hash must not be sent anywhere.
    @Test func aHashOfTheWrongLengthIsNotRequested() async {
        StubURLProtocol.reset([StubURLProtocol.Response(status: 200)])
        #expect(await makeFetcher().files(forInfoHash: "abc") == nil)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    /// A torrent parsing to zero usable files is a miss, not an empty list —
    /// otherwise the picker would show nothing and call it a success.
    @Test func aTorrentWithNoUsableFilesIsAMiss() async {
        let file = "d" + "6:length" + "i1e" + "4:path" + "l" + "2:.." + "e" + "e"
        let info = "d" + "5:files" + "l" + file + "e" + "4:name" + "4:Pack" + "e"
        let traversal = "d" + "4:info" + info + "e"
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 200, body: Data(traversal.utf8))
        ])
        #expect(await makeFetcher().files(forInfoHash: unheldHash) == nil)
    }

    /// The decoy, stubbed: a perfectly well-formed torrent that is simply not
    /// the one asked for. itorrents.org serves exactly this for any hash it
    /// does not hold, so accepting it would fabricate a file list.
    @Test func aWellFormedTorrentForADifferentHashIsRejected() async {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 200, body: torrent(name: "Decoy.exe", length: 999))
        ])
        #expect(await makeFetcher().files(forInfoHash: unheldHash) == nil)
    }
}
