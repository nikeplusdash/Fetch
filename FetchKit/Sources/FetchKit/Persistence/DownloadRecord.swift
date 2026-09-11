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
    public var subfolder: String?
    public var originalFilename: String
    public var totalBytes: Int64
    public var bytesDownloaded: Int64
    public var stateRaw: String
    public var lastError: String?
    public var segmentMapJSON: String?
    public var torrentFileList: String?
    public var renamedPath: String?
    public var groupKeyRaw: String?
    public var groupName: String?
    public var finalPath: String?

    public var sourceJSON: String?
    public var metadataJSON: String?

    /**
     What to hand the service to get this back, for a cloud row only.

     A cloud row is a claim about someone else's server, and the server can
     change without telling Fetch. Both submits are idempotent, so the honest
     response to "the service no longer holds this" is to hand it back what
     created it and let it say what happened.

     The raw magnet for a torrent row, the original URL for a hosted one.
     Which it is, is already recoverable from `sourceJSON`, so this is one
     column and not two. `nil` on every row that is not a cloud row.
     */
    public var cloudReAddSource: String?
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
        queuePosition: Int = 0, createdAt: Date = Date(),
        cloudReAddSource: String? = nil
    ) {
        self.groupKeyRaw = groupKeyRaw
        self.groupName = groupName
        self.finalPath = finalPath
        self.sourceJSON = sourceJSON
        self.cloudReAddSource = cloudReAddSource
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

    public var allFiles: [TorrentMetadata.File] {
        get {
            (torrentFileList ?? "").split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\u{1F}")
                guard parts.count == 2, let length = Int64(parts[1]) else { return nil }
                return TorrentMetadata.File(path: String(parts[0]), length: length)
            }
        }
        set {
            torrentFileList = newValue.isEmpty ? nil : newValue
                .map { "\($0.path)\u{1F}\($0.length)" }
                .joined(separator: "\n")
        }
    }

    public var metadata: ReleaseMetadata {
        get {
            guard let metadataJSON, let data = metadataJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(ReleaseMetadata.self, from: data)
            else { return .unparsed }
            return decoded
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
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

/**
 Pure reconciliation logic, kept free of SwiftData so it is directly
 testable. The partial file on disk is the source of truth.
 */
public enum LaunchRecovery {
    public struct Outcome: Equatable, Sendable {
        public let state: DownloadState
        public let bytesDownloaded: Int64
    }

    /**
     Reconciles a record against what is actually on disk.

     **The final file wins over the record.** A complete file present at its
     expected size means the download is done, whatever state was persisted.
     A real install accumulated 26 records marked `cancelled` whose files
     were whole and present, because a restore bug marked finished downloads
     `failed` and cancelling them from that section was then possible. The
     bytes were never in doubt — only the bookkeeping.

     This heals stale records; it does not resurrect abandoned ones. A
     cancelled download with nothing on disk stays cancelled, and a
     short final file is not treated as finished.
     **The partial file's size is not the truth for a segmented download.**
     `SegmentedTransfer.preallocate` grows the `.fetchpart` to the file's
     full length *before the first request*, so a download that failed
     before a single byte arrived leaves a full-size file of zeros behind.
     Measuring it reported those rows at 100 % on the next launch — 80 of
     them in the install this was found on, every one of which had
     transferred nothing.

     Worse than a wrong number: at 100 % the single-connection path takes
     its `offset == expectedSize` shortcut, `verify` compares sizes and
     passes, and a file of zeros is renamed to its final name and called
     Completed.

     `segmentMap` is the value that took over this job when parallel ranges
     put holes in the file — its own doc comment says so — and it is already
     persisted beside the record. It wins whenever it is present and belongs
     to a file of this size. The file's length remains the answer for
     single-connection downloads, which never preallocate and have no map.

     A cloud row (`.cloudQueued` / `.onCloud`) is returned untouched: no disk
     value is consulted, so a coincidental `finalSize == expectedSize` can
     never flip it to `.completed`.
     */
    public static func reconcile(
        state: DownloadState, recordedBytes: Int64, expectedSize: Int64,
        finalSize: Int64?, partialSize: Int64?, segmentMap: SegmentMap? = nil
    ) -> Outcome {
        guard !state.isCloudOnly else {
            return reconcile(
                state: state, recordedBytes: recordedBytes,
                partialExists: false, partialSize: 0)
        }
        if expectedSize > 0, let finalSize, finalSize == expectedSize {
            return Outcome(state: .completed, bytesDownloaded: expectedSize)
        }
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
            return partialExists
                ? Outcome(state: .completed, bytesDownloaded: recordedBytes)
                : Outcome(state: .missing, bytesDownloaded: recordedBytes)

        case .cancelled:
            return Outcome(state: .cancelled, bytesDownloaded: recordedBytes)

        case .cloudQueued, .onCloud:
            return Outcome(state: state, bytesDownloaded: 0)

        case .downloading, .paused, .preparing, .failed, .queued:
            guard partialExists else {
                return Outcome(state: .queued, bytesDownloaded: 0)
            }
            let next: DownloadState = (state == .downloading) ? .paused : state
            return Outcome(state: next, bytesDownloaded: mappedBytes ?? partialSize)
        }
    }
}
