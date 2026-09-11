import Foundation
import SwiftData
import FetchPluginAPI

/**
 Persists download rows so they survive quitting the app.

 **Why this exists.** `DownloadRecord` and `LaunchRecovery` were written in
 M1 and never connected to anything, so quitting mid-download lost the row
 outright — despite M1's acceptance criterion saying a relaunch resumes. It
 also forced `AppModel.saveAPIKey` to refuse while downloads are active,
 since there was no way to reconcile a row back to a job.

 `@MainActor` rather than an actor of its own: `ModelContext` is not
 `Sendable`, and the only caller is `AppModel`, which is already main-actor.
 Downloads are tens of rows written a few times a second at worst, so there
 is nothing here worth moving off the main thread for.
 */
@MainActor
public final class DownloadStore {
    private let container: ModelContainer
    private let context: ModelContext

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

    /**
     Inserts or updates the row for `id`.

     Progress events arrive several times a second, so this must update in
     place — inserting per tick would grow the database without bound and
     resurrect every row on relaunch.

     `originalFilename` is written only on insert: it is what makes a rename
     reversible (§9), so a later progress save must never overwrite it with
     the current name.
     */
    public func save(
        id: DownloadID, request: DownloadRequest,
        state: DownloadState, bytesDownloaded: Int64,
        segmentMap: SegmentMap? = nil,
        allFiles: [TorrentMetadata.File]? = nil,
        finalURL: URL? = nil,
        lastError: String? = nil,
        cloudReAddSource: String? = nil
    ) throws {
        if let existing = try fetch(id) {
            existing.state = state
            existing.bytesDownloaded = bytesDownloaded
            existing.lastError = state == .failed ? lastError : nil
            existing.totalBytes = request.file.size
            existing.groupKeyRaw = request.groupKey.rawValue
            existing.sourceJSON = Self.encode(request.source)
            if let name = request.groupName, !name.isEmpty { existing.groupName = name }
            if request.metadata != .unparsed { existing.metadata = request.metadata }
            if let finalURL { existing.finalPath = finalURL.path }
            if let cloudReAddSource { existing.cloudReAddSource = cloudReAddSource }
            if let segmentMap { existing.segmentMap = segmentMap }
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
                metadataJSON: request.metadata == .unparsed ? nil : Self.encode(request.metadata),
                cloudReAddSource: cloudReAddSource
            ))
        }
        try context.save()
    }

    nonisolated static func encode(_ source: DownloadSource) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(source)).flatMap { String(data: $0, encoding: .utf8) }
    }

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

    /**
     Drops terminal rows older than `age`. Nothing calls this yet; it is the
     seam for the Downloads tab's "Clear Completed".
     */
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
    /**
     Rebuilds the request needed to resume this download.

     Returns nil when the stored destination is unusable — a row pointing at
     a path that cannot be reconstructed is better surfaced as skipped than
     restored into a job that will fail on its first write.
     */
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
            renamedPath: renamedPath,
            groupKey: groupKeyRaw.map { DownloadGroupKey(rawValue: $0) }
                ?? .unattempted(infoHash),
            groupName: groupName,
            metadata: metadata
        )
    }

    public var finalURL: URL? {
        finalPath.map { URL(fileURLWithPath: $0) }
    }
}
