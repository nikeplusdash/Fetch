import Foundation
import SwiftData
import FetchPluginAPI

/// Persists download rows so they survive quitting the app.
///
/// **Why this exists.** `DownloadRecord` and `LaunchRecovery` were written in
/// M1 and never connected to anything, so quitting mid-download lost the row
/// outright — despite M1's acceptance criterion saying a relaunch resumes. It
/// also forced `AppModel.saveAPIKey` to refuse while downloads are active,
/// since there was no way to reconcile a row back to a job.
///
/// `@MainActor` rather than an actor of its own: `ModelContext` is not
/// `Sendable`, and the only caller is `AppModel`, which is already main-actor.
/// Downloads are tens of rows written a few times a second at worst, so there
/// is nothing here worth moving off the main thread for.
@MainActor
public final class DownloadStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Beside the credential store, not at SwiftData's default.
    ///
    /// The default is `~/Library/Application Support/default.store` —
    /// unnamespaced, so every non-sandboxed app taking the default shares one
    /// filename. Fetch's own directory is where the rest of its data already
    /// lives.
    public static var defaultStoreURL: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fetch", isDirectory: true)
        return directory.appendingPathComponent("downloads.store")
    }

    public init(inMemory: Bool = false, url: URL? = nil) throws {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let location = url ?? Self.defaultStoreURL
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: location)
        }
        container = try ModelContainer(for: DownloadRecord.self, configurations: configuration)
        context = ModelContext(container)
    }

    /// Inserts or updates the row for `id`.
    ///
    /// Progress events arrive several times a second, so this must update in
    /// place — inserting per tick would grow the database without bound and
    /// resurrect every row on relaunch.
    ///
    /// `originalFilename` is written only on insert: it is what makes a rename
    /// reversible (§9), so a later progress save must never overwrite it with
    /// the current name.
    public func save(
        id: DownloadID, request: DownloadRequest,
        state: DownloadState, bytesDownloaded: Int64,
        segmentMap: SegmentMap? = nil,
        allFiles: [TorrentMetadata.File]? = nil,
        finalURL: URL? = nil,
        lastError: String? = nil
    ) throws {
        if let existing = try fetch(id) {
            existing.state = state
            existing.bytesDownloaded = bytesDownloaded
            // Written at last. The column has existed since the first schema
            // with five plausible reasons to be there and no writer at all —
            // failure mode #1 — which is why a failed row could say only
            // "Failed". Cleared when a state other than `.failed` is saved, so
            // a resumed download does not carry its old reason forever.
            existing.lastError = state == .failed ? lastError : nil
            existing.totalBytes = request.file.size
            existing.groupKeyRaw = request.groupKey.rawValue
            existing.sourceJSON = Self.encode(request.source)
            // Only overwrite with a real name: nil means this save had nothing
            // to say about what the row is called, not that it lost its name.
            if let name = request.groupName, !name.isEmpty { existing.groupName = name }
            // Through the property, not `metadataJSON` directly: `existing.metadata`'s
            // setter is the same operation, and going around it would mean a nil
            // encode (however unlikely) *clears* previously stored metadata instead
            // of leaving it alone — the exact hazard this guard exists to prevent.
            if request.metadata != .unparsed { existing.metadata = request.metadata }
            // Only overwrite with a real path: a nil means this save had
            // nothing to say about where the file went, not that it moved.
            if let finalURL { existing.finalPath = finalURL.path }
            // Only overwrite with a real map: a nil here means the caller had
            // nothing to report, not that the stored progress is void.
            if let segmentMap { existing.segmentMap = segmentMap }
            // Only overwrite with a real list: nil means the caller had nothing
            // to say, not that the torrent is empty.
            if let allFiles, !allFiles.isEmpty { existing.allFiles = allFiles }
            if state == .completed, existing.completedAt == nil {
                existing.completedAt = Date()
            }
        } else {
            context.insert(DownloadRecord(
                id: id.rawValue,
                infoHash: request.infoHashHex,
                providerID: request.providerID.rawValue,
                debridTorrentID: request.torrentID.rawValue,
                debridFileID: request.file.id.rawValue,
                displayName: request.file.shortName,
                relativePath: request.file.name,
                destinationPath: request.destinationRoot.path,
                subfolder: request.subfolder,
                originalFilename: request.file.name,
                totalBytes: request.file.size,
                bytesDownloaded: bytesDownloaded,
                stateRaw: state.rawValue,
                segmentMapJSON: segmentMap
                    .flatMap { try? JSONEncoder().encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) },
                torrentFileList: (allFiles?.isEmpty == false)
                    ? allFiles?.map { "\($0.path)\u{1F}\($0.length)" }.joined(separator: "\n")
                    : nil,
                renamedPath: request.renamedPath,
                groupKeyRaw: request.groupKey.rawValue,
                groupName: request.groupName,
                finalPath: finalURL?.path,
                sourceJSON: Self.encode(request.source),
                metadataJSON: request.metadata == .unparsed ? nil : Self.encode(request.metadata)
            ))
        }
        try context.save()
    }

    /// The stored form of a request's source.
    ///
    /// Written on every save, including the update branch: a row saved before
    /// the column existed would otherwise keep restoring through the
    /// torrent-triple fallback forever, and a direct download would stay
    /// unresumable across every relaunch after the one that fixed it.
    nonisolated static func encode(_ source: DownloadSource) -> String? {
        let encoder = JSONEncoder()
        // Key order is otherwise nondeterministic run to run, which would
        // rewrite this column on every save with an identical value and make
        // any diff of the store unreadable.
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(source)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Used for the insert branch's `metadataJSON`, which needs a `String?`
    /// before a `DownloadRecord` exists to own the `metadata` accessor.
    ///
    /// `.sortedKeys`, same reason as `encode(_ source:)` above: it sorts
    /// `ReleaseMetadata`'s own top-level fields. It does **not** cover
    /// `.provenance` — see `DownloadRecord.metadata`'s setter for why that
    /// dictionary is a separate, unresolved gap.
    private static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func remove(id: DownloadID) throws {
        guard let existing = try fetch(id) else { return }
        context.delete(existing)
        try context.save()
    }

    public func loadAll() throws -> [DownloadRecord] {
        try context.fetch(FetchDescriptor<DownloadRecord>(
            sortBy: [SortDescriptor(\.createdAt)]))
    }

    /// Drops terminal rows older than `age`. Nothing calls this yet; it is the
    /// seam for the Downloads tab's "Clear Completed".
    public func pruneCompleted(olderThan age: TimeInterval, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-age)
        for record in try loadAll()
        where record.state.isTerminal && (record.completedAt ?? record.createdAt) < cutoff {
            context.delete(record)
        }
        try context.save()
    }

    private func fetch(_ id: DownloadID) throws -> DownloadRecord? {
        let raw = id.rawValue
        return try context.fetch(
            FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == raw })
        ).first
    }
}

extension DownloadRecord {
    /// Rebuilds the request needed to resume this download.
    ///
    /// Returns nil when the stored destination is unusable — a row pointing at
    /// a path that cannot be reconstructed is better surfaced as skipped than
    /// restored into a job that will fail on its first write.
    public func makeRequest() -> DownloadRequest? {
        guard !destinationPath.isEmpty else { return nil }

        let file = DebridFile(
            id: DebridFileID(rawValue: debridFileID),
            name: relativePath,
            shortName: displayName,
            size: totalBytes,
            mimeType: nil)
        let restoredKey = groupKeyRaw.map { DownloadGroupKey(rawValue: $0) }
            ?? .unattempted(infoHash)

        // A stored source wins. Falling back on a corrupt one rather than
        // refusing the row: losing a download to a bad string in one field
        // would be worse than resuming it the way rows without the field do.
        if let sourceJSON,
           let data = sourceJSON.data(using: .utf8),
           let source = try? JSONDecoder().decode(DownloadSource.self, from: data) {
            return DownloadRequest(
                source: source,
                file: file,
                infoHashHex: infoHash,
                subfolder: subfolder,
                destinationRoot: URL(fileURLWithPath: destinationPath, isDirectory: true),
                renamedPath: renamedPath,
                groupKey: restoredKey,
                // Carried back so a restored row keeps its stated name and its
                // kind — without this every row lost its library grouping on
                // the very next relaunch, the same bug one layer down from the
                // enqueue-time drop this task closes.
                groupName: groupName,
                metadata: metadata)
        }

        return DownloadRequest(
            providerID: DebridProviderID(rawValue: providerID),
            torrentID: DebridTorrentID(rawValue: debridTorrentID),
            file: DebridFile(
                id: DebridFileID(rawValue: debridFileID),
                name: relativePath,
                shortName: displayName,
                size: totalBytes,
                mimeType: nil),
            infoHashHex: infoHash,
            subfolder: subfolder,
            destinationRoot: URL(fileURLWithPath: destinationPath, isDirectory: true),
            // Carried back so a rename stays revertible after a relaunch: the
            // record would otherwise know the original name but not where the
            // file actually went.
            renamedPath: renamedPath,
            // Restored, not rebuilt from the infohash: the key carries which
            // attempt queued this file, and falling back to the bare infohash
            // would re-merge every attempt into one row on launch — the exact
            // bug the attempt exists to fix. A record saved before the field
            // existed has no attempt, so it groups by content as it did then.
            groupKey: groupKeyRaw.map { DownloadGroupKey(rawValue: $0) }
                ?? .unattempted(infoHash),
            // Same reasoning as the `source`-branch above: a nil `groupName`
            // and `.unparsed` metadata (a record saved before these columns
            // existed) fall through exactly as before — `torrentGroups`' path
            // derivation and `.other` respectively.
            groupName: groupName,
            metadata: metadata
        )
    }

    /// Where the completed file was written, when the record knows.
    public var finalURL: URL? {
        finalPath.map { URL(fileURLWithPath: $0) }
    }
}
