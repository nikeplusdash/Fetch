import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

private struct StubDebrid: DebridProvider {
    let id: DebridProviderID
    let displayName: String
    let canReportCacheStatus: Bool

    init(_ id: String, canReportCacheStatus: Bool = true) {
        self.id = DebridProviderID(rawValue: id)
        self.displayName = id
        self.canReportCacheStatus = canReportCacheStatus
    }

    func validateCredentials() async throws -> DebridAccount {
        DebridAccount(email: nil, plan: nil, expiresAt: nil)
    }
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        DebridTorrentID(rawValue: "0")
    }
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        DebridTorrent(
            id: id, infoHashHex: "", name: "", size: 0, progress: 0,
            state: .unknown("n/a"), files: [], seeds: nil, downloadSpeed: nil, eta: nil)
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        URL(string: "https://example.com")!
    }
    func delete(torrent: DebridTorrentID) async throws {}
}

@Suite struct DebridRoutingTests {


    @Test func aProviderReportsCacheStatusUnlessItSaysOtherwise() {
        #expect(StubDebrid("a").canReportCacheStatus)
        #expect(!StubDebrid("rd", canReportCacheStatus: false).canReportCacheStatus)
    }


    @Test func noProvidersAtAllIsStillNoDebridProvider() {
        #expect(CacheReadiness(providers: []) == .noDebridProvider)
    }

    @Test func providersThatCannotAnswerYieldNoCacheCapableProvider() {
        let readiness = CacheReadiness(providers: [
            StubDebrid("rd", canReportCacheStatus: false)
        ])
        #expect(readiness == .noCacheCapableProvider)
    }

    @Test func oneCapableProviderAmongIncapableOnesIsReady() {
        let readiness = CacheReadiness(providers: [
            StubDebrid("rd", canReportCacheStatus: false),
            StubDebrid("premiumize"),
        ])
        #expect(readiness == .ready)
    }

    @Test func noCacheCapableProviderExplainsItselfWithoutBlamingTheUser() {
        let text = CacheReadiness.noCacheCapableProvider.searchBannerText
        #expect(text != nil)
        #expect(text?.localizedCaseInsensitiveContains("cache") == true)
    }

    @Test func theBadgeColumnIsShownOnlyWhenSomethingCanAnswer() {
        #expect(CacheReadiness.ready.showsCacheBadges)
        #expect(!CacheReadiness.noCacheCapableProvider.showsCacheBadges)
        #expect(!CacheReadiness.noDebridProvider.showsCacheBadges)
    }


    private let hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    @Test func aCachedProviderWinsOverALowerOrderedUncachedOne() {
        let chosen = DebridRouter.provider(
            for: hash,
            providers: [StubDebrid("first"), StubDebrid("second")],
            cachedOn: [hash: [DebridProviderID(rawValue: "second")]])
        #expect(chosen?.id.rawValue == "second")
    }

    @Test func withNothingCachedTheHighestPreferenceProviderIsUsed() {
        let chosen = DebridRouter.provider(
            for: hash,
            providers: [StubDebrid("first"), StubDebrid("second")],
            cachedOn: [:])
        #expect(chosen?.id.rawValue == "first")
    }

    @Test func amongSeveralCachedProvidersThePreferredOneWins() {
        let chosen = DebridRouter.provider(
            for: hash,
            providers: [StubDebrid("a"), StubDebrid("b"), StubDebrid("c")],
            cachedOn: [hash: [
                DebridProviderID(rawValue: "c"), DebridProviderID(rawValue: "b"),
            ]])
        #expect(chosen?.id.rawValue == "b")
    }

    @Test func aProviderThatCannotReportCacheStatusCanStillBeRoutedTo() {
        let chosen = DebridRouter.provider(
            for: hash,
            providers: [StubDebrid("rd", canReportCacheStatus: false)],
            cachedOn: [:])
        #expect(chosen?.id.rawValue == "rd")
    }

    @Test func noProvidersRoutesNowhere() {
        #expect(DebridRouter.provider(for: hash, providers: [], cachedOn: [:]) == nil)
    }


    @Test func cachedOnAnyProviderReadsAsCached() {
        let merged = DebridRouter.mergeCacheStates([
            DebridProviderID(rawValue: "a"): .notCached,
            DebridProviderID(rawValue: "b"): .cached(
                CacheEntry(infoHashHex: hash, name: "x", size: 10, files: nil)),
        ])
        if case .cached = merged {} else { Issue.record("expected .cached, got \(merged)") }
    }

    @Test func notCachedAnywhereReadsAsNotCached() {
        let merged = DebridRouter.mergeCacheStates([
            DebridProviderID(rawValue: "a"): .notCached,
            DebridProviderID(rawValue: "b"): .notCached,
        ])
        #expect(merged == .notCached)
    }

    @Test func anErrorAlongsideAHitStillReadsAsCached() {
        let merged = DebridRouter.mergeCacheStates([
            DebridProviderID(rawValue: "a"): .error("boom"),
            DebridProviderID(rawValue: "b"): .cached(
                CacheEntry(infoHashHex: hash, name: "x", size: 10, files: nil)),
        ])
        if case .cached = merged {} else { Issue.record("expected .cached, got \(merged)") }
    }

    @Test func anErrorWithNoHitDoesNotBecomeNotCached() {
        let merged = DebridRouter.mergeCacheStates([
            DebridProviderID(rawValue: "a"): .error("boom"),
            DebridProviderID(rawValue: "b"): .notCached,
        ])
        if case .error = merged {} else { Issue.record("expected .error, got \(merged)") }
    }

    @Test func nothingReportedIsUnchecked() {
        #expect(DebridRouter.mergeCacheStates([:]) == .unchecked)
    }
}
