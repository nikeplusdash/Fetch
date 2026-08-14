import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// A minimal `DebridProvider` that exists only to carry an id and a cache
/// capability — routing and readiness are decisions about *which* provider,
/// never about what it returns.
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

    // MARK: - Capability

    /// TorBox and Premiumize can answer "is this cached?"; Real-Debrid cannot,
    /// because `/torrents/instantAvailability` returns `disabled_endpoint`.
    /// Defaulting to true keeps the flag opt-out, so a provider that can answer
    /// needs no boilerplate.
    @Test func aProviderReportsCacheStatusUnlessItSaysOtherwise() {
        #expect(StubDebrid("a").canReportCacheStatus)
        #expect(!StubDebrid("rd", canReportCacheStatus: false).canReportCacheStatus)
    }

    // MARK: - Readiness

    @Test func noProvidersAtAllIsStillNoDebridProvider() {
        #expect(CacheReadiness(providers: []) == .noDebridProvider)
    }

    /// The case that makes a single merged badge safe: a user with only
    /// Real-Debrid must not see every result marked "not cached", because
    /// nothing asked.
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

    /// Badges are meaningless when nothing can answer, so the column goes away
    /// rather than showing a row of question marks.
    @Test func theBadgeColumnIsShownOnlyWhenSomethingCanAnswer() {
        #expect(CacheReadiness.ready.showsCacheBadges)
        #expect(!CacheReadiness.noCacheCapableProvider.showsCacheBadges)
        #expect(!CacheReadiness.noDebridProvider.showsCacheBadges)
    }

    // MARK: - Routing

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

    /// Order is the caller's preference list, so the first cached one wins
    /// rather than an arbitrary member of the cached set.
    @Test func amongSeveralCachedProvidersThePreferredOneWins() {
        let chosen = DebridRouter.provider(
            for: hash,
            providers: [StubDebrid("a"), StubDebrid("b"), StubDebrid("c")],
            cachedOn: [hash: [
                DebridProviderID(rawValue: "c"), DebridProviderID(rawValue: "b"),
            ]])
        #expect(chosen?.id.rawValue == "b")
    }

    /// A provider that cannot report cache status is still perfectly able to
    /// download — excluding it from badges must not exclude it from routing.
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

    // MARK: - Merging cache answers

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

    /// One provider erroring must not turn a confirmed hit into an error —
    /// the answer is already known.
    @Test func anErrorAlongsideAHitStillReadsAsCached() {
        let merged = DebridRouter.mergeCacheStates([
            DebridProviderID(rawValue: "a"): .error("boom"),
            DebridProviderID(rawValue: "b"): .cached(
                CacheEntry(infoHashHex: hash, name: "x", size: 10, files: nil)),
        ])
        if case .cached = merged {} else { Issue.record("expected .cached, got \(merged)") }
    }

    /// With no hit, an error is the honest answer: "not cached" would assert
    /// something no provider actually confirmed.
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
