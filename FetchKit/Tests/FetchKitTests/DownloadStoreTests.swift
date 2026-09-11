import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite @MainActor struct DownloadStoreTests {
    private func makeStore() throws -> DownloadStore {
        try DownloadStore(inMemory: true)
    }

    private func makeRequest(
        name: String = "movie.mkv", size: Int64 = 1000, root: String = "/tmp/fetch-test"
    ) -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "torbox"),
            torrentID: DebridTorrentID(rawValue: "t1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "f1"), name: name,
                shortName: (name as NSString).lastPathComponent, size: size, mimeType: nil),
            infoHashHex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            subfolder: "Movies",
            destinationRoot: URL(fileURLWithPath: root, isDirectory: true))
    }

    @Test func aSavedDownloadComesBack() throws {
        let store = try makeStore()
        let id = DownloadID()

        try store.save(id: id, request: makeRequest(), state: .downloading, bytesDownloaded: 256)

        let all = try store.loadAll()
        #expect(all.count == 1)
        let record = try #require(all.first)
        #expect(record.id == id.rawValue)
        #expect(record.state == .downloading)
        #expect(record.bytesDownloaded == 256)
        #expect(record.totalBytes == 1000)
    }

    @Test func everythingNeededToResumeRoundTrips() throws {
        let store = try makeStore()
        let id = DownloadID()
        let request = makeRequest(name: "Pack/ep01.mkv", root: "/tmp/somewhere")

        try store.save(id: id, request: request, state: .paused, bytesDownloaded: 10)
        let record = try #require(try store.loadAll().first)
        let rebuilt = try #require(record.makeRequest())

        #expect(rebuilt.providerID == request.providerID)
        #expect(rebuilt.torrentID == request.torrentID)
        #expect(rebuilt.file.id == request.file.id)
        #expect(rebuilt.file.name == request.file.name)
        #expect(rebuilt.file.size == request.file.size)
        #expect(rebuilt.infoHashHex == request.infoHashHex)
        #expect(rebuilt.subfolder == request.subfolder)
        #expect(rebuilt.destinationRoot.path == request.destinationRoot.path)
    }

    @Test func savingTheSameIDUpdatesRatherThanDuplicating() throws {
        let store = try makeStore()
        let id = DownloadID()

        try store.save(id: id, request: makeRequest(), state: .queued, bytesDownloaded: 0)
        try store.save(id: id, request: makeRequest(), state: .downloading, bytesDownloaded: 500)
        try store.save(id: id, request: makeRequest(), state: .completed, bytesDownloaded: 1000)

        let all = try store.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.state == .completed)
        #expect(all.first?.bytesDownloaded == 1000)
    }

    @Test func groupNameAndMetadataArePersistedOnInsert() throws {
        let store = try makeStore()
        let id = DownloadID()
        let request = DownloadRequest(
            providerID: DebridProviderID(rawValue: "direct"),
            torrentID: DebridTorrentID(rawValue: "direct"),
            file: DebridFile(
                id: DebridFileID(rawValue: "u"), name: "a.epub", shortName: "a.epub",
                size: 10, mimeType: nil),
            infoHashHex: "",
            subfolder: "Books",
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            directURL: URL(string: "https://example.org/a.epub"),
            groupName: "The Three-Body Problem",
            metadata: ReleaseMetadata(mediaKind: .book, title: "The Three-Body Problem"))

        try store.save(id: id, request: request, state: .queued, bytesDownloaded: 0)

        let record = try #require(try store.loadAll().first)
        #expect(record.groupName == "The Three-Body Problem")
        #expect(record.metadata.mediaKind == .book)
        #expect(record.metadata.title == "The Three-Body Problem")
    }

    @Test func aSecondSaveWithNoOpinionPreservesTheStatedNameAndMetadata() throws {
        let store = try makeStore()
        let id = DownloadID()
        let named = DownloadRequest(
            providerID: DebridProviderID(rawValue: "direct"),
            torrentID: DebridTorrentID(rawValue: "direct"),
            file: DebridFile(
                id: DebridFileID(rawValue: "u"), name: "a.epub", shortName: "a.epub",
                size: 10, mimeType: nil),
            infoHashHex: "",
            subfolder: "Books",
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            directURL: URL(string: "https://example.org/a.epub"),
            groupName: "The Three-Body Problem",
            metadata: ReleaseMetadata(mediaKind: .book, title: "The Three-Body Problem"))
        try store.save(id: id, request: named, state: .downloading, bytesDownloaded: 3)

        let unopinionated = DownloadRequest(
            providerID: DebridProviderID(rawValue: "direct"),
            torrentID: DebridTorrentID(rawValue: "direct"),
            file: DebridFile(
                id: DebridFileID(rawValue: "u"), name: "a.epub", shortName: "a.epub",
                size: 10, mimeType: nil),
            infoHashHex: "",
            subfolder: "Books",
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            directURL: URL(string: "https://example.org/a.epub"))
        #expect(unopinionated.groupName == nil)
        #expect(unopinionated.metadata == .unparsed)

        try store.save(id: id, request: unopinionated, state: .completed, bytesDownloaded: 10)

        let record = try #require(try store.loadAll().first)
        #expect(record.groupName == "The Three-Body Problem")
        #expect(record.metadata.mediaKind == .book)
        #expect(record.metadata.title == "The Three-Body Problem")
    }

    @Test func theRestoredRequestCarriesGroupNameAndKind() throws {
        let store = try makeStore()
        let id = DownloadID()
        let request = DownloadRequest(
            providerID: DebridProviderID(rawValue: "direct"),
            torrentID: DebridTorrentID(rawValue: "direct"),
            file: DebridFile(
                id: DebridFileID(rawValue: "u"), name: "a.epub", shortName: "a.epub",
                size: 10, mimeType: nil),
            infoHashHex: "",
            subfolder: "Books",
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            directURL: URL(string: "https://example.org/a.epub"),
            groupName: "The Three-Body Problem",
            metadata: ReleaseMetadata(mediaKind: .book, title: "The Three-Body Problem"))

        try store.save(id: id, request: request, state: .queued, bytesDownloaded: 0)
        let record = try #require(try store.loadAll().first)
        let rebuilt = try #require(record.makeRequest())

        #expect(rebuilt.groupName == "The Three-Body Problem")
        #expect(rebuilt.metadata.mediaKind == .book)
        #expect(rebuilt.metadata.title == "The Three-Body Problem")
    }

    @Test func aRecordWithNeitherFieldRestoresExactlyAsBefore() throws {
        let store = try makeStore()
        let id = DownloadID()

        try store.save(id: id, request: makeRequest(), state: .queued, bytesDownloaded: 0)
        let record = try #require(try store.loadAll().first)
        let rebuilt = try #require(record.makeRequest())

        #expect(rebuilt.groupName == nil)
        #expect(rebuilt.metadata == .unparsed)
    }

    @Test func removingADownloadDropsIt() throws {
        let store = try makeStore()
        let id = DownloadID()
        try store.save(id: id, request: makeRequest(), state: .queued, bytesDownloaded: 0)

        try store.remove(id: id)

        #expect(try store.loadAll().isEmpty)
    }

    @Test func removingSomethingAbsentIsNotAnError() throws {
        let store = try makeStore()
        try store.remove(id: DownloadID())
    }

    @Test func severalDownloadsAreKeptApart() throws {
        let store = try makeStore()
        let a = DownloadID()
        let b = DownloadID()

        try store.save(id: a, request: makeRequest(name: "a.mkv"), state: .queued, bytesDownloaded: 0)
        try store.save(id: b, request: makeRequest(name: "b.mkv"), state: .paused, bytesDownloaded: 7)

        let byID = Dictionary(uniqueKeysWithValues: try store.loadAll().map { ($0.id, $0) })
        #expect(byID[a.rawValue]?.state == .queued)
        #expect(byID[b.rawValue]?.state == .paused)
    }

    @Test func theOriginalFilenameSurvivesLaterSaves() throws {
        let store = try makeStore()
        let id = DownloadID()

        try store.save(id: id, request: makeRequest(name: "Original.Name.mkv"),
                       state: .queued, bytesDownloaded: 0)
        try store.save(id: id, request: makeRequest(name: "Original.Name.mkv"),
                       state: .downloading, bytesDownloaded: 500)

        #expect(try store.loadAll().first?.originalFilename == "Original.Name.mkv")
    }
}

@Suite @MainActor struct DownloadStoreLocationTests {
    @Test func theDefaultStoreLivesInFetchsOwnDirectory() {
        let url = DownloadStore.defaultStoreURL

        #expect(url.deletingLastPathComponent().lastPathComponent == "Fetch")
        #expect(url.lastPathComponent != "default.store")
        #expect(url.path.contains("Application Support"))
    }
}

@Suite @MainActor struct DownloadRecordMetadataEncodingTests {
    private func makeRecord() -> DownloadRecord {
        DownloadRecord(
            infoHash: "", providerID: "", debridTorrentID: "", debridFileID: "",
            displayName: "", relativePath: "", destinationPath: "",
            originalFilename: "", totalBytes: 0)
    }

    @Test func metadataJSONOrdersReleaseMetadatasOwnFieldsAlphabetically() throws {
        let record = makeRecord()
        record.metadata = ReleaseMetadata(
            mediaKind: .book, title: "The Three-Body Problem",
            isSeasonPack: true, isProper: true, isRepack: true)
        let json = try #require(record.metadataJSON)

        let keysInAlphabeticalOrder = ["isProper", "isRepack", "isSeasonPack", "mediaKind", "title"]
        let positions = try keysInAlphabeticalOrder.map {
            try #require(json.range(of: "\"\($0)\"")).lowerBound
        }
        #expect(positions == positions.sorted())
    }

    @Test func provenanceStillEncodesAsAnArrayNotAnObjectSoItsOrderIsNotFixed() throws {
        let record = makeRecord()
        record.metadata = ReleaseMetadata(
            mediaKind: .book,
            provenance: [.title: .titleParse, .mediaKind: .attribute, .author: .inherited])
        let json = try #require(record.metadataJSON)

        #expect(json.contains(#""provenance":["#))
        #expect(!json.contains(#""provenance":{"#))
    }

    @Test func aSuccessfulEncodeIsWhatChangesMetadataJSON() throws {
        let record = makeRecord()
        record.metadata = ReleaseMetadata(mediaKind: .book, title: "First")
        let afterFirst = try #require(record.metadataJSON)

        record.metadata = ReleaseMetadata(mediaKind: .book, title: "Second")
        let afterSecond = try #require(record.metadataJSON)

        #expect(afterFirst != afterSecond)
        #expect(record.metadata.title == "Second")
    }
}

@Suite @MainActor struct RenamePersistenceTests {
    @Test func theRenamedPathRoundTrips() throws {
        let store = try DownloadStore(inMemory: true)
        let id = DownloadID()
        let request = DownloadRequest(
            providerID: DebridProviderID(rawValue: "torbox"),
            torrentID: DebridTorrentID(rawValue: "t1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "f1"), name: "Pack/E05.mkv",
                shortName: "E05.mkv", size: 100, mimeType: nil),
            infoHashHex: "aa", subfolder: "TV Shows",
            destinationRoot: URL(fileURLWithPath: "/downloads", isDirectory: true),
            renamedPath: "Show/Season 03/Show - S03E05.mkv")

        try store.save(id: id, request: request, state: .completed, bytesDownloaded: 100)
        let record = try #require(try store.loadAll().first)
        let rebuilt = try #require(record.makeRequest())

        #expect(rebuilt.renamedPath == "Show/Season 03/Show - S03E05.mkv")
        #expect(RenameReversal.plan(for: rebuilt) != nil)
    }
}
