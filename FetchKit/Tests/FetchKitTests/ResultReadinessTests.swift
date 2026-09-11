import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct ResultReadinessTests {
    private let hash = String(repeating: "a", count: 40)

    private func torrent() -> SearchResult {
        SearchResult(
            infoHashHex: hash, title: "T", size: 1, seeders: 1, peers: 0, grabs: nil,
            fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [SearchProviderID(rawValue: "x")], rawAttributes: [:])
    }

    private func directResult() -> SearchResult {
        SearchResult(
            candidates: [.direct(url: URL(string: "https://archive.org/download/x/y.mp4")!)],
            title: "An item", size: 10, seeders: nil, peers: nil, category: nil,
            publishDate: nil, sources: [SearchProviderID(rawValue: "ia")],
            sourceKey: "internet-archive:x", rawAttributes: [:])
    }

    private var cached: [String: CacheCheckState] {
        [hash: .cached(CacheEntry(infoHashHex: hash, name: "", size: 0, files: nil))]
    }

    @Test func aFileWithNoTorrentIsDirect() {
        #expect(ResultReadiness.of(directResult(), cacheStates: [:]) == .direct)
    }

    @Test func aCachedTorrentIsAlsoDirect() {
        #expect(ResultReadiness.of(torrent(), cacheStates: cached) == .direct)
    }

    @Test func aPublicFileAndACachedTorrentRankTheSame() {
        #expect(ResultReadiness.of(directResult(), cacheStates: [:]).rank
                == ResultReadiness.of(torrent(), cacheStates: cached).rank)
    }

    @Test func anUncachedTorrentNeedsFetching() {
        #expect(ResultReadiness.of(torrent(), cacheStates: [hash: .notCached]) == .needsFetching)
    }

    @Test func anInFlightCheckSaysSo() {
        #expect(ResultReadiness.of(torrent(), cacheStates: [hash: .checking]) == .checking)
    }

    @Test func anUncheckedOrFailedLookupIsUnknownNotUnavailable() {
        #expect(ResultReadiness.of(torrent(), cacheStates: [:]) == .unknown)
        #expect(ResultReadiness.of(torrent(), cacheStates: [hash: .error("boom")]) == .unknown)
        #expect(ResultReadiness.unknown.rank > ResultReadiness.needsFetching.rank)
    }

    @Test func directOutranksEverything() {
        #expect(ResultReadiness.direct.rank > ResultReadiness.checking.rank)
        #expect(ResultReadiness.direct.rank > ResultReadiness.unknown.rank)
        #expect(ResultReadiness.direct.rank > ResultReadiness.needsFetching.rank)
    }
}
