import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Adding a magnet or `.torrent`: which debrid gets it, and whether it is
/// already there.
///
/// The routing comment in `AppModel` claims a cached provider beats a
/// more-preferred uncached one. That is true for search results, whose hashes
/// were checked to draw their badges, and **silently false for a pasted
/// magnet**, whose hash nobody ever checked. These are the tests for the
/// difference.
@Suite struct LinkAvailabilityTests {
    private let hash = "274a4461422c9469b0e20d9c36de3ce7137467a4"

    private func store(_ providers: [any DebridProvider]) -> CacheStatusStore {
        CacheStatusStore(providers: providers, ttl: 300)
    }

    // MARK: - The bug

    /// **This is the one that fails today.** Resolving availability for a hash
    /// nobody has checked must *check it*, not read an empty map and shrug.
    @Test func resolvingAvailabilityAsksTheProviders() async {
        let asked = Asked()
        let provider = StubCacheDebrid("torbox", cached: [], asked: asked)

        _ = await LinkAvailability.resolve(
            hash: hash, providers: [provider], store: store([provider]))

        #expect(asked.hashes.contains(hash))
    }

    /// And the point of asking: a cached second debrid beats an uncached
    /// first, which is exactly what the doc comment promises and what a
    /// pasted magnet never got.
    @Test func aCachedSecondProviderBeatsAnUncachedFirst() async {
        let first = StubCacheDebrid("first", cached: [])
        let second = StubCacheDebrid("second", cached: [hash])
        let providers: [any DebridProvider] = [first, second]

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store(providers))

        #expect(availability == .cached(DebridProviderID(rawValue: "second")))
    }

    /// With nothing cached, preference order decides and the answer names who
    /// would do the fetching — so the sheet can say whose slot it will use.
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

    // MARK: - The answer nobody could give

    /// Real-Debrid's `instantAvailability` is a disabled endpoint. With only
    /// providers that cannot report, the answer is **unknowable**, not "not
    /// cached" — the latter asserts something no provider confirmed, and
    /// `CacheReadiness` already carries this reasoning for badges.
    @Test func aProviderThatCannotReportYieldsUnknowableNotAMiss() async {
        let rd = StubCacheDebrid("rd", cached: [], canReport: false)

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: [rd], store: store([rd]))

        #expect(availability == .unknowable(DebridProviderID(rawValue: "rd")))
    }

    /// One capable provider among incapable ones is enough to get a real
    /// answer — the incapable one is simply not consulted.
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

    /// A provider whose check throws must not be read as a miss: an error is
    /// an absent answer, and treating it as "not cached" would send the
    /// download somewhere on the strength of a failure.
    @Test func aFailingProviderDoesNotCountAsAMiss() async {
        let failing = StubCacheDebrid("failing", cached: [], fails: true)
        let good = StubCacheDebrid("good", cached: [hash])
        let providers: [any DebridProvider] = [failing, good]

        let availability = await LinkAvailability.resolve(
            hash: hash, providers: providers, store: store(providers))

        #expect(availability == .cached(DebridProviderID(rawValue: "good")))
    }

    // MARK: - What the sheet needs from it

    @Test func onlyACachedAnswerDownloadsWithoutConfirming() {
        let torbox = DebridProviderID(rawValue: "torbox")

        #expect(!LinkAvailability.cached(torbox).needsConfirmation)
        #expect(LinkAvailability.notCached(torbox).needsConfirmation)
        // Unknowable is not a warning about a long wait — nobody said there
        // would be one. Confirming here would nag every Real-Debrid user on
        // every add.
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

/// Records which hashes it was asked about — the point of the fix is the
/// request that now happens, and asserting on the returned value would pass
/// with no request at all.
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
