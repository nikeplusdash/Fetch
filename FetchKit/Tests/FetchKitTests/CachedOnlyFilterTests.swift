import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

@Suite struct CachedOnlyFilterTests {
    private static let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    private static let hashB = "aa1155ecdc7ca55fb0bbf81323d87062db1f6d99"

    private static let indexer = SearchProviderID(rawValue: "jackett")

    private func torrent(_ hash: String) -> SearchResult {
        SearchResult(
            infoHashHex: hash,
            title: "Torrent \(hash.prefix(4))",
            size: 1000, seeders: 10, peers: 0, grabs: nil, fileCount: nil,
            category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [Self.indexer], rawAttributes: [:])
    }

    private func direct() -> SearchResult {
        SearchResult(
            candidates: [.direct(url: URL(string: "https://example.org/a.epub")!)],
            title: "A Book",
            size: 1_840_000, seeders: nil, peers: nil,
            category: nil, publishDate: nil,
            sources: [SearchProviderID(rawValue: "gutenberg")],
            rawAttributes: [:])
    }

    private let entry = CacheEntry(
        infoHashHex: Self.hashA, name: "Torrent", size: 1000, files: nil)

    @Test func aKnownMissIsDropped() {
        let results = CachedOnlyFilter.apply(
            [torrent(Self.hashA), torrent(Self.hashB)],
            states: [Self.hashA: .cached(entry), Self.hashB: .notCached],
            readiness: .ready)
        #expect(results.map(\.infoHashHex) == [Self.hashA])
    }

    @Test func aResultWithNoInfoHashIsKept() {
        let results = CachedOnlyFilter.apply(
            [direct()], states: [:], readiness: .ready)
        #expect(results.count == 1)
    }

    @Test func unresolvedChecksAreKept() {
        let results = CachedOnlyFilter.apply(
            [torrent(Self.hashA), torrent(Self.hashB)],
            states: [Self.hashA: .unchecked, Self.hashB: .checking],
            readiness: .ready)
        #expect(results.count == 2)
    }

    @Test func aFailedCheckIsKept() {
        let results = CachedOnlyFilter.apply(
            [torrent(Self.hashA)],
            states: [Self.hashA: .error("timed out")],
            readiness: .ready)
        #expect(results.count == 1)
    }

    @Test func nothingIsHiddenWhenCacheStatusIsUnknowable() {
        for readiness in [CacheReadiness.noCacheCapableProvider, .noDebridProvider] {
            let results = CachedOnlyFilter.apply(
                [torrent(Self.hashA), torrent(Self.hashB)],
                states: [Self.hashA: .notCached, Self.hashB: .notCached],
                readiness: readiness)
            #expect(results.count == 2, "\(readiness)")
        }
    }

    @Test func orderIsPreserved() {
        let input = [torrent(Self.hashB), direct(), torrent(Self.hashA)]
        let results = CachedOnlyFilter.apply(
            input,
            states: [Self.hashA: .cached(entry), Self.hashB: .cached(entry)],
            readiness: .ready)
        #expect(results.map(\.title) == input.map(\.title))
    }
}
