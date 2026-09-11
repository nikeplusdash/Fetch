import Foundation
import FetchPluginAPI

/**
 One row on the Downloads screen.

 Lives in FetchKit rather than beside the view model because `fraction` and
 `etaText` are arithmetic with edge cases — a zero total, a stalled rate —
 and the app target has no test bundle, so anything declared there cannot
 be tested at all.
 */
public struct DownloadItem: Identifiable, Sendable {
    public let id: DownloadID
    public var displayName: String
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var state: DownloadState
    public var finalURL: URL?

    public var addedAt: Date

    public var completedAt: Date?

    public var errorMessage: String?

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

    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return Double(bytesDownloaded) / Double(totalBytes)
    }

    public var etaText: String? {
        ByteCount.eta(remaining: totalBytes - bytesDownloaded, bytesPerSecond: bytesPerSecond)
    }
}

/**
 Drives the Search screen's top-level state (design spec §12.1's "States"
 list): no query yet, in flight, a loaded result set, an explicit empty
 result, no providers configured, or every configured provider failing.
 */
public enum SearchScreenState: Equatable, Sendable {
    case noQuery
    case searching
    case results
    case noResults
    case noProviders
    case noProvidersForArea
    case allFailed
}
