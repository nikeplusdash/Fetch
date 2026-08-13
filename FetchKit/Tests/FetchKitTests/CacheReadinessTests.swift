import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// The regression these cover: with no debrid provider configured, the app
/// silently skipped its cache check and then told the user every result was
/// "not cached — TorBox will prepare this first". Both statements were
/// fabrications of an unconfigured app, and neither mentioned the actual
/// problem. Routing is a pure decision, so it is decided here rather than
/// inside a SwiftUI view where nothing can test it.
@Suite struct CacheReadinessTests {
    private func entry(_ hash: String = "abc") -> CacheEntry {
        CacheEntry(infoHashHex: hash, name: "Some.Release", size: 1_000, files: nil)
    }

    // MARK: - Banner

    @Test func noDebridProviderExplainsItselfAndNamesSettings() {
        let text = CacheReadiness.noDebridProvider.searchBannerText
        #expect(text != nil)
        #expect(text?.localizedCaseInsensitiveContains("settings") == true)
    }

    @Test func aReadyProviderShowsNoBanner() {
        #expect(CacheReadiness.ready.searchBannerText == nil)
    }

    // MARK: - Result activation

    @Test func withNoProviderActivatingAResultAsksForConfiguration() {
        #expect(
            ResultActivation.route(readiness: .noDebridProvider, cacheState: nil)
            == .configureDebrid
        )
    }

    /// Cache states outlive the provider that produced them — saving a new
    /// API key rebuilds the store but `AppModel.cacheStates` is only reset,
    /// not repopulated. A leftover `.cached` must not offer a download that
    /// has no engine to run it.
    @Test func withNoProviderALeftoverCachedStateStillAsksForConfiguration() {
        #expect(
            ResultActivation.route(readiness: .noDebridProvider, cacheState: .cached(entry()))
            == .configureDebrid
        )
    }

    @Test func aCachedResultOpensThePreview() {
        #expect(
            ResultActivation.route(readiness: .ready, cacheState: .cached(entry()))
            == .previewCachedFiles
        )
    }

    @Test func aNotCachedResultOffersToPrepare() {
        #expect(
            ResultActivation.route(readiness: .ready, cacheState: .notCached)
            == .offerPrepare
        )
    }

    /// Deliberate: an unresolved badge is routed to Prepare, which costs one
    /// extra click if TorBox turns out to have it and never asserts anything
    /// untrue. The bug was doing this while *unconfigured*, where Prepare
    /// could only ever throw `notConfigured`.
    @Test func anUnresolvedBadgeOffersToPrepareRatherThanGuessing() {
        #expect(
            ResultActivation.route(readiness: .ready, cacheState: nil)
            == .offerPrepare
        )
        #expect(
            ResultActivation.route(readiness: .ready, cacheState: .checking)
            == .offerPrepare
        )
        #expect(
            ResultActivation.route(readiness: .ready, cacheState: .error("boom"))
            == .offerPrepare
        )
    }
}

/// What to do once a preview has actually been fetched.
///
/// A cached hit does not guarantee a usable file list: TorBox can report a
/// hash cached and return no files for it. That left an empty picker with a
/// disabled Download button — "nothing there to download" — for a magnet that
/// downloads perfectly well through Prepare.
@Suite struct EmptyPreviewTests {
    @Test func aPreviewWithFilesIsUsed() {
        #expect(ResultActivation.afterPreview(fileCount: 3) == .previewCachedFiles)
    }

    /// The fallback is Prepare, which submits the magnet and gets the debrid's
    /// authoritative list — the one path guaranteed to produce files.
    @Test func anEmptyPreviewFallsBackToPrepare() {
        #expect(ResultActivation.afterPreview(fileCount: 0) == .offerPrepare)
    }

    /// Not an error: nothing failed, the shortcut simply was not available.
    /// Showing an error would suggest the download cannot happen, which is
    /// exactly wrong.
    @Test func anEmptyPreviewIsNotAnError() {
        #expect(ResultActivation.afterPreview(fileCount: 0) != .configureDebrid)
    }
}

/// A Real-Debrid-only setup.
///
/// RD cannot report cache status, so readiness is `.noCacheCapableProvider` —
/// which is *not* the same as having no provider. Treating the two alike told
/// the user "No debrid provider configured" on every result while Real-Debrid
/// sat configured and working, and hid the one action that would have worked.
@Suite struct CacheIncapableRoutingTests {
    private func entry() -> CacheEntry {
        CacheEntry(infoHashHex: "aa", name: "x", size: 10, files: nil)
    }

    @Test func aProviderThatCannotReportCacheStillOffersToPrepare() {
        #expect(
            ResultActivation.route(readiness: .noCacheCapableProvider, cacheState: nil)
            == .offerPrepare
        )
    }

    /// Only a genuinely absent provider sends the user to Settings.
    @Test func onlyAnAbsentProviderAsksForConfiguration() {
        #expect(
            ResultActivation.route(readiness: .noDebridProvider, cacheState: nil)
            == .configureDebrid
        )
    }

    /// A leftover cache state cannot be trusted when nothing can verify it, so
    /// it must not open a preview — but it is still Prepare, not Settings.
    @Test func aStaleCachedStateWithNoCapableProviderStillPreparesRatherThanBlocks() {
        #expect(
            ResultActivation.route(readiness: .noCacheCapableProvider, cacheState: .cached(entry()))
            == .offerPrepare
        )
    }
}
