import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

/// "Cached only" — what survives, and the three things it must never hide.
@Suite struct CachedOnlyFilterTests {
    private static let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    private static let hashB = "aa1155ecdc7ca55fb0bbf81323d87062db1f6d99"

    private static let indexer = SearchProviderID(rawValue: "jackett")

    /// The torrent initialiser, spelled as every other suite in this repo
    /// spells it — a malformed hash or magnet yields no candidate at all, so
    /// both have to be real.
    private func torrent(_ hash: String) -> SearchResult {
        SearchResult(
            infoHashHex: hash,
            title: "Torrent \(hash.prefix(4))",
            size: 1000, seeders: 10, peers: 0, grabs: nil, fileCount: nil,
            category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash)",
            sources: [Self.indexer], rawAttributes: [:])
    }

    /// A Gutenberg book or an Internet Archive file: no infohash, nothing to
    /// check, and nothing to prepare either.
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

    /// A direct download needs no debrid fetch, so it is already as instant as
    /// a cached torrent. Dropping it would make "cached only" mean
    /// "torrents only".
    @Test func aResultWithNoInfoHashIsKept() {
        let results = CachedOnlyFilter.apply(
            [direct()], states: [:], readiness: .ready)
        #expect(results.count == 1)
    }

    /// The answer has not arrived. Dropping it would make the list shrink as
    /// checks complete, which reads as results disappearing.
    @Test func unresolvedChecksAreKept() {
        let results = CachedOnlyFilter.apply(
            [torrent(Self.hashA), torrent(Self.hashB)],
            states: [Self.hashA: .unchecked, Self.hashB: .checking],
            readiness: .ready)
        #expect(results.count == 2)
    }

    /// A failed check is not a miss. It is retried on the next bulk check.
    @Test func aFailedCheckIsKept() {
        let results = CachedOnlyFilter.apply(
            [torrent(Self.hashA)],
            states: [Self.hashA: .error("timed out")],
            readiness: .ready)
        #expect(results.count == 1)
    }

    /// The Real-Debrid case. `unknowable` is not `notCached` — the same
    /// distinction `CacheReadiness` carries for badges and `LinkAvailability`
    /// carries for adding a link. Without this the switch empties the screen.
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
