import Foundation
import FetchPluginAPI

/// Whether the app can answer "is this cached?" at all.
///
/// A debrid provider is what answers cache questions, so with none
/// configured the honest answer to every hash is "I don't know" — not
/// "not cached". Conflating those two is what made a missing API key
/// present itself as a broken cache badge: `runSearch` skipped its bulk
/// check without saying so, and the file picker read the resulting absence
/// as a definite miss and offered to prepare a torrent that no engine
/// existed to prepare.
public enum CacheReadiness: Sendable, Equatable {
    /// At least one configured provider can be asked.
    case ready
    /// No debrid provider is configured at all.
    case noDebridProvider
    /// Providers are configured, but none can answer cache questions — a
    /// Real-Debrid-only setup. Distinct from `noDebridProvider` because
    /// downloading works fine; only the badges are unknowable.
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

    /// Whether the results table should carry a cache column at all. A column
    /// of question marks reports nothing except that the column exists.
    public var showsCacheBadges: Bool { self == .ready }

    /// Text for the Search screen's non-blocking banner (§7's partial-
    /// failure sidecar), or `nil` when there is nothing to say. Results are
    /// still perfectly usable without a debrid provider — only the badges
    /// are meaningless — so this informs rather than blocks.
    public var searchBannerText: String? {
        switch self {
        case .ready:
            nil
        case .noDebridProvider:
            "No debrid provider configured — cache status is unavailable. "
            + "Add a TorBox API key in Settings to see what can be "
            + "downloaded instantly."
        case .noCacheCapableProvider:
            // Not the user's mistake, and not fixable by them — Real-Debrid
            // withdrew the endpoint. Say what is true and stop there.
            "Cache status unavailable — none of your debrid providers can "
            + "report what they have cached. Downloads still work; they just "
            + "may need preparing first."
        }
    }
}

/// What activating a search result should do.
///
/// Split out from `FilePickerSheet` so the decision is testable: it lives
/// in a SwiftUI view's `task`, and the app target has no test target.
public enum ResultActivation: Sendable, Equatable {
    /// Send the user to Settings — nothing downloadable can happen yet.
    case configureDebrid
    /// Known cached: load the side-effect-free preview file list (§6).
    case previewCachedFiles
    /// Not cached, or not yet known: offer to prepare it.
    case offerPrepare

    /// What to do once the preview call has returned.
    ///
    /// A cached hit does not guarantee a usable file list — a provider can
    /// report a hash cached and hand back no files. Falling through to Prepare
    /// submits the magnet and gets the debrid's authoritative list, which is
    /// the one path guaranteed to produce something. Reporting an error
    /// instead would suggest the download cannot happen, which is the opposite
    /// of true.
    public static func afterPreview(fileCount: Int) -> ResultActivation {
        fileCount > 0 ? .previewCachedFiles : .offerPrepare
    }

    /// `cacheState` is `nil` when the hash has never been checked.
    ///
    /// Anything short of a definitive `.cached` routes to Prepare. That
    /// costs one extra click when the debrid turns out to hold it already,
    /// and never claims something untrue — whereas the reverse error would
    /// open a preview for a torrent with no files behind it.
    public static func route(
        readiness: CacheReadiness, cacheState: CacheCheckState?
    ) -> ResultActivation {
        // Only a genuinely absent provider sends the user to Settings.
        //
        // `.noCacheCapableProvider` is a different thing entirely: Real-Debrid
        // is configured and can download perfectly well, it simply cannot say
        // what it has cached. Lumping the two together announced "No debrid
        // provider configured" on every result of a working RD setup, and hid
        // Prepare — the one action that would have worked.
        guard readiness != .noDebridProvider else { return .configureDebrid }

        // Checked before the cache state, not after: states outlive the
        // provider that produced them, so a leftover `.cached` from an earlier
        // session must not open a preview nothing can honour.
        guard readiness == .ready else { return .offerPrepare }

        return switch cacheState {
        case .cached: .previewCachedFiles
        default: .offerPrepare
        }
    }
}
