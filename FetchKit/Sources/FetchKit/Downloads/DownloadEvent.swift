import Foundation
import FetchPluginAPI

public enum DownloadState: String, Sendable, Codable, CaseIterable {
    case queued, preparing, downloading, paused, completed, failed, cancelled

    /// The download finished, and the file is no longer where Fetch put it.
    ///
    /// Distinct from `.failed`, which it used to be folded into: nothing about
    /// the transfer failed, so calling it a failure both misdescribes it and
    /// offers a Resume button (`.failed` is resumable) that would silently
    /// re-download gigabytes the user may have deleted on purpose.
    case missing

    /// Settled for good — nothing here is waiting, running, or resumable.
    ///
    /// `.failed` is deliberately absent: a failed download can be resumed, so
    /// it is still live work. `.missing` is present because re-downloading a
    /// deleted file is a new decision, not a continuation.
    public var isTerminal: Bool {
        self == .completed || self == .cancelled || self == .missing
    }

    /// Settled *without* the file being there to use — what the Downloads
    /// screen's Failed filter collects, and what "Clear" clears.
    public var needsAttention: Bool {
        self == .failed || self == .cancelled || self == .missing
    }

    /// Whether downloading this file again is a thing the user can ask for.
    ///
    /// Everything settled: the three that need attention, plus `.completed` —
    /// a finished file may be corrupt, or deleted and wanted back, and
    /// refusing to re-fetch it would be Fetch deciding it knows better.
    ///
    /// Live work is excluded, and that is the whole point of the property.
    /// Offering "download this" beside a file that is queued or already
    /// transferring is how someone ends up with two copies and a row that sums
    /// both — the same arithmetic that `DownloadGroupKey`'s attempt exists to
    /// keep apart.
    public var canBeRequeued: Bool {
        needsAttention || self == .completed
    }

    /// Whether `DownloadEngine.resume` will act on this — the file is not
    /// running, and starting it is a thing the user can ask for.
    ///
    /// `.queued` is here because a restored download comes back queued
    /// *without* being in the engine's queue, and for a long time nothing
    /// could start it: this predicate's ancestor rejected `.queued`, and the
    /// row's Resume button follows the same rule, so those downloads had no
    /// button, no menu item and no code path at all.
    public var canBeStarted: Bool {
        self == .paused || self == .failed || self == .queued
    }

    /// Whether a checkbox may appear beside this file in an expanded torrent.
    ///
    /// Everything except work actually in flight. What the tick *means* then
    /// depends on the state — start it, or fetch it again — which is the
    /// row's business, not this one's.
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
    /// Where to write this file, relative to `subfolder`, when a naming
    /// strategy renamed it. Nil means use `file.name` unchanged.
    ///
    /// Kept separate from `file.name` rather than replacing it: `file.name` is
    /// the debrid's own path and the key every selection is re-resolved
    /// against (§6). Rewriting it would break that matching.
    public let renamedPath: String?
    public let destinationRoot: URL

    /// A public HTTPS URL to fetch directly, bypassing the debrid entirely
    /// (amendment §2). Nil for every torrent download, which is every download
    /// that existed before stage 7b.
    ///
    /// Additive rather than a replacement of the debrid triple: §6's rule is
    /// that no CDN URL is ever persisted, and that still holds — a debrid link
    /// is credentialed and expires, so it is re-resolved. A direct URL is a
    /// public address, so it *is* the identity and persisting it is correct.
    public let directURL: URL?

    /// Which row this download belongs under in the Downloads list.
    ///
    /// Defaults to `infoHashHex`, so every torrent groups exactly as before.
    /// A direct download has no infohash, and keying on "" put every
    /// Archive.org file from every item into one nameless row. Kept as its own
    /// field rather than borrowing `infoHashHex`, because that value is also a
    /// cache-lookup key and stuffing an item identifier into it is the kind of
    /// type abuse that works until something looks it up.
    ///
    /// Carries the queueing attempt as well as the content, so a second go at
    /// the same torrent is a second row rather than more files in the first —
    /// see `DownloadGroupKey`.
    public let groupKey: DownloadGroupKey

    /// What this row is called, decided when it was queued.
    ///
    /// `DownloadGrouping.displayName` reconstructs a name from the folder its
    /// files share, which works for a torrent and fails for anything whose
    /// files share no folder — a Gutenberg book taken in two formats read
    /// "2 files" rather than its title. The name is known at enqueue time by
    /// every caller; guessing it afterwards was the mistake.
    ///
    /// Optional so records written before it existed fall back to the
    /// derivation, exactly as they were named when they were saved.
    public let groupName: String?

    /// The release metadata this download was filed under.
    ///
    /// Carried on the request so it reaches the store. `enqueueDirect` used to
    /// accept a `metadata:` parameter and drop it, so every Internet Archive
    /// and Gutenberg download persisted none — which files every book under
    /// Other in a library grouped by media kind.
    public let metadata: ReleaseMetadata

    /// What this download actually points at.
    ///
    /// **Stored, not derived.** It used to be a ternary over
    /// `directURL != nil`: two branches, no third slot, and anything that was
    /// neither direct nor a torrent reported itself as a torrent. `.hosted`
    /// could not be bolted onto it, so the enum that already models all three
    /// cases became the field instead of being reconstructed from a proxy.
    public let source: DownloadSource

    /// The torrent-and-direct initialiser, unchanged in signature.
    ///
    /// Every existing call site builds requests this way; `source` is derived
    /// from the same two inputs it always was, so nothing moves. The hosted
    /// case uses the initialiser below, which states its source outright.
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
        // Defaults to the content alone with no attempt, so a caller that
        // builds requests one at a time (a restore rebuilding a persisted row)
        // cannot accidentally split one row into many. Batch call sites mint
        // one attempt and pass it to every file.
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

    /// A request that names its own source (7e §4.1).
    ///
    /// `providerID` and `torrentID` are filled from the source so the fields
    /// stay non-optional for every existing reader; for a hosted download the
    /// torrent id is the web-download id, which is the closest true thing —
    /// and `source` is what any new reader should consult.
    /// `infoHashHex` is carried separately because it is a separate fact: a
    /// torrent's content identity, used for cache lookups and as the grouping
    /// fallback, not something the source encodes. Restoring a torrent
    /// through this initialiser without it silently emptied the hash —
    /// `DownloadStoreTests.everythingNeededToResumeRoundTrips` caught it.
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
            // The closest true thing for a field that has to be non-optional
            // for every existing reader. New readers consult `source`.
            self.torrentID = DebridTorrentID(rawValue: download.rawValue)
            self.directURL = nil
        case .directHTTP(let url):
            self.providerID = DebridProviderID(rawValue: "direct")
            self.torrentID = DebridTorrentID(rawValue: "direct")
            self.directURL = url
        }
    }
}

/// Result of a selective enqueue (`DownloadEngine.enqueueMagnet(...selecting:)`
/// / `.enqueueSelected`) — the paths a caller asked for that had no match in
/// the authoritative file list are reported here rather than silently
/// dropped (§6, "Two kinds of file list").
public struct SelectiveEnqueueResult: Sendable, Equatable {
    public let downloadIDs: [DownloadID]
    public let missingPaths: [String]

    public init(downloadIDs: [DownloadID], missingPaths: [String]) {
        self.downloadIDs = downloadIDs
        self.missingPaths = missingPaths
    }
}

/// The authoritative torrent state a magnet resolves to once TorBox (or
/// another debrid) has it ready — returned by `DownloadEngine.prepareMagnet`
/// so a caller can show a file picker against real file IDs *before*
/// deciding what to enqueue.
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

/// A magnet the debrid is still fetching into its own cloud.
///
/// Distinct from a `DownloadID`, and deliberately so: nothing is being
/// transferred to this machine yet. What it identifies is a poll against the
/// user's account.
public struct PreparationID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

/// What the debrid says about a torrent it is still fetching.
///
/// The debrid's numbers, not Fetch's: `fraction` is how much of the torrent
/// *the service* holds, and `bytesPerSecond` is how fast it is pulling from
/// the swarm. None of it is a local transfer, and the row says so.
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

    /// What the row says while the debrid works. Read off the state rather
    /// than invented, so "stalled, no seeds" reaches the user instead of a
    /// spinner that looks identical to healthy progress.
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
    /// `filename` is `DebridFile.shortName` — the last path component, not
    /// the full in-torrent path — and `totalBytes` is `DebridFile.size`.
    /// Carrying both here (rather than a bare `DownloadID`) is what lets a
    /// UI label a row the instant it appears instead of showing a
    /// placeholder until the first `.progress` event arrives; it also means
    /// a multi-file torrent's rows are distinguishable immediately, since
    /// each one enqueues its own file.
    case enqueued(DownloadID, filename: String, totalBytes: Int64)
    case stateChanged(DownloadID, DownloadState)
    case progress(DownloadID, bytesDownloaded: Int64, totalBytes: Int64, bytesPerSecond: Double)
    case finished(DownloadID, at: URL)
    case failed(DownloadID, DownloadError)
    case removed(DownloadID)

    // MARK: - Remote preparation
    //
    // An uncached magnet used to be an `await` the *sheet* was holding: submit,
    // then poll until the debrid had fetched the whole torrent, then return.
    // That is minutes to hours with a spinner on screen and nothing in
    // Downloads, for work that was committed to the user's account the moment
    // the magnet went up. These four events are that wait, moved to where the
    // user can watch it and leave.

    /// The magnet is on the account and the poll has started. `groupKey` is
    /// the row the resulting downloads will land under — announced here so the
    /// preparing row and the file rows are visibly the same row.
    case preparationStarted(PreparationID, name: String, groupKey: DownloadGroupKey)
    case preparationProgress(PreparationID, PreparationProgress)
    /// The debrid has it; `.enqueued` events for its files follow immediately.
    case preparationFinished(PreparationID)
    case preparationFailed(PreparationID, DownloadError)
    /// Withdrawn by the user. Distinct from `.preparationFailed` so a cancel
    /// does not present itself as something going wrong.
    case preparationCancelled(PreparationID)
}
