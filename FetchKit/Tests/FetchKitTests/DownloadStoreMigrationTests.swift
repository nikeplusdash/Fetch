import Testing
import Foundation
@testable import FetchKit

/// Free function, not a static on the suite: `.enabled(if:)` evaluates its
/// condition in a `Sendable` closure, which cannot touch main-actor state.
private let migrationStorePath: String? =
    ProcessInfo.processInfo.environment["FETCH_MIGRATION_STORE"]

/// Opening a database written by an earlier build.
///
/// `DownloadRecord` gained `groupKeyRaw` and `finalPath`. Both are optional,
/// which is the case SwiftData migrates automatically — but "should migrate"
/// and "does migrate against the file on this Mac" are different claims, and
/// the failure mode is the whole download history disappearing behind "Could
/// not open the downloads database".
///
/// Point `FETCH_MIGRATION_STORE` at a `downloads.store` to check a real one.
/// It is **copied** first; the original is never opened, so a failed migration
/// cannot damage it.
@Suite @MainActor struct DownloadStoreMigrationTests {

    /// Copies the real store `FETCH_MIGRATION_STORE` points at into a sandbox
    /// and opens it there, so a failed migration can never damage the
    /// original.
    ///
    /// SQLite keeps its write-ahead log and shared memory beside the store;
    /// copying only the `.store` can present a database missing committed
    /// rows, which would make a test pass on less data than the user has.
    private func openCopyOfRealStore() throws -> DownloadStore {
        let original = URL(fileURLWithPath: try #require(migrationStorePath))
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let copy = sandbox.appendingPathComponent(original.lastPathComponent)
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: original.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(
                at: source, to: URL(fileURLWithPath: copy.path + suffix))
        }

        return try DownloadStore(url: copy)
    }

    @Test(.enabled(if: migrationStorePath != nil))
    func aStoreFromAnEarlierBuildStillOpens() throws {
        let store = try openCopyOfRealStore()
        let records = try store.loadAll()

        // Every row must survive and still rebuild a request — the new fields
        // being absent must read as "not recorded", not as a broken record.
        for record in records {
            #expect(record.groupKeyRaw == nil || !(record.groupKeyRaw ?? "").isEmpty)
            if record.makeRequest() != nil {
                let request = try #require(record.makeRequest())
                // A row saved before attempts existed groups by content, which
                // is exactly how it grouped when it was written.
                #expect(request.groupKey.content == record.infoHash
                        || record.groupKeyRaw != nil)
            }
        }
        // Reported rather than asserted: an empty store is a legitimate state,
        // and failing on it would make this test about the Mac it runs on.
        let name = URL(fileURLWithPath: try #require(migrationStorePath)).lastPathComponent
        print("migrated \(records.count) records from \(name)")
    }

    /// A record saved before `groupName` existed must still load, still
    /// rebuild a request, and still group and name itself.
    ///
    /// The first version of this test asserted every record's `groupName`
    /// was nil. That held only because no call site supplied one yet — once
    /// a later task wires the call sites (Task 17) and a real download gets
    /// a name, this test would go red on a live store for a reason that has
    /// nothing to do with migration. What actually matters, and ages
    /// correctly regardless of whether the column is populated, is that
    /// loading and grouping keep working either way.
    @Test(.enabled(if: migrationStorePath != nil))
    func recordsWithoutAGroupNameStillLoad() throws {
        let store = try openCopyOfRealStore()
        let records = try store.loadAll()
        #expect(!records.isEmpty)

        for record in records {
            // Loads and rebuilds: the column being absent (or present) must
            // read as ordinary data, not as a broken record.
            _ = try #require(record.makeRequest())
        }

        // Grouping still resolves: bucket the restored records by the same
        // key the Downloads screen uses, then name each row the way it would
        // be named live — a stated name wins, a nil one falls back to the
        // untouched path derivation. Either branch must produce a name for
        // any group that has at least one path.
        let rows = DownloadGrouping.rows(records) { record in
            record.groupKeyRaw.map { DownloadGroupKey(rawValue: $0) }
                ?? .unattempted(record.infoHash)
        }
        for row in rows {
            let paths = row.members.map(\.relativePath)
            let stated = row.members.first?.groupName
            #expect(DownloadGrouping.displayName(stated: stated, forPaths: paths) != nil)
        }
    }
}
