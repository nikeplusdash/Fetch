import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// The persistence half of surviving a relaunch. Every case runs against an
/// in-memory container, so nothing touches the real database.
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

    /// Enough must round-trip to rebuild a `DownloadRequest`, or a restored
    /// row cannot actually resume — it would have no torrent, file, or
    /// destination to resume against.
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

    /// Progress ticks arrive ~10/second; each must update the existing row
    /// rather than insert another.
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

    /// The insert branch's whole job for these two fields: write what the
    /// request states, exactly once, before there is a row to update.
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

    /// The rule the update branch exists to enforce: a save carrying no
    /// opinion about the name or metadata must never blank out ones a prior
    /// save already persisted. This is the only thing standing between a
    /// relaunch (`DownloadRecord.makeRequest()` rebuilds a request with
    /// `groupName: nil, metadata: .unparsed` — neither field round-trips) and
    /// every row in the library losing its title.
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

        // A later save — e.g. a progress tick, or a restore's request, which
        // never carries either field — states nothing about the name.
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

    /// The restore path, not just the save path: `makeRequest()` used to drop
    /// `groupName` and `metadata` even though both round-trip cleanly through
    /// the columns (`aSecondSaveWithNoOpinionPreservesTheStatedNameAndMetadata`
    /// above proves the store side is fine). Without this, a row queued today
    /// reads its title and its kind — then loses both the moment the app
    /// relaunches and rebuilds its request from the record, because the
    /// rebuilt request always carried `groupName: nil, metadata: .unparsed`.
    /// That is the same bug as the enqueue-time drop, one layer down.
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

    /// The other half: a record saved before these columns existed — nil
    /// `groupName`, `.unparsed` metadata — must restore exactly as it did
    /// before this task, not gain an opinion it never had.
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

    /// The original filename is stored so a rename stays reversible (§9), and
    /// it must not be clobbered by later progress saves.
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

/// Where the database lives.
///
/// SwiftData's default is `~/Library/Application Support/default.store` —
/// unnamespaced, and therefore shared with any other non-sandboxed app that
/// also takes the default. Fetch already keeps its credentials in its own
/// directory; the database belongs beside them.
@Suite @MainActor struct DownloadStoreLocationTests {
    @Test func theDefaultStoreLivesInFetchsOwnDirectory() {
        let url = DownloadStore.defaultStoreURL

        #expect(url.deletingLastPathComponent().lastPathComponent == "Fetch")
        #expect(url.lastPathComponent != "default.store")
        #expect(url.path.contains("Application Support"))
    }
}

/// `DownloadRecord.metadata`'s setter is the shared point both of
/// `DownloadStore.save`'s branches now go through, so its own guarantees are
/// what actually matter: a deterministic encoding, and no silent data loss
/// on an encoding failure.
@Suite @MainActor struct DownloadRecordMetadataEncodingTests {
    private func makeRecord() -> DownloadRecord {
        DownloadRecord(
            infoHash: "", providerID: "", debridTorrentID: "", debridFileID: "",
            displayName: "", relativePath: "", destinationPath: "",
            originalFilename: "", totalBytes: 0)
    }

    /// `.sortedKeys` sorts JSON *object* keys. `ReleaseMetadata` itself is a
    /// struct, so its own top-level fields — `mediaKind`, `title`, `year`, …
    /// — encode as a real keyed object, and this is the part `.sortedKeys`
    /// genuinely fixes: two values with the same fields set encode with
    /// those fields in the same, alphabetical order regardless of which
    /// order the initialiser's arguments were given in. Checked against
    /// adjacent fields (`isProper` / `isRepack` / `isSeasonPack`, which sort
    /// alphabetically but not declaration-order) so this can't pass by
    /// coincidentally matching either order.
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

    /// **A real limitation, discovered while writing this coverage — not a
    /// claim of victory.** `ReleaseMetadata.provenance` is
    /// `[MetadataField: MetadataSource]`, and `MetadataField`, though
    /// `String`-backed, is not literally the `String` type. Swift's
    /// synthesized `Encodable` for `Dictionary` only uses a keyed JSON
    /// *object* when `Key` is exactly `String` or `Int`; for any other
    /// (including `RawRepresentable`) key type it falls back to an
    /// *unkeyed* JSON array of alternating key/value elements. `.sortedKeys`
    /// only reorders object keys, so it has **no effect** on this array.
    /// (Confirmed by hand, not asserted below to keep this test
    /// deterministic rather than probabilistic: encoding identical
    /// `provenance` content built via two different insertion sequences
    /// reliably produced two *different* arrays across 15 separate process
    /// launches, because open-addressing collision placement — not just the
    /// per-process hash seed — depends on insertion order too. That
    /// inequality isn't guaranteed for every possible key set, so it isn't
    /// what this test asserts; the structural fact below is.)
    ///
    /// Fixing this for real means changing `provenance`'s Codable shape
    /// (e.g. keying by `MetadataField.rawValue: String` so it becomes an
    /// object) in `FetchPluginAPI/MetadataDTOs.swift` — a different target,
    /// used by every parser and consumer of `ReleaseMetadata`, not a
    /// one-line encoder setting. Out of scope here; flagged rather than
    /// fixed. This test pins the actual, current shape so a future reader
    /// isn't misled into thinking `.sortedKeys` already covers it.
    @Test func provenanceStillEncodesAsAnArrayNotAnObjectSoItsOrderIsNotFixed() throws {
        let record = makeRecord()
        record.metadata = ReleaseMetadata(
            mediaKind: .book,
            provenance: [.title: .titleParse, .mediaKind: .attribute, .author: .inherited])
        let json = try #require(record.metadataJSON)

        // The shape is an array, not an object: no `{` immediately follows
        // `"provenance":`. This is what actually makes `.sortedKeys`
        // powerless here — there is no keyed container for it to sort.
        #expect(json.contains(#""provenance":["#))
        #expect(!json.contains(#""provenance":{"#))
    }

    /// The hazard the review named: unlike `(try? encoder.encode(newValue))
    /// .flatMap { ... }`, which would overwrite `metadataJSON` with nil the
    /// moment encoding failed, the setter must leave a previously stored
    /// value alone when it cannot produce a new one. `ReleaseMetadata` itself
    /// has no value that fails to encode, so this pins the setter's actual
    /// control flow rather than the (currently unreachable) failure path:
    /// only a successful encode may ever change `metadataJSON`.
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

/// A rename must still be revertible after a relaunch.
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
        // And the revert plan can still be computed from the restored request —
        // which is the whole reason the path is stored.
        #expect(RenameReversal.plan(for: rebuilt) != nil)
    }
}
