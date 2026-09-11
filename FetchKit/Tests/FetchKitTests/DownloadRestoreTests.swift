import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct DownloadRestoreTests {
    private func makeRequest(name: String = "movie.mkv", size: Int64 = 1000) -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "stub"),
            torrentID: DebridTorrentID(rawValue: "t1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "f1"), name: name,
                shortName: name, size: size, mimeType: nil),
            infoHashHex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            subfolder: nil,
            destinationRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeEngine() -> DownloadEngine {
        DownloadEngine(provider: RestoreStubProvider())
    }

    @Test func aRestoredJobKeepsItsIdentity() async {
        let engine = makeEngine()
        let id = DownloadID()

        await engine.restore(
            id: id, request: makeRequest(), state: .paused, bytesDownloaded: 512)

        #expect(await engine.state(of: id) == .paused)
    }

    @Test func restoringDoesNotStartTheTransfer() async throws {
        let engine = makeEngine()
        let id = DownloadID()

        await engine.restore(
            id: id, request: makeRequest(), state: .paused, bytesDownloaded: 512)
        try await Task.sleep(for: .milliseconds(80))

        #expect(await engine.state(of: id) == .paused)
    }

    @Test func aRestoredJobIsResumable() async {
        let engine = makeEngine()
        let id = DownloadID()

        await engine.restore(
            id: id, request: makeRequest(), state: .paused, bytesDownloaded: 512)
        await engine.resume(id)

        let state = await engine.state(of: id)
        #expect(state != .paused, "resume should move it off paused, got \(String(describing: state))")
    }

    @Test func aCompletedRecordRestoresAsCompleted() async {
        let engine = makeEngine()
        let id = DownloadID()

        await engine.restore(
            id: id, request: makeRequest(), state: .completed, bytesDownloaded: 1000)

        #expect(await engine.state(of: id) == .completed)
    }

    @Test func restoringEmitsARowSoTheUICanShowIt() async {
        let engine = makeEngine()
        let id = DownloadID()

        let collected = Task {
            var seen: [DownloadEvent] = []
            for await event in await engine.events {
                seen.append(event)
                if seen.count == 2 { break }
            }
            return seen
        }
        try? await Task.sleep(for: .milliseconds(30))

        await engine.restore(
            id: id, request: makeRequest(), state: .paused, bytesDownloaded: 512)

        let events = await collected.value
        guard case .enqueued(let emittedID, _, let total) = events.first else {
            Issue.record("expected .enqueued first, got \(String(describing: events.first))")
            return
        }
        #expect(emittedID == id)
        #expect(total == 1000)
    }

    @Test func restoringTwiceDoesNotDuplicateTheJob() async {
        let engine = makeEngine()
        let id = DownloadID()
        let request = makeRequest()

        await engine.restore(id: id, request: request, state: .paused, bytesDownloaded: 512)
        await engine.restore(id: id, request: request, state: .paused, bytesDownloaded: 512)
        await engine.resume(id)

        #expect(await engine.state(of: id) != nil)
    }
}

private struct RestoreStubProvider: DebridProvider {
    let id = DebridProviderID(rawValue: "stub")
    let displayName = "Stub"

    func validateCredentials() async throws -> DebridAccount {
        DebridAccount(email: nil, plan: nil, expiresAt: nil)
    }
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        DebridTorrentID(rawValue: "t1")
    }
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        DebridTorrent(
            id: id, infoHashHex: "", name: "", size: 0, progress: 0,
            state: .completed, files: [], seeds: nil, downloadSpeed: nil, eta: nil)
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        URL(string: "https://example.invalid/file")!
    }
    func delete(torrent: DebridTorrentID) async throws {}
}

@Suite(.serialized, .usesStubURLProtocol) struct RestoredQueueTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func request(root: URL) -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "fake"),
            torrentID: DebridTorrentID(rawValue: "1"),
            file: DebridFile(id: DebridFileID(rawValue: "0"), name: "file.bin",
                             shortName: "file.bin", size: 100, mimeType: nil),
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: "Movies", destinationRoot: root)
    }

    @Test func aRestoredQueuedDownloadCanBeStarted() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([StubURLProtocol.Response(
            status: 200, headers: ["Content-Length": "100"],
            body: Data(repeating: 0x7, count: 100))])

        let engine = DownloadEngine(
            provider: RestoreFakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1)

        let id = DownloadID()
        await engine.restore(id: id, request: request(root: root), state: .queued, bytesDownloaded: 0)
        #expect(await engine.state(of: id) == .queued)

        await engine.resume(id)
        try await engine.waitUntilSettled(id)

        #expect(await engine.state(of: id) == .completed)
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    @Test func restoringStillDoesNotStartAnything() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([StubURLProtocol.Response(status: 500)])

        let engine = DownloadEngine(
            provider: RestoreFakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1)
        let id = DownloadID()
        await engine.restore(id: id, request: request(root: root), state: .queued, bytesDownloaded: 0)

        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(await engine.state(of: id) == .queued)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }
}

private struct RestoreFakeDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "fake")
    let displayName = "Fake"
    func validateCredentials() async throws -> DebridAccount {
        DebridAccount(email: nil, plan: nil, expiresAt: nil)
    }
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        DebridTorrentID(rawValue: "1")
    }
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        DebridTorrent(id: id, infoHashHex: "", name: "t", size: 0, progress: 1,
                      state: .completed, files: [], seeds: nil, downloadSpeed: nil, eta: nil)
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        URL(string: "https://cdn.example.com/file.bin")!
    }
    func delete(torrent: DebridTorrentID) async throws {}
}
