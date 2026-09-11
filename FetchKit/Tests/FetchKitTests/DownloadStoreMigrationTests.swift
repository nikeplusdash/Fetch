import Testing
import Foundation
@testable import FetchKit

private let migrationStorePath: String? =
    ProcessInfo.processInfo.environment["FETCH_MIGRATION_STORE"]

@Suite @MainActor struct DownloadStoreMigrationTests {

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

        for record in records {
            #expect(record.groupKeyRaw == nil || !(record.groupKeyRaw ?? "").isEmpty)
            if record.makeRequest() != nil {
                let request = try #require(record.makeRequest())
                #expect(request.groupKey.content == record.infoHash
                        || record.groupKeyRaw != nil)
            }
        }
        let name = URL(fileURLWithPath: try #require(migrationStorePath)).lastPathComponent
        print("migrated \(records.count) records from \(name)")
    }

    @Test(.enabled(if: migrationStorePath != nil))
    func recordsWithoutAGroupNameStillLoad() throws {
        let store = try openCopyOfRealStore()
        let records = try store.loadAll()
        #expect(!records.isEmpty)

        for record in records {
            _ = try #require(record.makeRequest())
        }

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
