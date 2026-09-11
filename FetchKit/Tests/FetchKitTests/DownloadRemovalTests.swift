import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct DownloadRemovalTests {
    private struct StubDebrid: DebridProvider {
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
            DebridTorrent(
                id: id, infoHashHex: "", name: "t", size: 0, progress: 1,
                state: .completed, files: [], seeds: nil, downloadSpeed: nil, eta: nil)
        }
        func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
        func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
            URL(string: "https://cdn.example.com/file.bin")!
        }
        func delete(torrent: DebridTorrentID) async throws {}
    }

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRequest(root: URL, name: String = "file.bin") -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "fake"),
            torrentID: DebridTorrentID(rawValue: "1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "0"), name: name,
                shortName: name, size: 100, mimeType: nil),
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: "Movies",
            destinationRoot: root)
    }

    private func makeEngine() -> DownloadEngine {
        DownloadEngine(
            provider: StubDebrid(),
            transfer: RangeTransfer(
                body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1)
    }

    @Test func aRemovedJobIsForgottenByTheEngine() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([StubURLProtocol.Response(status: 500)])

        let engine = makeEngine()
        let id = await engine.enqueue(makeRequest(root: root))
        try await engine.waitUntilSettled(id)

        await engine.remove(id)

        #expect(await engine.state(of: id) == nil)
        #expect(await engine.request(for: id) == nil)
    }

    @Test func removalEmitsTheRemovedEvent() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([StubURLProtocol.Response(status: 500)])

        let engine = makeEngine()
        let events = engine.events
        let seen = RemovalRecorder()
        let collector = Task {
            for await event in events {
                if case .removed(let id) = event { await seen.record(id) }
            }
        }
        defer { collector.cancel() }

        let id = await engine.enqueue(makeRequest(root: root))
        try await engine.waitUntilSettled(id)
        await engine.remove(id)

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await seen.ids == [id])
    }

    @Test func removingACompletedDownloadLeavesItsFileOnDisk() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x01, count: 100))
        ])

        let engine = makeEngine()
        let id = await engine.enqueue(makeRequest(root: root))
        try await engine.waitUntilSettled(id)
        #expect(await engine.state(of: id) == .completed)

        let landed = root.appendingPathComponent("Movies/file.bin")
        #expect(FileManager.default.fileExists(atPath: landed.path))

        await engine.remove(id)

        #expect(await engine.state(of: id) == nil)
        #expect(FileManager.default.fileExists(atPath: landed.path),
                "clearing a row must never delete the file it downloaded")
    }

    @Test func removingAnUnfinishedDownloadTakesItsPartialWithIt() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x01, count: 40))
        ])

        let engine = makeEngine()
        let id = await engine.enqueue(makeRequest(root: root))
        try await engine.waitUntilSettled(id)

        let partial = root.appendingPathComponent("Movies/file.bin.fetchpart")
        let hadPartial = FileManager.default.fileExists(atPath: partial.path)

        await engine.remove(id)

        #expect(await engine.state(of: id) == nil)
        if hadPartial {
            #expect(!FileManager.default.fileExists(atPath: partial.path))
        }
    }

    @Test func removingAnUnknownDownloadDoesNothing() async throws {
        let engine = makeEngine()
        await engine.remove(DownloadID())
        #expect(await engine.state(of: DownloadID()) == nil)
    }

    @Test func queuingTheSameTorrentTwiceProducesTwoRows() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([StubURLProtocol.Response(status: 500)])

        let engine = makeEngine()
        let files = [
            DebridFile(id: DebridFileID(rawValue: "0"), name: "Pack/a.mkv",
                       shortName: "a.mkv", size: 10, mimeType: nil),
            DebridFile(id: DebridFileID(rawValue: "1"), name: "Pack/b.mkv",
                       shortName: "b.mkv", size: 10, mimeType: nil),
        ]
        var queued: [DownloadID] = []
        func enqueueBatch() async -> [DownloadGroupKey] {
            let result = await engine.enqueueSelected(
                torrentID: DebridTorrentID(rawValue: "1"),
                infoHashHex: "abc", files: files, selecting: nil,
                subfolder: nil, destinationRoot: root)
            queued.append(contentsOf: result.downloadIDs)
            var keys: [DownloadGroupKey] = []
            for id in result.downloadIDs {
                if let request = await engine.request(for: id) { keys.append(request.groupKey) }
            }
            return keys
        }

        let first = await enqueueBatch()
        let second = await enqueueBatch()

        for id in queued { await engine.remove(id) }

        #expect(Set(first).count == 1, "one batch is one row")
        #expect(Set(second).count == 1)
        #expect(first[0] != second[0], "a second attempt is a second row")
        #expect(first[0].content == second[0].content)
    }
}

private actor RemovalRecorder {
    private(set) var ids: [DownloadID] = []
    func record(_ id: DownloadID) { ids.append(id) }
}

@Suite(.serialized, .usesStubURLProtocol) struct RemovingAnUnknownJobTests {
    private struct Silent: DebridProvider {
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
            DebridTorrent(id: id, infoHashHex: "", name: "t", size: 0, progress: 0,
                          state: .queued, files: [], seeds: nil, downloadSpeed: nil, eta: nil)
        }
        func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
        func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
            URL(string: "https://cdn.example/x")!
        }
        func delete(torrent: DebridTorrentID) async throws {}
    }

    @Test func anIdThisEngineNeverHadIsStillReportedRemoved() async throws {
        let engine = DownloadEngine(provider: Silent(), maxConcurrent: 1)
        let stranger = DownloadID()

        let collector = Task { () -> Bool in
            for await event in engine.events {
                if case .removed(let id) = event, id == stranger { return true }
            }
            return false
        }

        await engine.remove(stranger)
        #expect(await collector.value, "the row would never clear")
    }
}
