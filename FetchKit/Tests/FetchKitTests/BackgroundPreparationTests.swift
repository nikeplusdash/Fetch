import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// The uncached path, moved off the sheet.
///
/// `prepareMagnet` and `enqueueMagnet` submit a magnet and then poll until the
/// debrid holds the whole torrent before they return — minutes to hours for an
/// uncached one — and every caller of theirs was a modal sheet. So the reported
/// symptom, "it keeps loading even though it has been queued": the magnet was
/// on the user's account within a second, and the only evidence of it was
/// trapped behind a spinner.
///
/// `beginPreparation` returns after the submit and reports the debrid's own
/// progress as events.
// `.usesStubURLProtocol` because this builds engines on
// `StubURLProtocol.makeConfiguration()`. `.serialized` orders tests *within* a
// suite; the stub's recorder and response queue are process-global, so a suite
// that touches it without this trait runs alongside the others and pops their
// responses. It surfaced as `GutenbergProviderTests` asking for a third page
// it had no reason to ask for — a failure with nothing to do with either
// suite's subject, one run in three.
@Suite(.serialized, .usesStubURLProtocol) struct BackgroundPreparationTests {
    /// A debrid that needs `readyAfter` polls before it has the torrent, so a
    /// test can observe the window in which the old API had not yet returned.
    private actor Progressing: DebridProvider {
        nonisolated let id = DebridProviderID(rawValue: "fake")
        nonisolated let displayName = "Fake"

        private let readyAfter: Int
        private let failing: Bool
        private(set) var polls = 0
        private(set) var submissions = 0

        init(readyAfter: Int, failing: Bool = false) {
            self.readyAfter = readyAfter
            self.failing = failing
        }

        nonisolated func validateCredentials() async throws -> DebridAccount {
            DebridAccount(email: nil, plan: nil, expiresAt: nil)
        }
        nonisolated func checkCached(
            hashes: [String], listFiles: Bool
        ) async throws -> [String: CacheEntry] { [:] }

        func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
            submissions += 1
            return DebridTorrentID(rawValue: "1")
        }

        func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
            polls += 1
            if failing {
                return Self.torrent(id: id, state: .failed(reason: "dead"), files: [])
            }
            if polls <= readyAfter {
                return Self.torrent(
                    id: id, state: .downloading, files: [],
                    progress: Double(polls) / Double(readyAfter + 1))
            }
            // Ready, but reported as `uploading` — which is what TorBox says
            // the moment a finished torrent starts seeding. A readiness check
            // keyed on `.completed` alone waits here forever.
            return Self.torrent(
                id: id, state: .uploading, files: Self.files, progress: 1,
                filesArePresent: true)
        }

        nonisolated static var files: [DebridFile] {
            [
                DebridFile(id: DebridFileID(rawValue: "0"), name: "show/a.mkv",
                           shortName: "a.mkv", size: 10, mimeType: nil),
                DebridFile(id: DebridFileID(rawValue: "1"), name: "show/b.mkv",
                           shortName: "b.mkv", size: 20, mimeType: nil),
            ]
        }

        nonisolated static func torrent(
            id: DebridTorrentID, state: DebridTorrentState, files: [DebridFile],
            progress: Double = 0, filesArePresent: Bool = false
        ) -> DebridTorrent {
            DebridTorrent(
                id: id, infoHashHex: "", name: "t", size: 30, progress: progress,
                state: state, files: files, seeds: 7, downloadSpeed: 1_000, eta: 5,
                filesArePresent: filesArePresent)
        }

        nonisolated func files(in id: DebridTorrentID) async throws -> [DebridFile] {
            Self.files
        }
        nonisolated func downloadURL(
            torrent: DebridTorrentID, file: DebridFileID
        ) async throws -> URL {
            URL(string: "https://cdn.example/file")!
        }
        nonisolated func delete(torrent: DebridTorrentID) async throws {}
    }

    private static let magnet =
        "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Show"

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Collects events until `stop` is satisfied, or the timeout expires.
    private func events(
        from engine: DownloadEngine, until stop: @escaping @Sendable ([DownloadEvent]) -> Bool
    ) -> Task<[DownloadEvent], Never> {
        Task {
            var collected: [DownloadEvent] = []
            for await event in engine.events {
                collected.append(event)
                if stop(collected) { break }
            }
            return collected
        }
    }

    private func engine(_ provider: any DebridProvider) -> DownloadEngine {
        DownloadEngine(
            provider: provider,
            transfer: RangeTransfer(body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1,
            // The poll's backoff is not what these tests are about.
            pollInterval: 0.01)
    }

    // MARK: - It returns

    /// The whole point. `prepareMagnet` would still be inside its poll here.
    @Test func itReturnsWhileTheDebridIsStillFetching() async throws {
        let provider = Progressing(readyAfter: 50)
        let engine = engine(provider)

        let id = try await engine.beginPreparation(
            Self.magnet, selecting: nil, subfolder: nil, destinationRoot: tempRoot())

        #expect(await provider.submissions == 1)
        #expect(await engine.activePreparations.contains(id))
        await engine.cancelPreparation(id)
    }

    /// A magnet the service refuses outright throws where the caller can show
    /// it, rather than becoming a row that appears and dies.
    @Test func aRefusedSubmissionThrowsRatherThanBecomingARow() async throws {
        struct Refusing: DebridProvider {
            let id = DebridProviderID(rawValue: "fake")
            let displayName = "Fake"
            func validateCredentials() async throws -> DebridAccount {
                DebridAccount(email: nil, plan: nil, expiresAt: nil)
            }
            func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
            func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
                throw DebridError.providerRejected(detail: "ACTIVE_LIMIT")
            }
            func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
                throw DebridError.fileNotFound
            }
            func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
            func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
                throw DebridError.fileNotFound
            }
            func delete(torrent: DebridTorrentID) async throws {}
        }

        let engine = engine(Refusing())
        await #expect(throws: DebridError.providerRejected(detail: "ACTIVE_LIMIT")) {
            _ = try await engine.beginPreparation(
                Self.magnet, selecting: nil, subfolder: nil, destinationRoot: self.tempRoot())
        }
        #expect(await engine.activePreparations.isEmpty)
    }

    // MARK: - It reports

    @Test func theDebridsOwnProgressIsReported() async throws {
        let engine = engine(Progressing(readyAfter: 2))
        let collector = events(from: engine) { events in
            events.contains { if case .preparationFinished = $0 { true } else { false } }
        }

        _ = try await engine.beginPreparation(
            Self.magnet, selecting: nil, subfolder: nil, destinationRoot: tempRoot())
        let seen = await collector.value

        guard case .preparationStarted(_, let name, _) = seen.first else {
            Issue.record("the first event is not .preparationStarted: \(String(describing: seen.first))")
            return
        }
        #expect(name == "Show")

        let progress = seen.compactMap { event -> PreparationProgress? in
            if case .preparationProgress(_, let p) = event { return p }
            return nil
        }
        #expect(progress.count >= 2)
        #expect(progress.first?.seeds == 7)
        #expect(progress.first?.statusText == "Downloading to your debrid")
    }

    /// TorBox reports a finished torrent as `uploading` once it starts
    /// seeding — `download_present` is the field that says the files are
    /// there, and it was decoded and dropped for the whole life of the
    /// provider. A poll keyed on `.completed` alone never leaves this state.
    @Test func aSeedingTorrentIsTreatedAsReady() async throws {
        let engine = engine(Progressing(readyAfter: 1))
        let collector = events(from: engine) { events in
            events.filter { if case .enqueued = $0 { true } else { false } }.count == 2
        }

        _ = try await engine.beginPreparation(
            Self.magnet, selecting: nil, subfolder: nil, destinationRoot: tempRoot())
        let seen = await collector.value

        #expect(seen.contains { if case .preparationFinished = $0 { true } else { false } })
    }

    /// The row does not jump: the files land under the key the preparation
    /// announced before they existed, so what the user sees is one row that
    /// stops preparing and starts downloading.
    @Test func theFilesLandUnderTheKeyThePreparationAnnounced() async throws {
        let engine = engine(Progressing(readyAfter: 1))
        let collector = events(from: engine) { events in
            events.filter { if case .enqueued = $0 { true } else { false } }.count == 2
        }

        _ = try await engine.beginPreparation(
            Self.magnet, selecting: nil, subfolder: nil, destinationRoot: tempRoot())
        let seen = await collector.value

        guard case .preparationStarted(_, _, let announced) = seen.first else {
            Issue.record("no .preparationStarted")
            return
        }
        let enqueued = seen.compactMap { event -> DownloadID? in
            if case .enqueued(let id, _, _) = event { return id }
            return nil
        }
        #expect(enqueued.count == 2)
        for id in enqueued {
            #expect(await engine.request(for: id)?.groupKey == announced)
        }
    }

    /// A selection made against the torrent's own metadata is still resolved
    /// by relative path against the authoritative list (§6) — the background
    /// path must not quietly become "download everything".
    @Test func theSelectionIsHonouredWhenTheTorrentLands() async throws {
        let engine = engine(Progressing(readyAfter: 1))
        let collector = events(from: engine) { events in
            events.contains { if case .preparationFinished = $0 { true } else { false } }
                && events.contains { if case .enqueued = $0 { true } else { false } }
        }

        _ = try await engine.beginPreparation(
            Self.magnet, selecting: ["show/b.mkv"], subfolder: nil,
            destinationRoot: tempRoot())
        let seen = await collector.value

        let names = seen.compactMap { event -> String? in
            if case .enqueued(_, let filename, _) = event { return filename }
            return nil
        }
        #expect(names == ["b.mkv"])
    }

    // MARK: - It ends

    @Test func aFailedTorrentReportsAndEnqueuesNothing() async throws {
        let engine = engine(Progressing(readyAfter: 0, failing: true))
        let collector = events(from: engine) { events in
            events.contains { if case .preparationFailed = $0 { true } else { false } }
        }

        _ = try await engine.beginPreparation(
            Self.magnet, selecting: nil, subfolder: nil, destinationRoot: tempRoot())
        let seen = await collector.value

        #expect(!seen.contains { if case .enqueued = $0 { true } else { false } })
        #expect(await engine.activePreparations.isEmpty)
    }

    /// Cancelling reports itself as a cancel, not as a failure — the user did
    /// this on purpose and does not need an error about it.
    @Test func cancellingStopsThePollAndSaysSo() async throws {
        let provider = Progressing(readyAfter: 1_000)
        let engine = engine(provider)
        let collector = events(from: engine) { events in
            events.contains { if case .preparationCancelled = $0 { true } else { false } }
        }

        let id = try await engine.beginPreparation(
            Self.magnet, selecting: nil, subfolder: nil, destinationRoot: tempRoot())
        await engine.cancelPreparation(id)
        let seen = await collector.value

        #expect(!seen.contains { if case .preparationFailed = $0 { true } else { false } })
        #expect(await engine.activePreparations.isEmpty)

        // And it really stopped, rather than merely stopping being reported.
        let atCancel = await provider.polls
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await provider.polls <= atCancel + 1)
    }
}

/// `DebridTorrent.isReady`, on its own.
@Suite struct DebridTorrentReadinessTests {
    private func torrent(
        state: DebridTorrentState, files: [DebridFile], present: Bool
    ) -> DebridTorrent {
        DebridTorrent(
            id: DebridTorrentID(rawValue: "1"), infoHashHex: "", name: "t", size: 1,
            progress: 1, state: state, files: files, seeds: nil, downloadSpeed: nil,
            eta: nil, filesArePresent: present)
    }

    private var oneFile: [DebridFile] {
        [DebridFile(id: DebridFileID(rawValue: "0"), name: "a", shortName: "a",
                    size: 1, mimeType: nil)]
    }

    @Test func aSeedingTorrentWithItsFilesPresentIsReady() {
        #expect(torrent(state: .uploading, files: oneFile, present: true).isReady)
    }

    @Test func aSeedingTorrentWithoutThatSignalIsNotReady() {
        #expect(!torrent(state: .uploading, files: oneFile, present: false).isReady)
    }

    @Test func aCompletedTorrentIsReadyWithoutTheSignal() {
        #expect(torrent(state: .completed, files: oneFile, present: false).isReady)
    }

    /// A service that says ready and lists nothing has nothing to enqueue, and
    /// treating it as ready produced a torrent with no rows at all.
    @Test func readinessStillRequiresAFileList() {
        #expect(!torrent(state: .completed, files: [], present: true).isReady)
    }

    /// A provider that says nothing about presence behaves exactly as before.
    @Test func theSignalDefaultsToAbsent() {
        let legacy = DebridTorrent(
            id: DebridTorrentID(rawValue: "1"), infoHashHex: "", name: "t", size: 1,
            progress: 1, state: .downloading, files: oneFile, seeds: nil,
            downloadSpeed: nil, eta: nil)
        #expect(!legacy.filesArePresent)
        #expect(!legacy.isReady)
    }
}

/// Cancelling should cancel — on the service too.
///
/// Leaving the torrent behind was the old behaviour, argued as "the user has
/// already paid the wait for it". That is backwards for the case it covers:
/// cancelling an uncached torrent cancels a fetch the service is running right
/// now, and leaving it means the account goes on downloading something nobody
/// wants, holding a slot until it finishes.
@Suite(.serialized, .usesStubURLProtocol) struct CancelDeletesRemotelyTests {
    private actor Recorder {
        private(set) var deleted: [String] = []
        func record(_ id: String) { deleted.append(id) }
    }

    private struct Watching: DebridProvider {
        let id = DebridProviderID(rawValue: "fake")
        let displayName = "Fake"
        let recorder: Recorder

        func validateCredentials() async throws -> DebridAccount {
            DebridAccount(email: nil, plan: nil, expiresAt: nil)
        }
        func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
        func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
            DebridTorrentID(rawValue: "77")
        }
        func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
            // Never ready: this is the uncached case, which is the whole point.
            DebridTorrent(id: id, infoHashHex: "", name: "t", size: 10, progress: 0.2,
                          state: .downloading, files: [], seeds: 3,
                          downloadSpeed: 100, eta: 60)
        }
        func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
        func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
            URL(string: "https://cdn.example/x")!
        }
        func delete(torrent: DebridTorrentID) async throws {
            await recorder.record(torrent.rawValue)
        }
    }

    private func engine(_ recorder: Recorder) -> DownloadEngine {
        DownloadEngine(provider: Watching(recorder: recorder), maxConcurrent: 1, pollInterval: 0.01)
    }

    private var root: URL { FileManager.default.temporaryDirectory }

    @Test func cancellingAPreparationDeletesTheTorrent() async throws {
        let recorder = Recorder()
        let engine = engine(recorder)
        let id = try await engine.beginPreparation(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            selecting: nil, subfolder: nil, destinationRoot: root)

        await engine.cancelPreparation(id)
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(await recorder.deleted == ["77"])
    }

    /// The escape hatch stays, for a caller that wants the row gone and the
    /// torrent kept.
    @Test func cancellingCanBeToldToLeaveItAlone() async throws {
        let recorder = Recorder()
        let engine = engine(recorder)
        let id = try await engine.beginPreparation(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            selecting: nil, subfolder: nil, destinationRoot: root)

        await engine.cancelPreparation(id, deletingRemotely: false)
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(await recorder.deleted.isEmpty)
    }
}

/// A service that says "done" and lists nothing.
///
/// Twice this shape has produced a row that polls for ever with no
/// explanation: TorBox reporting `uploading` for a finished torrent, and
/// Premiumize mapping its folder id to an empty file array. Both looked
/// identical from the engine — "not ready yet" — and both were permanent.
@Suite(.serialized, .usesStubURLProtocol) struct EmptyReadyTorrentTests {
    private struct DoneButEmpty: DebridProvider {
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
            DebridTorrent(id: id, infoHashHex: "", name: "t", size: 10, progress: 1,
                          state: .completed, files: [], seeds: nil,
                          downloadSpeed: nil, eta: nil)
        }
        func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
        func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
            URL(string: "https://cdn.example/x")!
        }
        func delete(torrent: DebridTorrentID) async throws {}
    }

    @Test func itIsReportedRatherThanPolledForever() async throws {
        let engine = DownloadEngine(
            provider: DoneButEmpty(), maxConcurrent: 1, pollInterval: 0.001)
        let collector = Task { () -> Bool in
            for await event in engine.events {
                if case .preparationFailed = event { return true }
            }
            return false
        }

        _ = try await engine.beginPreparation(
            "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            selecting: nil, subfolder: nil,
            destinationRoot: FileManager.default.temporaryDirectory)

        #expect(await collector.value, "the row would have spun for ever")
    }
}
