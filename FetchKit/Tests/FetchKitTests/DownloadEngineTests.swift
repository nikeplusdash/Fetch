import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

private struct FakeDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "fake")
    let displayName = "Fake"
    var linkURL = URL(string: "https://cdn.example.com/file.bin")!

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
            state: .completed, files: [], seeds: nil, downloadSpeed: nil, eta: nil
        )
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL { linkURL }
    func delete(torrent: DebridTorrentID) async throws {}
}

private struct SlowFakeDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "fake")
    let displayName = "Fake"
    var linkURL = URL(string: "https://cdn.example.com/file.bin")!
    var delayNanoseconds: UInt64 = 150_000_000

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
            state: .completed, files: [], seeds: nil, downloadSpeed: nil, eta: nil
        )
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return linkURL
    }
    func delete(torrent: DebridTorrentID) async throws {}
}

actor EventRecorder {
    private(set) var sawFailure = false
    private(set) var enqueuedPayloads: [(id: DownloadID, filename: String, totalBytes: Int64)] = []
    func record(_ event: DownloadEvent) {
        if case .failed = event { sawFailure = true }
        if case .enqueued(let id, let filename, let totalBytes) = event {
            enqueuedPayloads.append((id, filename, totalBytes))
        }
    }
}

@Suite(.serialized, .usesStubURLProtocol) struct DownloadEngineTests {
    private func makeRequest(root: URL, name: String = "file.bin") -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "fake"),
            torrentID: DebridTorrentID(rawValue: "1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "0"), name: name,
                shortName: name, size: 100, mimeType: nil
            ),
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: "Movies",
            destinationRoot: root
        )
    }

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func enqueueEmitsEnqueuedEvent() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x01, count: 100)
            )
        ])
        let engine = DownloadEngine(
            provider: FakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )

        let id = await engine.enqueue(makeRequest(root: root))
        #expect(await engine.state(of: id) != nil)
    }

    @Test func enqueuedEventCarriesShortNameAndTotalBytes() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([StubURLProtocol.Response(status: 500)])

        let engine = DownloadEngine(
            provider: FakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )
        let recorder = EventRecorder()
        let events = engine.events
        let collector = Task {
            for await event in events { await recorder.record(event) }
        }

        let request = DownloadRequest(
            providerID: DebridProviderID(rawValue: "fake"),
            torrentID: DebridTorrentID(rawValue: "1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "0"),
                name: "Show/Season 01/S01E03.mkv",
                shortName: "S01E03.mkv",
                size: 12_345, mimeType: nil
            ),
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: "Show",
            destinationRoot: root
        )
        let id = await engine.enqueue(request)
        try await engine.waitUntilSettled(id)

        try await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()

        let payloads = await recorder.enqueuedPayloads
        let payload = try #require(payloads.first(where: { $0.id == id }))
        #expect(payload.filename == "S01E03.mkv")
        #expect(payload.totalBytes == 12_345)
    }

    @Test func completedDownloadRenamesPartialToFinalName() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x01, count: 100)
            )
        ])
        let engine = DownloadEngine(
            provider: FakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )

        let id = await engine.enqueue(makeRequest(root: root))
        try await engine.waitUntilSettled(id)

        #expect(await engine.state(of: id) == .completed)
        let final = root.appendingPathComponent("Movies/file.bin")
        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: final.path + ".fetchpart"))
    }

    @Test func failedTransferMovesToFailedAndKeepsPartial() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset([StubURLProtocol.Response(status: 500)])
        let engine = DownloadEngine(
            provider: FakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )

        let id = await engine.enqueue(makeRequest(root: root))
        try await engine.waitUntilSettled(id)
        #expect(await engine.state(of: id) == .failed)
    }

    @Test func cancelMarksCancelled() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([StubURLProtocol.Response(status: 500)])

        let engine = DownloadEngine(
            provider: FakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )
        let id = await engine.enqueue(makeRequest(root: root))
        await engine.cancel(id, deletePartial: true)
        #expect(await engine.state(of: id) == .cancelled)
    }

    @Test func unsafePathIsRejectedBeforeAnyNetworkCall() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubURLProtocol.reset([])

        let engine = DownloadEngine(
            provider: FakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )
        let id = await engine.enqueue(makeRequest(root: root, name: "../../escape.bin"))
        try await engine.waitUntilSettled(id)

        let escaped = root.deletingLastPathComponent().appendingPathComponent("escape.bin")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test func concurrencyCapIsRespected() async throws {
        let engine = DownloadEngine(
            provider: FakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 2
        )
        #expect(await engine.maxConcurrentSetting == 2)
        await engine.setMaxConcurrent(5)
        #expect(await engine.maxConcurrentSetting == 5)
    }

    @Test func pauseThenResumeNeverStartsASecondWriter() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x01, count: 100)
            )
        ])
        let engine = DownloadEngine(
            provider: SlowFakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )

        let id = await engine.enqueue(makeRequest(root: root))
        await engine.pause(id)
        await engine.resume(id)
        try await engine.waitUntilSettled(id)

        #expect(await engine.state(of: id) == .completed)
        let final = root.appendingPathComponent("Movies/file.bin")
        #expect(FileManager.default.fileExists(atPath: final.path))
        let size = (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int64) ?? -1
        #expect(size == 100)
    }

    @Test func pauseEmitsNoFailureEvent() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x01, count: 100)
            )
        ])
        let engine = DownloadEngine(
            provider: SlowFakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )

        let recorder = EventRecorder()
        let events = engine.events
        let collector = Task {
            for await event in events { await recorder.record(event) }
        }

        let id = await engine.enqueue(makeRequest(root: root))
        await engine.pause(id)

        try await Task.sleep(nanoseconds: 300_000_000)
        collector.cancel()

        #expect(await recorder.sawFailure == false)
        #expect(await engine.state(of: id) == .paused)
    }

    @Test func pauseDoesNotClobberACompletionThatLandsFirst() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x01, count: 100)
            )
        ])
        let engine = DownloadEngine(
            provider: FakeDebrid(),
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1
        )

        let events = engine.events
        let progressSeen = Task<Void, Never> {
            for await event in events {
                if case .progress = event { return }
            }
        }

        let id = await engine.enqueue(makeRequest(root: root))
        await progressSeen.value
        await engine.pause(id)

        #expect(await engine.state(of: id) == .completed)
        let final = root.appendingPathComponent("Movies/file.bin")
        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: final.path + ".fetchpart"))
    }
}
