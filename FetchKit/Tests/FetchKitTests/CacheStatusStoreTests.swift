import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

private actor RecordingDebridProvider: DebridProvider {
    nonisolated let id: DebridProviderID
    nonisolated let displayName = "Fake"
    nonisolated let canReportCacheStatus: Bool

    init(id: String = "fake", canReportCacheStatus: Bool = true) {
        self.id = DebridProviderID(rawValue: id)
        self.canReportCacheStatus = canReportCacheStatus
    }

    private var responses: [String: CacheEntry] = [:]
    private var errorToThrow: (any Error)?
    private(set) var calls: [[String]] = []

    func setResponse(hash: String, entry: CacheEntry) { responses[hash] = entry }
    func setError(_ error: (any Error)?) { errorToThrow = error }
    func recordedCalls() -> [[String]] { calls }

    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] {
        calls.append(hashes.sorted())
        if let errorToThrow { throw errorToThrow }
        var result: [String: CacheEntry] = [:]
        for hash in hashes {
            result[hash] = responses[hash] ?? CacheEntry(infoHashHex: hash, name: "", size: 0, files: nil)
        }
        return result
    }

    nonisolated func validateCredentials() async throws -> DebridAccount {
        DebridAccount(email: nil, plan: nil, expiresAt: nil)
    }
    nonisolated func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        DebridTorrentID(rawValue: "0")
    }
    nonisolated func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        DebridTorrent(
            id: id, infoHashHex: "", name: "", size: 0, progress: 0,
            state: .unknown("n/a"), files: [], seeds: nil, downloadSpeed: nil, eta: nil
        )
    }
    nonisolated func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
    nonisolated func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        URL(string: "https://example.com")!
    }
    nonisolated func delete(torrent: DebridTorrentID) async throws {}
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 0)) { self.date = date }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }
}

private struct TestError: Error, Equatable {}

@Suite struct CacheStatusStoreTests {
    private let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
    private let hashB = "aa1155ecdc7ca55fb0bbf81323d87062db1f6d99"

    @Test func unknownHashStartsUnchecked() async {
        let store = CacheStatusStore(provider: RecordingDebridProvider())
        #expect(await store.state(for: hashA) == .unchecked)
    }

    @Test func checkResolvesToCachedWhenSizeIsPositive() async {
        let provider = RecordingDebridProvider()
        await provider.setResponse(
            hash: hashA, entry: CacheEntry(infoHashHex: hashA, name: "Movie", size: 123, files: nil)
        )
        let store = CacheStatusStore(provider: provider)
        await store.check(hashes: [hashA])

        guard case .cached(let entry) = await store.state(for: hashA) else {
            Issue.record("expected .cached"); return
        }
        #expect(entry.size == 123)
    }

    @Test func checkResolvesToNotCachedWhenSizeIsZero() async {
        let store = CacheStatusStore(provider: RecordingDebridProvider())
        await store.check(hashes: [hashA])
        #expect(await store.state(for: hashA) == .notCached)
    }

    @Test func checkEmitsCheckingBeforeResolving() async {
        let provider = RecordingDebridProvider()
        let store = CacheStatusStore(provider: provider)

        var iterator = store.updates.makeAsyncIterator()
        async let _ = store.check(hashes: [hashA])

        let first = await iterator.next()
        #expect(first?.state == .checking)
        let second = await iterator.next()
        #expect(second?.state == .notCached)
    }

    @Test func failedCheckSetsErrorState() async {
        let provider = RecordingDebridProvider()
        await provider.setError(TestError())
        let store = CacheStatusStore(provider: provider)
        await store.check(hashes: [hashA])

        guard case .error = await store.state(for: hashA) else {
            Issue.record("expected .error"); return
        }
    }


    @Test func secondCheckWithinTTLDoesNotHitProviderAgain() async {
        let provider = RecordingDebridProvider()
        let clock = MutableClock()
        let store = CacheStatusStore(provider: provider, ttl: 300, now: { clock.now })

        await store.check(hashes: [hashA])
        clock.advance(by: 60)
        await store.check(hashes: [hashA])

        #expect(await provider.recordedCalls().count == 1)
    }

    @Test func checkAfterTTLExpiresHitsProviderAgain() async {
        let provider = RecordingDebridProvider()
        let clock = MutableClock()
        let store = CacheStatusStore(provider: provider, ttl: 300, now: { clock.now })

        await store.check(hashes: [hashA])
        clock.advance(by: 301)
        await store.check(hashes: [hashA])

        #expect(await provider.recordedCalls().count == 2)
    }

    @Test func erroredHashIsNotMemoizedAndIsRetriedOnNextBulkCheck() async {
        let provider = RecordingDebridProvider()
        await provider.setError(TestError())
        let store = CacheStatusStore(provider: provider)

        await store.check(hashes: [hashA])
        guard case .error = await store.state(for: hashA) else {
            Issue.record("expected .error"); return
        }

        await provider.setError(nil)
        await store.check(hashes: [hashA])

        #expect(await store.state(for: hashA) == .notCached)
        #expect(await provider.recordedCalls().count == 2)
    }

    @Test func bulkCheckOnlyQueriesStaleHashes() async {
        let provider = RecordingDebridProvider()
        let store = CacheStatusStore(provider: provider)

        await store.check(hashes: [hashA])
        await store.check(hashes: [hashA, hashB])

        let calls = await provider.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls[1] == [hashB])
    }

    @Test func retryIgnoresTTLAndAlwaysRequeries() async {
        let provider = RecordingDebridProvider()
        let store = CacheStatusStore(provider: provider)

        await store.check(hashes: [hashA])
        await store.retry(hash: hashA)
        await store.retry(hash: hashA)

        #expect(await provider.recordedCalls().count == 3)
    }

    @Test func checkNormalizesHashCase() async {
        let provider = RecordingDebridProvider()
        let store = CacheStatusStore(provider: provider)

        await store.check(hashes: [hashA.uppercased()])
        #expect(await store.state(for: hashA) == .notCached)
    }
}

@Suite struct MultiProviderCacheStatusStoreTests {
    private let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"

    @Test func cachedOnAnyProviderResolvesToCached() async {
        let a = RecordingDebridProvider(id: "a")
        let b = RecordingDebridProvider(id: "b")
        await b.setResponse(
            hash: hashA, entry: CacheEntry(infoHashHex: hashA, name: "M", size: 500, files: nil))

        let store = CacheStatusStore(providers: [a, b])
        await store.check(hashes: [hashA])

        guard case .cached(let entry) = await store.state(for: hashA) else {
            Issue.record("expected .cached"); return
        }
        #expect(entry.size == 500)
    }

    @Test func notCachedAnywhereResolvesToNotCached() async {
        let store = CacheStatusStore(
            providers: [RecordingDebridProvider(id: "a"), RecordingDebridProvider(id: "b")])
        await store.check(hashes: [hashA])
        #expect(await store.state(for: hashA) == .notCached)
    }

    @Test func oneProviderFailingDoesNotHideAnothersHit() async {
        let broken = RecordingDebridProvider(id: "broken")
        await broken.setError(TestError())
        let good = RecordingDebridProvider(id: "good")
        await good.setResponse(
            hash: hashA, entry: CacheEntry(infoHashHex: hashA, name: "M", size: 7, files: nil))

        let store = CacheStatusStore(providers: [broken, good])
        await store.check(hashes: [hashA])

        guard case .cached = await store.state(for: hashA) else {
            Issue.record("expected .cached despite the other provider failing"); return
        }
    }

    @Test func aProviderThatCannotReportIsNeverQueried() async {
        let incapable = RecordingDebridProvider(id: "rd", canReportCacheStatus: false)
        let capable = RecordingDebridProvider(id: "torbox")
        await capable.setResponse(
            hash: hashA, entry: CacheEntry(infoHashHex: hashA, name: "M", size: 9, files: nil))

        let store = CacheStatusStore(providers: [incapable, capable])
        await store.check(hashes: [hashA])

        #expect(await incapable.recordedCalls().isEmpty)
        #expect(await capable.recordedCalls() == [[hashA]])
    }

    @Test func withNoCapableProviderNothingIsResolved() async {
        let store = CacheStatusStore(
            providers: [RecordingDebridProvider(id: "rd", canReportCacheStatus: false)])
        await store.check(hashes: [hashA])
        #expect(await store.state(for: hashA) == .unchecked)
    }
}

@Suite struct CachedProviderTrackingTests {
    private let hashA = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"

    private func entry(_ hash: String, size: Int64) -> CacheEntry {
        CacheEntry(infoHashHex: hash, name: "M", size: size, files: nil)
    }

    @Test func theStoreRemembersWhichProvidersHaveIt() async {
        let a = RecordingDebridProvider(id: "torbox")
        let b = RecordingDebridProvider(id: "premiumize")
        await b.setResponse(hash: hashA, entry: entry(hashA, size: 500))

        let store = CacheStatusStore(providers: [a, b])
        await store.check(hashes: [hashA])

        #expect(await store.cachedProviders(for: hashA).map(\.rawValue) == ["premiumize"])
    }

    @Test func severalProvidersHoldingItAreAllRecorded() async {
        let a = RecordingDebridProvider(id: "torbox")
        let b = RecordingDebridProvider(id: "premiumize")
        await a.setResponse(hash: hashA, entry: entry(hashA, size: 1))
        await b.setResponse(hash: hashA, entry: entry(hashA, size: 2))

        let store = CacheStatusStore(providers: [a, b])
        await store.check(hashes: [hashA])

        #expect(Set(await store.cachedProviders(for: hashA).map(\.rawValue))
            == ["torbox", "premiumize"])
    }

    @Test func aHashNobodyHasRecordsNoProviders() async {
        let store = CacheStatusStore(providers: [RecordingDebridProvider(id: "torbox")])
        await store.check(hashes: [hashA])
        #expect(await store.cachedProviders(for: hashA).isEmpty)
    }

    @Test func aFailingProviderIsNotRecordedAsHavingIt() async {
        let broken = RecordingDebridProvider(id: "torbox")
        await broken.setError(TestError())
        let store = CacheStatusStore(providers: [broken])
        await store.check(hashes: [hashA])
        #expect(await store.cachedProviders(for: hashA).isEmpty)
    }

    @Test func anUncheckedHashHasNoProviders() async {
        let store = CacheStatusStore(providers: [RecordingDebridProvider(id: "torbox")])
        #expect(await store.cachedProviders(for: hashA).isEmpty)
    }
}
