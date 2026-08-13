import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Returns `downloading` on the first poll and `completed` after, so the
/// engine must actually wait rather than assuming readiness.
private actor PollCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}

private struct SlowDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "slow")
    let displayName = "Slow"
    let counter = PollCounter()

    func validateCredentials() async throws -> DebridAccount {
        DebridAccount(email: nil, plan: nil, expiresAt: nil)
    }
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        DebridTorrentID(rawValue: "77")
    }
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        let ready = await counter.next() > 1
        return DebridTorrent(
            id: id, infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            name: "Prepared", size: 100,
            progress: ready ? 1 : 0.4,
            state: ready ? .completed : .downloading,
            files: ready
                ? [DebridFile(id: DebridFileID(rawValue: "0"), name: "out.bin",
                              shortName: "out.bin", size: 100, mimeType: nil)]
                : [],
            seeds: 5, downloadSpeed: nil, eta: nil
        )
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] {
        try await torrent(id: id).files
    }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        URL(string: "https://cdn.example.com/out.bin")!
    }
    func delete(torrent: DebridTorrentID) async throws {}
}

@Suite(.serialized, .usesStubURLProtocol) struct PreparingFlowTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func uncachedMagnetPassesThroughPreparingThenDownloads() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x04, count: 100)
            )
        ])
        let engine = DownloadEngine(
            provider: SlowDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1,
            pollInterval: 0.01
        )

        let ids = try await engine.enqueueMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: nil,
            destinationRoot: root
        )
        let id = try #require(ids.first)
        try await engine.waitUntilSettled(id)

        #expect(await engine.state(of: id) == .completed)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("out.bin").path))
    }

    @Test func collidingFilenameGetsNumberedSuffix() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing".utf8).write(to: root.appendingPathComponent("out.bin"))

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x04, count: 100)
            )
        ])
        let engine = DownloadEngine(
            provider: SlowDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1,
            pollInterval: 0.01
        )

        let ids = try await engine.enqueueMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: nil, destinationRoot: root
        )
        try await engine.waitUntilSettled(try #require(ids.first))

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("out.bin (1)").path)
             || FileManager.default.fileExists(atPath: root.appendingPathComponent("out (1).bin").path))
        #expect(try Data(contentsOf: root.appendingPathComponent("out.bin")) == Data("existing".utf8))
    }

    @Test func invalidMagnetThrowsBeforeAnyNetworkCall() async {
        StubURLProtocol.reset([])
        let engine = DownloadEngine(
            provider: SlowDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1, pollInterval: 0.01
        )
        await #expect(throws: (any Error).self) {
            _ = try await engine.enqueueMagnet(
                "not-a-magnet", subfolder: nil,
                destinationRoot: FileManager.default.temporaryDirectory
            )
        }
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }
}
