import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct BackgroundPreparationTests {
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
            pollInterval: 0.01)
    }


    @Test func itReturnsWhileTheDebridIsStillFetching() async throws {
        let provider = Progressing(readyAfter: 50)
        let engine = engine(provider)

        let id = try await engine.beginPreparation(
            Self.magnet, selecting: nil, subfolder: nil, destinationRoot: tempRoot())

        #expect(await provider.submissions == 1)
        #expect(await engine.activePreparations.contains(id))
        await engine.cancelPreparation(id)
    }

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

        let atCancel = await provider.polls
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await provider.polls <= atCancel + 1)
    }
}

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

    @Test func readinessStillRequiresAFileList() {
        #expect(!torrent(state: .completed, files: [], present: true).isReady)
    }

    @Test func theSignalDefaultsToAbsent() {
        let legacy = DebridTorrent(
            id: DebridTorrentID(rawValue: "1"), infoHashHex: "", name: "t", size: 1,
            progress: 1, state: .downloading, files: oneFile, seeds: nil,
            downloadSpeed: nil, eta: nil)
        #expect(!legacy.filesArePresent)
        #expect(!legacy.isReady)
    }
}

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
