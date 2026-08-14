import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stage 7e §3.4–3.5. Which debrid, if any, can fetch a given hoster link.
///
/// Coverage is a property of the *debrid*, not of Fetch: a user with TorBox
/// and Real-Debrid has two different host lists, and a Rapidgator link may be
/// downloadable through one and not the other.
@Suite struct HostRoutingTests {
    private func host(
        _ id: String, domains: [String], isActive: Bool = true
    ) -> DebridHost {
        DebridHost(
            id: HostID(rawValue: id), displayName: id.capitalized,
            domains: domains, isActive: isActive)
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    private var mediafire: DebridHost { host("mediafire", domains: ["mediafire.com"]) }
    private var rapidgator: DebridHost { host("rapidgator", domains: ["rapidgator.net"]) }

    // MARK: - Matching is on label boundaries, not substrings

    /// **The one that matters.** `evil-mediafire.com` contains
    /// `mediafire.com`. Treating that as a match hands an attacker-chosen URL
    /// to the user's debrid account.
    ///
    /// Asserted on the *match*, not on the string — "substring checks on
    /// paths" is the third entry on this repo's recurring-failure list, and
    /// the test that missed it checked the string rather than the result.
    @Test func aLookalikeDomainDoesNotMatch() {
        #expect(!mediafire.matches(url("https://evil-mediafire.com/file/x")))
    }

    @Test func aSuffixWithoutADotDoesNotMatch() {
        #expect(!mediafire.matches(url("https://notmediafire.com/file/x")))
    }

    /// And the rule must not over-reject: a subdomain is the normal case.
    @Test func aSubdomainMatches() {
        #expect(mediafire.matches(url("https://www.mediafire.com/file/x")))
        #expect(mediafire.matches(url("https://download1234.mediafire.com/abc")))
    }

    @Test func theBareDomainMatches() {
        #expect(mediafire.matches(url("https://mediafire.com/file/x")))
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(mediafire.matches(url("https://WWW.MediaFire.COM/file/x")))
    }

    /// A host with several domains matches any of them — 1fichier serves
    /// several, and listing them is the provider's job, not a caller's.
    @Test func anyOfAHostsDomainsMatches() {
        let fichier = host("1fichier", domains: ["1fichier.com", "alterupload.com"])

        #expect(fichier.matches(url("https://alterupload.com/x")))
        #expect(fichier.matches(url("https://1fichier.com/x")))
    }

    /// A URL with no host at all is not a match for anything.
    @Test func aURLWithNoHostMatchesNothing() {
        #expect(!mediafire.matches(url("file:///etc/passwd")))
    }

    // MARK: - Routing across configured providers

    @Test func theLinkRoutesToWhicheverProviderCoversTheHost() {
        let chosen = DebridRouter.provider(
            forHost: url("https://rapidgator.net/file/x"),
            providers: [DebridProviderID(rawValue: "torbox"), DebridProviderID(rawValue: "rd")],
            supportedBy: [
                DebridProviderID(rawValue: "torbox"): [mediafire],
                DebridProviderID(rawValue: "rd"): [rapidgator],
            ])

        #expect(chosen?.provider.rawValue == "rd")
    }

    /// Preference order decides among several that cover it — the same rule
    /// the cached-torrent router uses.
    @Test func amongSeveralCoveringProvidersThePreferredOneWins() {
        let chosen = DebridRouter.provider(
            forHost: url("https://mediafire.com/file/x"),
            providers: [DebridProviderID(rawValue: "first"), DebridProviderID(rawValue: "second")],
            supportedBy: [
                DebridProviderID(rawValue: "first"): [mediafire],
                DebridProviderID(rawValue: "second"): [mediafire],
            ])

        #expect(chosen?.provider.rawValue == "first")
    }

    /// Unlike the torrent router, there is **no fallback to the first
    /// provider**. An uncovered host is not a slower download, it is one that
    /// cannot happen, and handing it to a debrid that does not support it
    /// would fail at submit with a message about the wrong thing.
    @Test func anUncoveredHostRoutesNowhere() {
        let chosen = DebridRouter.provider(
            forHost: url("https://somerandomhost.com/x"),
            providers: [DebridProviderID(rawValue: "torbox")],
            supportedBy: [DebridProviderID(rawValue: "torbox"): [mediafire]])

        #expect(chosen == nil)
    }

    /// A host the provider itself reports as down is not coverage.
    @Test func anInactiveHostIsNotAMatch() {
        let chosen = DebridRouter.provider(
            forHost: url("https://mediafire.com/file/x"),
            providers: [DebridProviderID(rawValue: "torbox")],
            supportedBy: [DebridProviderID(rawValue: "torbox"): [
                host("mediafire", domains: ["mediafire.com"], isActive: false)
            ]])

        #expect(chosen == nil)
    }

    /// …but a second provider that has it up still wins, rather than the
    /// down report poisoning the whole decision.
    @Test func anotherProviderWithTheHostUpStillWins() {
        let chosen = DebridRouter.provider(
            forHost: url("https://mediafire.com/file/x"),
            providers: [DebridProviderID(rawValue: "down"), DebridProviderID(rawValue: "up")],
            supportedBy: [
                DebridProviderID(rawValue: "down"): [
                    host("mediafire", domains: ["mediafire.com"], isActive: false)],
                DebridProviderID(rawValue: "up"): [mediafire],
            ])

        #expect(chosen?.provider.rawValue == "up")
    }

    /// §5's degrade-to-invisible: a provider with no web-download support
    /// reports no hosts, so it never wins and is never asked for a link.
    @Test func aProviderWithNoHostsNeverWins() {
        let chosen = DebridRouter.provider(
            forHost: url("https://mediafire.com/file/x"),
            providers: [DebridProviderID(rawValue: "none"), DebridProviderID(rawValue: "torbox")],
            supportedBy: [
                DebridProviderID(rawValue: "none"): [],
                DebridProviderID(rawValue: "torbox"): [mediafire],
            ])

        #expect(chosen?.provider.rawValue == "torbox")
    }

    @Test func withNoProvidersAtAllNothingRoutes() {
        #expect(DebridRouter.provider(
            forHost: url("https://mediafire.com/x"), providers: [], supportedBy: [:]) == nil)
    }

    // MARK: - The matched host's identity

    /// `.hosted` carries a `HostID`, and it comes from whichever host matched
    /// rather than from parsing the URL — the provider named it.
    @Test func theMatchedHostIdentifiesItself() {
        let matched = DebridRouter.host(
            for: url("https://download1234.mediafire.com/x"), in: [rapidgator, mediafire])

        #expect(matched?.id == HostID(rawValue: "mediafire"))
    }
}

/// Stage 7e §3.3. The four web-download methods are defaulted, so a provider
/// that does not implement them degrades to invisible rather than broken.
@Suite struct WebDownloadDefaultsTests {
    /// A provider that says nothing about hosts supports none — not "all",
    /// and not a crash. This is the whole degradation story: it reports `[]`,
    /// so it never wins host routing, so the other three are never called.
    @Test func aProviderThatSaysNothingSupportsNoHosts() async throws {
        #expect(try await SilentDebrid().supportedHosts().isEmpty)
    }

    /// And if one is called anyway, it refuses rather than inventing a link.
    @Test func theUnimplementedOperationsThrowRatherThanReturnSomething() async {
        let provider = SilentDebrid()
        let url = URL(string: "https://mediafire.com/file/x")!

        await #expect(throws: DebridError.self) { try await provider.submitLink(url) }
        await #expect(throws: DebridError.self) {
            try await provider.webDownload(id: DebridDownloadID(rawValue: "1"))
        }
        await #expect(throws: DebridError.self) {
            try await provider.downloadURL(web: DebridDownloadID(rawValue: "1"))
        }
    }
}

/// Implements only the torrent half of the protocol — which is exactly what a
/// debrid without web downloads looks like.
private struct SilentDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "silent")
    let displayName = "Silent"

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

/// Stage 7e §3.6. Host lists change rarely; a cold call per pasted link would
/// be absurd, and per search result — once 7f produces them — ruinous.
@Suite struct SupportedHostsCacheTests {
    private let mediafire = DebridHost(
        id: HostID(rawValue: "mediafire"), displayName: "MediaFire",
        domains: ["mediafire.com"], isActive: true)

    /// A counting provider, because the point of a cache is the requests it
    /// does *not* make — asserting on the returned hosts would pass with no
    /// cache at all.
    fileprivate final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func provider(_ id: String, calls: Counter, hosts: [DebridHost]) -> CountingDebrid {
        CountingDebrid(id: id, calls: calls, hosts: hosts)
    }

    @Test func theFirstAskFetches() async throws {
        let calls = Counter()
        let cache = SupportedHostsCache(ttl: 3600)

        _ = await cache.hosts(for: [provider("a", calls: calls, hosts: [mediafire])], now: Date())
        #expect(calls.count == 1)
    }

    @Test func aSecondAskInsideTheWindowMakesNoRequest() async throws {
        let calls = Counter()
        let cache = SupportedHostsCache(ttl: 3600)
        let providers = [provider("a", calls: calls, hosts: [mediafire])]
        let start = Date()

        _ = await cache.hosts(for: providers, now: start)
        let second = await cache.hosts(for: providers, now: start.addingTimeInterval(60))

        #expect(calls.count == 1)
        #expect(second[DebridProviderID(rawValue: "a")]?.count == 1)
    }

    @Test func pastTheTTLItFetchesAgain() async throws {
        let calls = Counter()
        let cache = SupportedHostsCache(ttl: 3600)
        let providers = [provider("a", calls: calls, hosts: [mediafire])]
        let start = Date()

        _ = await cache.hosts(for: providers, now: start)
        _ = await cache.hosts(for: providers, now: start.addingTimeInterval(3601))

        #expect(calls.count == 2)
    }

    /// One provider failing must not empty the map for the others: a debrid
    /// that is down should cost its own coverage, not everyone's.
    @Test func oneProviderFailingLeavesTheOthersIntact() async throws {
        let calls = Counter()
        let cache = SupportedHostsCache(ttl: 3600)

        let map = await cache.hosts(
            for: [FailingDebrid(), provider("ok", calls: calls, hosts: [mediafire])],
            now: Date())

        #expect(map[DebridProviderID(rawValue: "ok")]?.count == 1)
        #expect(map[DebridProviderID(rawValue: "failing")] == nil)
    }

    /// A refresh is the user saying "ask again", so it must actually ask.
    @Test func refreshingDiscardsWhatWasCached() async throws {
        let calls = Counter()
        let cache = SupportedHostsCache(ttl: 3600)
        let providers = [provider("a", calls: calls, hosts: [mediafire])]
        let start = Date()

        _ = await cache.hosts(for: providers, now: start)
        await cache.invalidate()
        _ = await cache.hosts(for: providers, now: start)

        #expect(calls.count == 2)
    }
}

private struct CountingDebrid: DebridProvider {
    let id: DebridProviderID
    let displayName: String
    let calls: SupportedHostsCacheTests.Counter
    let hosts: [DebridHost]

    init(id: String, calls: SupportedHostsCacheTests.Counter, hosts: [DebridHost]) {
        self.id = DebridProviderID(rawValue: id)
        self.displayName = id
        self.calls = calls
        self.hosts = hosts
    }

    func supportedHosts() async throws -> [DebridHost] {
        calls.increment()
        return hosts
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

private struct FailingDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "failing")
    let displayName = "Failing"

    func supportedHosts() async throws -> [DebridHost] { throw DebridError.unauthorized }

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
