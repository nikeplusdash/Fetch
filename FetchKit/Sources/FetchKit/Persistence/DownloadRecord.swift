import Foundation
import SwiftData

@Model
public final class DownloadRecord {
    @Attribute(.unique) public var id: UUID
    public var infoHash: String
    public var providerID: String
    public var debridTorrentID: String
    public var debridFileID: String
    public var displayName: String
    public var relativePath: String
    public var destinationPath: String
    /// The routing subfolder (`Movies`, `TV Shows/…`) chosen when the download
    /// was queued. Stored separately from `destinationPath`, which is the root:
    /// without it a restored download loses its routing and lands loose in the
    /// download directory.
    public var subfolder: String?
    /// Kept so a rename is always reversible.
    public var originalFilename: String
    public var totalBytes: Int64
    public var bytesDownloaded: Int64
    public var stateRaw: String
    /// Why this download failed, as a sentence, or nil in any other state.
    ///
    /// Unwritten for most of this project's life — five plausible reasons to
    /// exist and no producer, failure mode #1 in HANDOFF — which is why a
    /// failed row could say "Failed" and nothing more, and why the only
    /// account of the reported `error 6` was a number in a banner that had
    /// scrolled away. `DownloadStore.save` writes it now, and
    /// `DownloadEvent.failed`'s `DownloadError` is what it holds.
    public var lastError: String?
    /// `SegmentMap` as JSON. Stored rather than derived, because with parallel
    /// ranges the partial file's size no longer tells you what is done — the
    /// invariant segmented downloading traded away.
    public var segmentMapJSON: String?
    /// Every file in the torrent, as `path\u{1F}length` lines — not only the
    /// ones queued. Without it a torrent row describes the user's selection
    /// rather than the torrent, and a file skipped by mistake is invisible.
    public var torrentFileList: String?
    /// Where the file was actually written, relative to `subfolder`, when a
    /// naming strategy renamed it. Without this a rename cannot be reverted
    /// after a relaunch — the record would know the original name but not
    /// where the file went.
    public var renamedPath: String?
    /// Which Downloads row this file belongs under — `DownloadGroupKey.rawValue`.
    ///
    /// Persisted rather than rederived, because it now carries the queueing
    /// attempt as well as the content. Rebuilding it from `infoHash` alone
    /// would re-merge every attempt into one row on the next launch, which is
    /// the bug this key exists to fix. Optional so records written before it
    /// existed still load; they fall back to the infohash, exactly as they
    /// grouped when they were saved.
    public var groupKeyRaw: String?
    /// The row's name as its caller stated it. See `DownloadRequest.groupName`.
    ///
    /// Optional so a store written before this column loads unchanged; those
    /// records fall back to the path derivation, which is how they were named
    /// when they were saved.
    public var groupName: String?
    /// Where the file was actually written when it completed.
    ///
    /// Without it, "is this file still there?" had to be re-derived from the
    /// request — which misses both a rename and the `(2)` suffix
    /// `PathSanitizer.disambiguate` may have added, so a perfectly present file
    /// reads as deleted. It is also what "Show in Finder" needs after a
    /// relaunch: `DownloadItem.finalURL` is only set by the live `.finished`
    /// event, so a restored completed row had a button that did nothing.
    public var finalPath: String?

    /// The encoded `DownloadSource` (7e §4.2).
    ///
    /// Optional because it did not always exist: a row saved before this
    /// column rebuilds the torrent triple from the columns beside it, exactly
    /// as it did then, so no existing download changes behaviour.
    ///
    /// §6's rule that no CDN URL is ever persisted holds *by type*: the two
    /// debrid cases encode identifiers, and `.directHTTP` encodes a public
    /// address, because that is what each case holds.
    public var sourceJSON: String?
    /// The release metadata the download was filed under, as JSON. Persisted
    /// so the Downloads tab can group and filter by the same fields the search
    /// results do (§12.3 reuses §8 wholesale).
    public var metadataJSON: String?
    public var queuePosition: Int
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(), infoHash: String, providerID: String,
        debridTorrentID: String, debridFileID: String, displayName: String,
        relativePath: String, destinationPath: String, subfolder: String? = nil,
        originalFilename: String,
        totalBytes: Int64, bytesDownloaded: Int64 = 0,
        stateRaw: String = DownloadState.queued.rawValue,
        segmentMapJSON: String? = nil,
        torrentFileList: String? = nil,
        renamedPath: String? = nil,
        groupKeyRaw: String? = nil,
        groupName: String? = nil,
        finalPath: String? = nil,
        sourceJSON: String? = nil,
        metadataJSON: String? = nil,
        queuePosition: Int = 0, createdAt: Date = Date()
    ) {
        self.groupKeyRaw = groupKeyRaw
        self.groupName = groupName
        self.finalPath = finalPath
        self.sourceJSON = sourceJSON
        self.id = id
        self.infoHash = infoHash
        self.providerID = providerID
        self.debridTorrentID = debridTorrentID
        self.debridFileID = debridFileID
        self.displayName = displayName
        self.relativePath = relativePath
        self.destinationPath = destinationPath
        self.subfolder = subfolder
        self.originalFilename = originalFilename
        self.totalBytes = totalBytes
        self.bytesDownloaded = bytesDownloaded
        self.stateRaw = stateRaw
        self.segmentMapJSON = segmentMapJSON
        self.torrentFileList = torrentFileList
        self.renamedPath = renamedPath
        self.metadataJSON = metadataJSON
        self.queuePosition = queuePosition
        self.createdAt = createdAt
    }

    /// Decoded map, or nil when there is none or it no longer parses. A map
    /// that cannot be read is treated as absent so the download restarts
    /// cleanly rather than resuming against ranges it cannot verify.
    public var segmentMap: SegmentMap? {
        get {
            guard let segmentMapJSON, let data = segmentMapJSON.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(SegmentMap.self, from: data)
        }
        set {
            segmentMapJSON = newValue
                .flatMap { try? JSONEncoder().encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// The torrent's full contents, or empty when they were never known.
    public var allFiles: [TorrentMetadata.File] {
        get {
            (torrentFileList ?? "").split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\u{1F}")
                guard parts.count == 2, let length = Int64(parts[1]) else { return nil }
                return TorrentMetadata.File(path: String(parts[0]), length: length)
            }
        }
        set {
            // Unit separator, not a comma: paths legitimately contain commas,
            // and a delimiter that can appear in the data is not a delimiter.
            torrentFileList = newValue.isEmpty ? nil : newValue
                .map { "\($0.path)\u{1F}\($0.length)" }
                .joined(separator: "\n")
        }
    }

    /// Decoded metadata, or `.unparsed` when none was stored.
    public var metadata: ReleaseMetadata {
        get {
            guard let metadataJSON, let data = metadataJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(ReleaseMetadata.self, from: data)
            else { return .unparsed }
            return decoded
        }
        set {
            let encoder = JSONEncoder()
            // Sorts `ReleaseMetadata`'s own top-level fields (a real JSON
            // object) so the column doesn't rewrite on every save with an
            // identical value in different field order. It does **not**
            // reach `.provenance`: that's `[MetadataField: MetadataSource]`,
            // and Swift's synthesized `Encodable` for a `Dictionary` whose
            // key isn't literally `String`/`Int` encodes as an unkeyed JSON
            // *array* of alternating key/value elements, which `.sortedKeys`
            // has no power over. See `DownloadRecordMetadataEncodingTests`
            // for both halves of that — closing the array case is a
            // `FetchPluginAPI` change (`provenance`'s Codable shape), out of
            // scope here.
            encoder.outputFormatting = .sortedKeys
            // Only assign on success: unlike `try? ... .flatMap { ... }`,
            // which would overwrite `metadataJSON` with nil on an encoding
            // failure and silently erase whatever was already stored, this
            // leaves the previous value in place when encoding fails.
            if let data = try? encoder.encode(newValue), let json = String(data: data, encoding: .utf8) {
                metadataJSON = json
            }
        }
    }

    public var state: DownloadState {
        get { DownloadState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }
}

/// Pure reconciliation logic, kept free of SwiftData so it is directly
/// testable. The partial file on disk is the source of truth.
public enum LaunchRecovery {
    public struct Outcome: Equatable, Sendable {
        public let state: DownloadState
        public let bytesDownloaded: Int64
    }

    /// Reconciles a record against what is actually on disk.
    ///
    /// **The final file wins over the record.** A complete file present at its
    /// expected size means the download is done, whatever state was persisted.
    /// A real install accumulated 26 records marked `cancelled` whose files
    /// were whole and present, because a restore bug marked finished downloads
    /// `failed` and cancelling them from that section was then possible. The
    /// bytes were never in doubt — only the bookkeeping.
    ///
    /// This heals stale records; it does not resurrect abandoned ones. A
    /// cancelled download with nothing on disk stays cancelled, and a
    /// short final file is not treated as finished.
    /// **The partial file's size is not the truth for a segmented download.**
    /// `SegmentedTransfer.preallocate` grows the `.fetchpart` to the file's
    /// full length *before the first request*, so a download that failed
    /// before a single byte arrived leaves a full-size file of zeros behind.
    /// Measuring it reported those rows at 100 % on the next launch — 80 of
    /// them in the install this was found on, every one of which had
    /// transferred nothing.
    ///
    /// Worse than a wrong number: at 100 % the single-connection path takes
    /// its `offset == expectedSize` shortcut, `verify` compares sizes and
    /// passes, and a file of zeros is renamed to its final name and called
    /// Completed.
    ///
    /// `segmentMap` is the value that took over this job when parallel ranges
    /// put holes in the file — its own doc comment says so — and it is already
    /// persisted beside the record. It wins whenever it is present and belongs
    /// to a file of this size. The file's length remains the answer for
    /// single-connection downloads, which never preallocate and have no map.
    public static func reconcile(
        state: DownloadState, recordedBytes: Int64, expectedSize: Int64,
        finalSize: Int64?, partialSize: Int64?, segmentMap: SegmentMap? = nil
    ) -> Outcome {
        if expectedSize > 0, let finalSize, finalSize == expectedSize {
            return Outcome(state: .completed, bytesDownloaded: expectedSize)
        }
        // A map recorded against a different length describes other content;
        // the same rule `DownloadEngine.restore` applies before resuming from
        // one.
        let usable = segmentMap.flatMap {
            expectedSize > 0 && $0.matches(totalBytes: expectedSize) ? $0 : nil
        }
        return reconcile(
            state: state, recordedBytes: recordedBytes,
            partialExists: partialSize != nil, partialSize: partialSize ?? 0,
            mappedBytes: usable?.bytesComplete)
    }

    public static func reconcile(
        state: DownloadState, recordedBytes: Int64,
        partialExists: Bool, partialSize: Int64,
        mappedBytes: Int64? = nil
    ) -> Outcome {
        switch state {
        case .completed, .missing:
            // A completed record whose file is gone was moved or deleted —
            // `.missing`, not `.failed`. Nothing about the transfer failed, and
            // calling it a failure offered a Resume button that would quietly
            // re-download a file the user had deleted on purpose. A `.missing`
            // record whose file is back reverts to `.completed`: restoring it
            // from the Trash is exactly the undo the user expects to work.
            return partialExists
                ? Outcome(state: .completed, bytesDownloaded: recordedBytes)
                : Outcome(state: .missing, bytesDownloaded: recordedBytes)

        case .cancelled:
            return Outcome(state: .cancelled, bytesDownloaded: recordedBytes)

        case .downloading, .paused, .preparing, .failed, .queued:
            guard partialExists else {
                return Outcome(state: .queued, bytesDownloaded: 0)
            }
            // Never auto-resume without user intent.
            let next: DownloadState = (state == .downloading) ? .paused : state
            return Outcome(state: next, bytesDownloaded: mappedBytes ?? partialSize)
        }
    }
}
