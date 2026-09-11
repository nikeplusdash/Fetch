import Foundation
import FetchPluginAPI

public enum DownloadState: String, Sendable, Codable, CaseIterable {
    case queued, preparing, downloading, paused, completed, failed, cancelled

    case missing

    /**
     The service has agreed to fetch this and has not finished.

     Its own state rather than a flavour of `.onCloud`, because one case
     cannot sit in two pills: a torrent still being fetched would otherwise
     land in the Library offering Play on bytes nobody has.
     */
    case cloudQueued

    /**
     Held by the debrid, and not on this Mac.

     A state rather than a separate list, because a file on the cloud is the
     same thing as a file on disk one stage earlier — same row, same group,
     same name. What differs is that nothing has been transferred and nothing
     is going to be until the user asks.
     */
    case onCloud

    /**
     True for a row whose bytes are somewhere else on purpose.

     Gates the disk probes, the never-transfer rule, and what Cancel means.
     */
    public var isCloudOnly: Bool {
        self == .cloudQueued || self == .onCloud
    }

    /**
     Whether the service actually holds the bytes yet.

     Not `isCloudOnly`: the service having accepted a torrent is not the
     service having it, and Play or Download on a `.cloudQueued` row would
     resolve a link against nothing.
     */
    public var isCloudReady: Bool { self == .onCloud }

    /**
     Whether the launch-time restore should hand this row to the engine.

     Both cloud states answer false, and that is the whole point. A row with
     no local bytes and no intention of having any would otherwise be
     "resumed" on every start, downloading the exact thing the user asked
     not to download.
     */
    public var transfersLocally: Bool {
        switch self {
        case .queued, .preparing, .downloading, .paused, .failed: true
        case .completed, .cancelled, .missing, .cloudQueued, .onCloud: false
        }
    }

    public var isTerminal: Bool {
        self == .completed || self == .cancelled || self == .missing
    }

    /**
     Whether anything about this row is changing from one second to the next.

     Only a moving row earns a second line. A queued row's position and a
     paused row's percentage are true but static — they sit there unchanged
     for minutes, and a line that never changes is one people stop reading
     while it doubles the height of the list.
     */
    public var isActive: Bool {
        self == .downloading || self == .preparing
    }

    /**
     Whether this download has stopped moving for good.

     Deliberately its own question rather than a borrowed one. It happens to
     name the same four states as `canBeRequeued` today, but that asks what
     the user may do next and this asks whether the row is still changing;
     one can move without the other, and a row that reads its answer off the
     wrong question is the sort of thing that only shows up as a stale line
     under a name.
     */
    public var isSettled: Bool {
        isTerminal || self == .failed
    }

    public var needsAttention: Bool {
        self == .failed || self == .cancelled || self == .missing
    }

    public var canBeRequeued: Bool {
        needsAttention || self == .completed
    }

    public var canBeStarted: Bool {
        self == .paused || self == .failed || self == .queued
    }

    public var isSelectableForAction: Bool {
        canBeStarted || canBeRequeued
    }
}

public struct DownloadRequest: Sendable {
    public let providerID: DebridProviderID
    public let torrentID: DebridTorrentID
    public let file: DebridFile
    public let infoHashHex: String
    public let subfolder: String?
    public let renamedPath: String?
    public let destinationRoot: URL

    public let directURL: URL?

    public let groupKey: DownloadGroupKey

    public let groupName: String?

    public let metadata: ReleaseMetadata

    public let source: DownloadSource

    /**
     The torrent-and-direct initialiser, unchanged in signature.

     Every existing call site builds requests this way; `source` is derived
     from the same two inputs it always was, so nothing moves. The hosted
     case uses the initialiser below, which states its source outright.
     */
    public init(
        providerID: DebridProviderID, torrentID: DebridTorrentID,
        file: DebridFile, infoHashHex: String,
        subfolder: String?, destinationRoot: URL,
        renamedPath: String? = nil,
        directURL: URL? = nil,
        groupKey: DownloadGroupKey? = nil,
        groupName: String? = nil,
        metadata: ReleaseMetadata = .unparsed
    ) {
        self.directURL = directURL
        self.source = if let directURL {
            .directHTTP(url: directURL)
        } else {
            .debridTorrent(provider: providerID, torrent: torrentID, file: file.id)
        }
        self.groupKey = groupKey ?? .unattempted(infoHashHex)
        self.groupName = groupName
        self.metadata = metadata
        self.providerID = providerID
        self.torrentID = torrentID
        self.file = file
        self.infoHashHex = infoHashHex
        self.subfolder = subfolder
        self.renamedPath = renamedPath
        self.destinationRoot = destinationRoot
    }

    /**
     A request that names its own source (7e §4.1).

     `providerID` and `torrentID` are filled from the source so the fields
     stay non-optional for every existing reader; for a hosted download the
     torrent id is the web-download id, which is the closest true thing —
     and `source` is what any new reader should consult.
     `infoHashHex` is carried separately because it is a separate fact: a
     torrent's content identity, used for cache lookups and as the grouping
     fallback, not something the source encodes. Restoring a torrent
     through this initialiser without it silently emptied the hash —
     `DownloadStoreTests.everythingNeededToResumeRoundTrips` caught it.
     */
    public init(
        source: DownloadSource,
        file: DebridFile,
        infoHashHex: String = "",
        subfolder: String?,
        destinationRoot: URL,
        renamedPath: String? = nil,
        groupKey: DownloadGroupKey,
        groupName: String? = nil,
        metadata: ReleaseMetadata = .unparsed
    ) {
        self.source = source
        self.groupKey = groupKey
        self.groupName = groupName
        self.metadata = metadata
        self.file = file
        self.subfolder = subfolder
        self.renamedPath = renamedPath
        self.destinationRoot = destinationRoot

        self.infoHashHex = infoHashHex

        switch source {
        case .debridTorrent(let provider, let torrent, _):
            self.providerID = provider
            self.torrentID = torrent
            self.directURL = nil
        case .debridHosted(let provider, let download):
            self.providerID = provider
            self.torrentID = DebridTorrentID(rawValue: download.rawValue)
            self.directURL = nil
        case .directHTTP(let url):
            self.providerID = DebridProviderID(rawValue: "direct")
            self.torrentID = DebridTorrentID(rawValue: "direct")
            self.directURL = url
        }
    }
}

/**
 Result of a selective enqueue (`DownloadEngine.enqueueMagnet(...selecting:)`
 / `.enqueueSelected`) — the paths a caller asked for that had no match in
 the authoritative file list are reported here rather than silently
 dropped (§6, "Two kinds of file list").
 */
public struct SelectiveEnqueueResult: Sendable, Equatable {
    public let downloadIDs: [DownloadID]
    public let missingPaths: [String]

    public init(downloadIDs: [DownloadID], missingPaths: [String]) {
        self.downloadIDs = downloadIDs
        self.missingPaths = missingPaths
    }
}

/**
 The authoritative torrent state a magnet resolves to once TorBox (or
 another debrid) has it ready — returned by `DownloadEngine.prepareMagnet`
 so a caller can show a file picker against real file IDs *before*
 deciding what to enqueue.
 */
public struct PreparedMagnet: Sendable, Equatable {
    public let torrentID: DebridTorrentID
    public let infoHashHex: String
    public let files: [DebridFile]

    public init(torrentID: DebridTorrentID, infoHashHex: String, files: [DebridFile]) {
        self.torrentID = torrentID
        self.infoHashHex = infoHashHex
        self.files = files
    }
}

/**
 A magnet the debrid is still fetching into its own cloud.

 Distinct from a `DownloadID`, and deliberately so: nothing is being
 transferred to this machine yet. What it identifies is a poll against the
 user's account.
 */
public struct PreparationID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

/**
 What the debrid says about a torrent it is still fetching.

 The debrid's numbers, not Fetch's: `fraction` is how much of the torrent
 *the service* holds, and `bytesPerSecond` is how fast it is pulling from
 the swarm. None of it is a local transfer, and the row says so.
 */
public struct PreparationProgress: Sendable, Equatable {
    public let fraction: Double
    public let seeds: Int?
    public let bytesPerSecond: Int64?
    public let eta: TimeInterval?
    public let state: DebridTorrentState

    public init(
        fraction: Double, seeds: Int?, bytesPerSecond: Int64?,
        eta: TimeInterval?, state: DebridTorrentState
    ) {
        self.fraction = fraction
        self.seeds = seeds
        self.bytesPerSecond = bytesPerSecond
        self.eta = eta
        self.state = state
    }

    public var statusText: String {
        switch state {
        case .queued: "Queued at your debrid"
        case .checking: "Checking"
        case .downloading: "Downloading to your debrid"
        case .uploading: "Finishing up"
        case .stalled: "Stalled, waiting for seeds"
        case .completed: "Ready"
        case .failed(let reason): "Failed: \(reason)"
        case .unknown(let raw): raw
        }
    }
}

public enum DownloadEvent: Sendable {
    case enqueued(DownloadID, filename: String, totalBytes: Int64)
    case stateChanged(DownloadID, DownloadState)
    case progress(DownloadID, bytesDownloaded: Int64, totalBytes: Int64, bytesPerSecond: Double)
    case finished(DownloadID, at: URL)
    case failed(DownloadID, DownloadError)
    case removed(DownloadID)


    case preparationStarted(PreparationID, name: String, groupKey: DownloadGroupKey)
    case preparationProgress(PreparationID, PreparationProgress)
    case preparationFinished(PreparationID)
    case preparationFailed(PreparationID, DownloadError)
    case preparationCancelled(PreparationID)
}
