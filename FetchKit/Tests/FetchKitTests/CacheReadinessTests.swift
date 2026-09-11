import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct CacheReadinessTests {
    private func entry(_ hash: String = "abc") -> CacheEntry {
        CacheEntry(infoHashHex: hash, name: "Some.Release", size: 1_000, files: nil)
    }


    @Test func noDebridProviderExplainsItselfAndOffersTheWayOut() {
        let readiness = CacheReadiness.noDebridProvider
        #expect(readiness.searchBannerText != nil)
        #expect(readiness.searchBannerActionTitle == "Settings")
    }

    @Test func anUncapableProviderIsStatedWithNoActionToTake() {
        let readiness = CacheReadiness.noCacheCapableProvider
        #expect(readiness.searchBannerText != nil)
        #expect(readiness.searchBannerActionTitle == nil)
    }

    @Test func aReadyProviderShowsNoBanner() {
        #expect(CacheReadiness.ready.searchBannerText == nil)
    }


    @Test func withNoProviderActivatingAResultAsksForConfiguration() {
        #expect(
            ResultActivation.route(readiness: .noDebridProvider, cacheState: nil)
            == .configureDebrid
        )
    }

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

@Suite struct EmptyPreviewTests {
    @Test func aPreviewWithFilesIsUsed() {
        #expect(ResultActivation.afterPreview(fileCount: 3) == .previewCachedFiles)
    }

    @Test func anEmptyPreviewFallsBackToPrepare() {
        #expect(ResultActivation.afterPreview(fileCount: 0) == .offerPrepare)
    }

    @Test func anEmptyPreviewIsNotAnError() {
        #expect(ResultActivation.afterPreview(fileCount: 0) != .configureDebrid)
    }
}

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

    @Test func onlyAnAbsentProviderAsksForConfiguration() {
        #expect(
            ResultActivation.route(readiness: .noDebridProvider, cacheState: nil)
            == .configureDebrid
        )
    }

    @Test func aStaleCachedStateWithNoCapableProviderStillPreparesRatherThanBlocks() {
        #expect(
            ResultActivation.route(readiness: .noCacheCapableProvider, cacheState: .cached(entry()))
            == .offerPrepare
        )
    }
}
