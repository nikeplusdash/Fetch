import Foundation
import FetchPluginAPI

/// One row on the Downloads screen.
///
/// Lives in FetchKit rather than beside the view model because `fraction` and
/// `etaText` are arithmetic with edge cases — a zero total, a stalled rate —
/// and the app target has no test bundle, so anything declared there cannot
/// be tested at all.
public struct DownloadItem: Identifiable, Sendable {
    public let id: DownloadID
    public var displayName: String
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var state: DownloadState
    public var finalURL: URL?

    /// When this download was added, which is what the list is sorted by and
    /// what the Added column says.
    ///
    /// **It is the sort key, so it is on the screen.** The list claims to be
    /// newest first; with no date on it, that claim is unfalsifiable. Carried
    /// on the item rather than derived from the row's files, because a row's
    /// files arrive over several seconds and the row must not re-sort itself
    /// while they do.
    ///
    /// Defaults to now, which is right for a download being queued this
    /// second. `DownloadRecord.createdAt` is what a restored one gets, and
    /// without it every download in the store would claim it was added at
    /// launch.
    public var addedAt: Date

    /// When this download finished, for the library's ordering.
    ///
    /// Nil while it is still running, and nil for a row saved before the
    /// store recorded it — those sort last rather than as the epoch, which
    /// would put the oldest downloads Fetch has ever seen at the top of a
    /// newest-first shelf.
    public var completedAt: Date?

    /// Why this download failed, in a sentence. Nil for every other state.
    ///
    /// The row used to show `DownloadState.failed` and nothing else, and the
    /// window's banner showed `error.localizedDescription` — which for a bare
    /// Swift error is a domain and a number. "FetchKit.DownloadError error 6"
    /// is what the user was actually given, and it does not even decode the
    /// way a reader would count. `DownloadError` is `LocalizedError` now; this
    /// is where its sentence lands, and `DownloadRecord.lastError` is where it
    /// survives a relaunch.
    public var errorMessage: String?

    /// Chosen once, from `totalBytes`, when the row is created — see
    /// `ByteCount.pinnedUnit(for:)`. Reused for every progress tick so the
    /// transferred/total string's length (and therefore the row's layout)
    /// never changes mid-download, which `format(_:)` alone cannot
    /// guarantee since it recomputes the "best" unit per value.
    public var pinnedUnit: ByteCountFormatter.Units

    public init(
        id: DownloadID,
        displayName: String,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double = 0,
        state: DownloadState,
        finalURL: URL? = nil,
        errorMessage: String? = nil,
        addedAt: Date = Date(),
        completedAt: Date? = nil,
        pinnedUnit: ByteCountFormatter.Units
    ) {
        self.addedAt = addedAt
        self.id = id
        self.displayName = displayName
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.state = state
        self.finalURL = finalURL
        self.errorMessage = errorMessage
        self.completedAt = completedAt
        self.pinnedUnit = pinnedUnit
    }

    /// `nil` when the total is unknown, which is *not* the same as 0%: a
    /// determinate bar at zero claims the size is known and nothing has
    /// arrived. The Downloads row shows an indeterminate track instead.
    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return Double(bytesDownloaded) / Double(totalBytes)
    }

    public var etaText: String? {
        ByteCount.eta(remaining: totalBytes - bytesDownloaded, bytesPerSecond: bytesPerSecond)
    }
}

/// Drives the Search screen's top-level state (design spec §12.1's "States"
/// list): no query yet, in flight, a loaded result set, an explicit empty
/// result, no providers configured, or every configured provider failing.
public enum SearchScreenState: Equatable, Sendable {
    case noQuery
    case searching
    case results
    case noResults
    case noProviders
    /// There are indexers, but every one of them has been reserved for other
    /// areas. Distinct from `noProviders` because "add a Torznab endpoint" is
    /// the wrong advice for a user who has several and scoped them all away
    /// from this pill.
    case noProvidersForArea
    case allFailed
}
