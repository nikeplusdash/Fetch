import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

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


    @Test func aLookalikeDomainDoesNotMatch() {
        #expect(!mediafire.matches(url("https://evil-mediafire.com/file/x")))
    }

    @Test func aSuffixWithoutADotDoesNotMatch() {
        #expect(!mediafire.matches(url("https://notmediafire.com/file/x")))
    }

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

    @Test func anyOfAHostsDomainsMatches() {
        let fichier = host("1fichier", domains: ["1fichier.com", "alterupload.com"])

        #expect(fichier.matches(url("https://alterupload.com/x")))
        #expect(fichier.matches(url("https://1fichier.com/x")))
    }

    @Test func aURLWithNoHostMatchesNothing() {
        #expect(!mediafire.matches(url("file:///etc/passwd")))
    }


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

    @Test func anUncoveredHostRoutesNowhere() {
        let chosen = DebridRouter.provider(
            forHost: url("https://somerandomhost.com/x"),
            providers: [DebridProviderID(rawValue: "torbox")],
            supportedBy: [DebridProviderID(rawValue: "torbox"): [mediafire]])

        #expect(chosen == nil)
    }

    @Test func anInactiveHostIsNotAMatch() {
        let chosen = DebridRouter.provider(
            forHost: url("https://mediafire.com/file/x"),
            providers: [DebridProviderID(rawValue: "torbox")],
            supportedBy: [DebridProviderID(rawValue: "torbox"): [
                host("mediafire", domains: ["mediafire.com"], isActive: false)
            ]])

        #expect(chosen == nil)
    }

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


    @Test func theMatchedHostIdentifiesItself() {
        let matched = DebridRouter.host(
            for: url("https://download1234.mediafire.com/x"), in: [rapidgator, mediafire])

        #expect(matched?.id == HostID(rawValue: "mediafire"))
    }
}

@Suite struct WebDownloadDefaultsTests {
    @Test func aProviderThatSaysNothingSupportsNoHosts() async throws {
        #expect(try await SilentDebrid().supportedHosts().isEmpty)
    }

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

@Suite struct SupportedHostsCacheTests {
    private let mediafire = DebridHost(
        id: HostID(rawValue: "mediafire"), displayName: "MediaFire",
        domains: ["mediafire.com"], isActive: true)

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

    @Test func oneProviderFailingLeavesTheOthersIntact() async throws {
        let calls = Counter()
        let cache = SupportedHostsCache(ttl: 3600)

        let map = await cache.hosts(
            for: [FailingDebrid(), provider("ok", calls: calls, hosts: [mediafire])],
            now: Date())

        #expect(map[DebridProviderID(rawValue: "ok")]?.count == 1)
        #expect(map[DebridProviderID(rawValue: "failing")] == nil)
    }

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
