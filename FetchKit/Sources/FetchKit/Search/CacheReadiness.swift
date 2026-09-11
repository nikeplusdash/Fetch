import Foundation
import FetchPluginAPI

/**
 Whether the app can answer "is this cached?" at all.

 A debrid provider is what answers cache questions, so with none
 configured the honest answer to every hash is "I don't know" — not
 "not cached". Conflating those two is what made a missing API key
 present itself as a broken cache badge: `runSearch` skipped its bulk
 check without saying so, and the file picker read the resulting absence
 as a definite miss and offered to prepare a torrent that no engine
 existed to prepare.
 */
public enum CacheReadiness: Sendable, Equatable {
    case ready
    case noDebridProvider
    case noCacheCapableProvider

    public init(isConfigured: Bool) {
        self = isConfigured ? .ready : .noDebridProvider
    }

    public init(providers: [any DebridProvider]) {
        if providers.isEmpty {
            self = .noDebridProvider
        } else if providers.contains(where: \.canReportCacheStatus) {
            self = .ready
        } else {
            self = .noCacheCapableProvider
        }
    }

    public var showsCacheBadges: Bool { self == .ready }

    public var searchBannerText: String? {
        switch self {
        case .ready:
            nil
        case .noDebridProvider:
            "Results cannot show what is already cached without a debrid service."
        case .noCacheCapableProvider:
            "None of your services can report what they have cached."
        }
    }

    public var searchBannerActionTitle: String? {
        switch self {
        case .ready, .noCacheCapableProvider: nil
        case .noDebridProvider: "Settings"
        }
    }
}

/**
 What activating a search result should do.

 Split out from `FilePickerSheet` so the decision is testable: it lives
 in a SwiftUI view's `task`, and the app target has no test target.
 */
public enum ResultActivation: Sendable, Equatable {
    case configureDebrid
    case previewCachedFiles
    case offerPrepare

    /**
     What to do once the preview call has returned.

     A cached hit does not guarantee a usable file list — a provider can
     report a hash cached and hand back no files. Falling through to Prepare
     submits the magnet and gets the debrid's authoritative list, which is
     the one path guaranteed to produce something. Reporting an error
     instead would suggest the download cannot happen, which is the opposite
     of true.
     */
    public static func afterPreview(fileCount: Int) -> ResultActivation {
        fileCount > 0 ? .previewCachedFiles : .offerPrepare
    }

    /**
     `cacheState` is `nil` when the hash has never been checked.

     Anything short of a definitive `.cached` routes to Prepare. That
     costs one extra click when the debrid turns out to hold it already,
     and never claims something untrue — whereas the reverse error would
     open a preview for a torrent with no files behind it.
     */
    public static func route(
        readiness: CacheReadiness, cacheState: CacheCheckState?
    ) -> ResultActivation {
        guard readiness != .noDebridProvider else { return .configureDebrid }

        guard readiness == .ready else { return .offerPrepare }

        return switch cacheState {
        case .cached: .previewCachedFiles
        default: .offerPrepare
        }
    }
}
