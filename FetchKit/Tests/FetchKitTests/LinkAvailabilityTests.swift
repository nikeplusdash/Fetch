import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct LinkAvailabilityTests {
    private let hash = "274a4461422c9469b0e20d9c36de3ce7137467a4"

    private func store(_ providers: [any DebridProvider]) -> CacheStatusStore {
        CacheStatusStore(providers: providers, ttl: 300)
    }


    @Test func resolvingAvailabilityAsksTheProviders() async {
        let asked = Asked()
        let provider = StubCacheDebrid("torbox", cached: [], asked: asked)

        _ = await LinkAvailability.resolve(
            hash: hash, providers: [provider], store: store([provider]))

        #expect(asked.hashes.contains(hash))
    }

    @Test func aCachedSecondProviderBeatsAnUncachedFirst() async {
        let first = StubCacheDebrid("first", cached: [])
        let second = StubCacheDebrid("second", cached: [hash])
        let providers: [any DebridProvider] = [first, second]

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store(providers))

        #expect(availability == .cached(DebridProviderID(rawValue: "second")))
    }

    @Test func withNothingCachedTheFirstProviderWouldFetchIt() async {
        let first = StubCacheDebrid("first", cached: [])
        let second = StubCacheDebrid("second", cached: [])
        let providers: [any DebridProvider] = [first, second]

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store(providers))

        #expect(availability == .notCached(DebridProviderID(rawValue: "first")))
    }

    @Test func amongSeveralCachedProvidersThePreferredOneWins() async {
        let first = StubCacheDebrid("first", cached: [hash])
        let second = StubCacheDebrid("second", cached: [hash])
        let providers: [any DebridProvider] = [first, second]

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store(providers))

        #expect(availability == .cached(DebridProviderID(rawValue: "first")))
    }


    @Test func aProviderThatCannotReportYieldsUnknowableNotAMiss() async {
        let rd = StubCacheDebrid("rd", cached: [], canReport: false)

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: [rd], store: store([rd]))

        #expect(availability == .unknowable(DebridProviderID(rawValue: "rd")))
    }

    @Test func oneCapableProviderAmongIncapableOnesStillAnswers() async {
        let rd = StubCacheDebrid("rd", cached: [], canReport: false)
        let torbox = StubCacheDebrid("torbox", cached: [hash])
        let providers: [any DebridProvider] = [rd, torbox]

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store(providers))

        #expect(availability == .cached(DebridProviderID(rawValue: "torbox")))
    }

    @Test func withNoProvidersThereIsNothingToAsk() async {
        let availability = await LinkAvailability.resolve(
            hash: hash, providers: [], store: store([]))

        #expect(availability == .noProviders)
    }

    @Test func aFailingProviderDoesNotCountAsAMiss() async {
        let failing = StubCacheDebrid("failing", cached: [], fails: true)
        let good = StubCacheDebrid("good", cached: [hash])
        let providers: [any DebridProvider] = [failing, good]

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store(providers))

        #expect(availability == .cached(DebridProviderID(rawValue: "good")))
    }


    @Test func onlyACachedAnswerDownloadsWithoutConfirming() {
        let torbox = DebridProviderID(rawValue: "torbox")

        #expect(!LinkAvailability.cached(torbox).needsConfirmation)
        #expect(LinkAvailability.notCached(torbox).needsConfirmation)
        #expect(!LinkAvailability.unknowable(torbox).needsConfirmation)
    }

    @Test func everyAnswerButNoProvidersNamesTheDebridThatWouldServeIt() {
        let torbox = DebridProviderID(rawValue: "torbox")

        #expect(LinkAvailability.cached(torbox).provider == torbox)
        #expect(LinkAvailability.notCached(torbox).provider == torbox)
        #expect(LinkAvailability.unknowable(torbox).provider == torbox)
        #expect(LinkAvailability.noProviders.provider == nil)
    }
}

final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func record(_ hashes: [String]) {
        lock.lock(); seen.append(contentsOf: hashes); lock.unlock()
    }
    var hashes: [String] {
        lock.lock(); defer { lock.unlock() }; return seen
    }
}

private struct StubCacheDebrid: DebridProvider {
    let id: DebridProviderID
    let displayName: String
    let canReportCacheStatus: Bool
    let cached: Set<String>
    let fails: Bool
    let asked: Asked?

    init(
        _ id: String, cached: [String], canReport: Bool = true,
        fails: Bool = false, asked: Asked? = nil
    ) {
        self.id = DebridProviderID(rawValue: id)
        self.displayName = id
        self.canReportCacheStatus = canReport
        self.cached = Set(cached.map { $0.lowercased() })
        self.fails = fails
        self.asked = asked
    }

    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] {
        asked?.record(hashes)
        if fails { throw DebridError.unauthorized }
        var out: [String: CacheEntry] = [:]
        for hash in hashes where cached.contains(hash.lowercased()) {
            out[hash.lowercased()] = CacheEntry(
                infoHashHex: hash.lowercased(), name: "x", size: 1, files: [])
        }
        return out
    }

    func validateCredentials() async throws -> DebridAccount {
        DebridAccount(email: nil, plan: nil, expiresAt: nil)
    }
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
