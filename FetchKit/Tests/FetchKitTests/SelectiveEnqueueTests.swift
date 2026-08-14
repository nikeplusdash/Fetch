import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// A debrid whose torrent is immediately ready with a fixed, multi-file
/// listing — enough to exercise selection without a poll loop.
private struct MultiFileDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "fake")
    let displayName = "Fake"
    let files: [DebridFile]

    func validateCredentials() async throws -> DebridAccount {
        DebridAccount(email: nil, plan: nil, expiresAt: nil)
    }
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        DebridTorrentID(rawValue: "42")
    }
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        DebridTorrent(
            id: id, infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            name: "Show", size: files.reduce(0) { $0 + $1.size },
            progress: 1, state: .completed, files: files,
            seeds: 5, downloadSpeed: nil, eta: nil
        )
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] { files }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        URL(string: "https://cdn.example.com/\(file.rawValue)")!
    }
    func delete(torrent: DebridTorrentID) async throws {}
}

@Suite(.serialized, .usesStubURLProtocol) struct SelectiveEnqueueTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every `enqueue`/`enqueueMagnet`/`enqueueSelected` call starts a real
    /// (stubbed) background transfer `Task` per file. `.usesStubURLProtocol`
    /// only serializes *test bodies* against each other via its gate — it
    /// does not know about an engine's own untracked background tasks, so a
    /// test that returns without waiting for those tasks to reach a
    /// terminal state leaves them free to keep issuing requests through
    /// `StubURLProtocol`'s process-global queue after the gate has already
    /// been handed to the next suite. This bit `TorBoxCacheTests` for
    /// exactly that reason during development of this file — every test
    /// below settles every ID it produces before returning.
    private func settleAll(_ ids: [DownloadID], on engine: DownloadEngine) async throws {
        for id in ids { try await engine.waitUntilSettled(id) }
    }

    private func seasonFiles() -> [DebridFile] {
        [
            DebridFile(id: DebridFileID(rawValue: "1"), name: "Show/S01E01.mkv",
                       shortName: "S01E01.mkv", size: 100, mimeType: nil),
            DebridFile(id: DebridFileID(rawValue: "2"), name: "Show/S01E02.mkv",
                       shortName: "S01E02.mkv", size: 100, mimeType: nil),
            DebridFile(id: DebridFileID(rawValue: "3"), name: "Show/S01E03.mkv",
                       shortName: "S01E03.mkv", size: 100, mimeType: nil),
        ]
    }

    @Test func nilSelectingQueuesEveryFileMatchingOriginalBehavior() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([])

        let engine = DownloadEngine(
            provider: MultiFileDebrid(files: seasonFiles()),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1, pollInterval: 0.01
        )
        let result = try await engine.enqueueMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: nil, destinationRoot: root, selecting: nil
        )
        try await settleAll(result.downloadIDs, on: engine)
        #expect(result.downloadIDs.count == 3)
        #expect(result.missingPaths.isEmpty)
    }

    @Test func selectingASubsetQueuesOnlyThoseFiles() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([])

        let engine = DownloadEngine(
            provider: MultiFileDebrid(files: seasonFiles()),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1, pollInterval: 0.01
        )
        let result = try await engine.enqueueMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: nil, destinationRoot: root,
            selecting: ["Show/S01E02.mkv"]
        )
        try await settleAll(result.downloadIDs, on: engine)
        #expect(result.downloadIDs.count == 1)
        #expect(result.missingPaths.isEmpty)
    }

    /// The load-bearing case: a path selected against the preview that has
    /// no counterpart in the authoritative list must be reported, not
    /// silently dropped, and must not queue a bogus download.
    @Test func selectingAPathAbsentFromAuthoritativeListIsReportedAsMissing() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([])

        let engine = DownloadEngine(
            provider: MultiFileDebrid(files: seasonFiles()),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1, pollInterval: 0.01
        )
        let result = try await engine.enqueueMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: nil, destinationRoot: root,
            selecting: ["Show/S01E02.mkv", "Show/S01E99.mkv"]
        )
        try await settleAll(result.downloadIDs, on: engine)
        #expect(result.downloadIDs.count == 1)
        #expect(result.missingPaths == ["Show/S01E99.mkv"])
    }

    @Test func emptySelectionQueuesNothing() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([])

        let engine = DownloadEngine(
            provider: MultiFileDebrid(files: seasonFiles()),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1, pollInterval: 0.01
        )
        let result = try await engine.enqueueMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: nil, destinationRoot: root, selecting: []
        )
        try await settleAll(result.downloadIDs, on: engine)
        #expect(result.downloadIDs.isEmpty)
        #expect(result.missingPaths.isEmpty)
    }

    /// The original (pre-existing) three-argument overload must keep
    /// working unchanged — nothing about adding `selecting:` may alter its
    /// return type or behavior.
    @Test func originalThreeArgumentOverloadStillReturnsPlainDownloadIDArray() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([])

        let engine = DownloadEngine(
            provider: MultiFileDebrid(files: seasonFiles()),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1, pollInterval: 0.01
        )
        let ids: [DownloadID] = try await engine.enqueueMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: nil, destinationRoot: root
        )
        try await settleAll(ids, on: engine)
        #expect(ids.count == 3)
    }

    // MARK: - prepareMagnet / enqueueSelected (the "choose before adding" path)

    @Test func prepareMagnetReturnsAuthoritativeFilesWithoutEnqueuingAnything() async throws {
        let engine = DownloadEngine(
            provider: MultiFileDebrid(files: seasonFiles()),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1, pollInterval: 0.01
        )
        let prepared = try await engine.prepareMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
        )
        #expect(prepared.files.count == 3)
        #expect(prepared.infoHashHex == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
    }

    @Test func enqueueSelectedUsesThePreparedAuthoritativeListDirectly() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([])

        let engine = DownloadEngine(
            provider: MultiFileDebrid(files: seasonFiles()),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1, pollInterval: 0.01
        )
        let prepared = try await engine.prepareMagnet(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
        )
        let result = await engine.enqueueSelected(
            torrentID: prepared.torrentID, infoHashHex: prepared.infoHashHex, files: prepared.files,
            selecting: ["Show/S01E01.mkv"], subfolder: nil, destinationRoot: root
        )
        try await settleAll(result.downloadIDs, on: engine)
        #expect(result.downloadIDs.count == 1)
        #expect(result.missingPaths.isEmpty)
    }
}
