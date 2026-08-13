import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Minimal fake so engine tests never touch the network.
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

/// Like `FakeDebrid`, but `downloadURL` sleeps before returning — so a
/// spawned transfer `Task` is reliably still suspended (and therefore still
/// cancellable/interruptible) at the moment a test calls `pause`/`cancel`,
/// instead of racing a StubURLProtocol response that resolves synchronously.
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

/// Collects `engine.events` in the background so a test can assert on the
/// transient event stream, not just the final settled state — a zombie
/// writer's own completion callback can self-heal the end state while still
/// having emitted a misleading event along the way (see `RangeTransferTests`'
/// `Counter` for the same "small actor helper alongside a fake" pattern).
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

    /// Regression test for Task 17 Bug 1: `DownloadEvent.enqueued` used to
    /// carry only a `DownloadID`, so the UI had no way to label a row until
    /// the first `.progress` event arrived (or ever, for a download that
    /// failed before its first tick) — every row showed a literal "…". The
    /// event must carry `shortName` (the last path component the UI should
    /// render), not `name` (the full in-torrent path, e.g.
    /// "Show/Season 01/S01E03.mkv") — a multi-file torrent enqueues many
    /// rows from one magnet, and the UI cannot tell them apart from a
    /// magnet-level display name alone.
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

        // Give the recorder a beat to drain the already-emitted event.
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

        // Sanitization strips the traversal, so it lands inside root, not outside.
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

    /// Regression test for the invariant `RangeTransfer` hands to its caller:
    /// at most one in-flight `transfer(to:)` per partial URL. `pause()` used to
    /// return before the cancelled task had actually stopped, so an immediate
    /// `resume()` could start a second writer on the same `.fetchpart` file
    /// while the first was still mid-write. If that ever happens again, the
    /// completed file will not be exactly 100 bytes (it would be corrupted or,
    /// in the worst case, doubled).
    @Test func pauseThenResumeNeverStartsASecondWriter() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "100"],
                body: Data(repeating: 0x01, count: 100)
            )
        ])
        // SlowFakeDebrid keeps the first attempt suspended (awaiting its own
        // link fetch) at the moment `pause` cancels it, instead of racing a
        // StubURLProtocol response that resolves synchronously — see the
        // fix-round report for why a plain `FakeDebrid` version of this test
        // does not reliably exercise the race at all.
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

    /// A cooperative cancel unwinds the transfer with `CancellationError` —
    /// the expected outcome of a pause, not a failure. Without `fail()`
    /// ignoring it, the losing task's own completion callback can report
    /// before `pause` writes its own `.paused` state, and the UI Task 14
    /// builds on this event stream would flash "Failed" on every pause.
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

        // Give a would-be zombie writer time to surface a spurious event
        // before we stop collecting.
        try await Task.sleep(nanoseconds: 300_000_000)
        collector.cancel()

        #expect(await recorder.sawFailure == false)
        #expect(await engine.state(of: id) == .paused)
    }

    /// `pause` cancels cooperatively and then awaits the task's actual
    /// completion (`releasePath`) before writing its own final state — but
    /// `releasePath` only returns *after* the task's own `finish()` callback
    /// has already run if the download won the race and completed first.
    /// `pause` must re-read state after that await and leave a genuine
    /// completion alone, not clobber it back to `.paused` with `finalURL`
    /// dropped and the (already-renamed-away) `.fetchpart` file gone.
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

        // Wait for the FIRST `.progress` event, not a fixed delay. `onProgress`
        // only fires once the whole 100-byte buffer has actually been flushed
        // to disk — RangeTransfer's byte-iteration loop, the only place that
        // observes cancellation, has already fully drained by then, and
        // nothing between there and `finish()` (rename, dictionary update)
        // checks cancellation at all. So by the time this event lands, the
        // download is *going* to complete regardless of what `pause` does;
        // the only open question is whether `pause`'s own state write, land-
        // ing moments later, clobbers that completion or defers to it.
        //
        // A `Task.yield()`-based `FileManager.fileExists` poll loop was tried
        // and discarded: yielding every iteration hands the executor to
        // *other* ready work on every spin — including the very `finish()`
        // call it's racing — so it reliably lost, landing on `.completed`
        // even with the fix reverted (see the fix-round report for the
        // measured numbers). This `events`-based version was verified, with
        // the fix reverted, to fail reliably under the real, unfiltered
        // full-suite run — not just in isolation.
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
