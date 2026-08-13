import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stage 7e §4. A hoster link, unrestricted by a debrid, arriving on disk.
@Suite(.serialized, .usesStubURLProtocol) struct HostedDownloadTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let hosterLink = URL(string: "https://mediafire.com/file/abc/movie.mkv")!

    // MARK: - `source` is stored, not inferred

    /// It used to be a ternary over `directURL != nil` — two branches, no
    /// third slot, and anything that was not direct silently reported itself
    /// as a debrid *torrent*.
    @Test func aHostedRequestReportsItselfAsHosted() {
        let request = DownloadRequest(
            source: .debridHosted(
                provider: DebridProviderID(rawValue: "torbox"),
                download: DebridDownloadID(rawValue: "4821")),
            file: DebridFile(
                id: DebridFileID(rawValue: "0"), name: "movie.mkv",
                shortName: "movie.mkv", size: 1024, mimeType: nil),
            subfolder: nil,
            destinationRoot: temporaryDirectory(),
            groupKey: DownloadGroupKey(rawValue: "hosted:4821"))

        #expect(request.source == .debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821")))
    }

    // MARK: - The acceptance test

    /// **The mirror of `aDirectDownloadNeverAsksTheDebridForALink`.**
    ///
    /// That test hands the engine a provider whose every method throws and
    /// asserts a file still lands. This one asserts the opposite: when the
    /// debrid cannot produce a link, **nothing lands on disk**.
    ///
    /// The tempting failure is falling back to GETting the hoster URL itself.
    /// That request *succeeds* — and writes a 40 KB HTML page named like a
    /// movie.
    ///
    /// **The stub answers every request with a body**, which is what makes
    /// this an acceptance test rather than a coincidence: a fallback would
    /// find something to download and put a file on disk. Without the stub
    /// the fetch fails for want of a network and "nothing landed" proves
    /// nothing — asserting the wrong property is failure mode #4 in this
    /// repo's own list, and this test had it on the first attempt.
    @Test func aHostedDownloadNeverFallsBackToFetchingTheHosterPage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let page = Data(String(repeating: "<html>not the movie</html>", count: 64).utf8)
        StubURLProtocol.reset { _ in
            StubURLProtocol.Response(status: 200, headers: [:], body: page)
        }

        let engine = DownloadEngine(
            provider: RefusingWebDebrid(),
            transfer: RangeTransfer(
                body: ChunkedBody(configuration: StubURLProtocol.makeConfiguration())),
            maxConcurrent: 1)

        let id = await engine.enqueue(DownloadRequest(
            source: .debridHosted(
                provider: DebridProviderID(rawValue: "refusing"),
                download: DebridDownloadID(rawValue: "1")),
            file: DebridFile(
                id: DebridFileID(rawValue: "0"), name: "movie.mkv",
                shortName: "movie.mkv", size: 1024, mimeType: nil),
            subfolder: nil,
            destinationRoot: root,
            groupKey: DownloadGroupKey(rawValue: "hosted:1")))

        var failed = false
        for await event in await engine.events {
            if case .failed(let failedID, _) = event, failedID == id {
                failed = true
                break
            }
            if case .finished(let doneID, _) = event, doneID == id {
                Issue.record("a refused unrestrict must not finish")
                break
            }
        }

        #expect(failed)
        let landed = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        #expect(landed.isEmpty, "a refused unrestrict must leave nothing on disk")
    }
}

/// Every web-download method throws. A stub that quietly returned a plausible
/// URL would let the fallback this test exists to forbid slip through.
private struct RefusingWebDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "refusing")
    let displayName = "Refusing"

    func supportedHosts() async throws -> [DebridHost] {
        [DebridHost(
            id: HostID(rawValue: "mediafire"), displayName: "MediaFire",
            domains: ["mediafire.com"], isActive: true)]
    }
    func submitLink(_ url: URL) async throws -> DebridDownloadID {
        DebridDownloadID(rawValue: "1")
    }
    func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
        DebridWebDownload(
            id: id, name: "movie.mkv", size: 1024, progress: 1,
            state: .completed, files: [])
    }
    func downloadURL(web id: DebridDownloadID) async throws -> URL {
        throw DebridError.linkExpired
    }

    func validateCredentials() async throws -> DebridAccount { throw DebridError.unauthorized }
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] {
        throw DebridError.unauthorized
    }
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        throw DebridError.unauthorized
    }
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        throw DebridError.unauthorized
    }
    func files(in id: DebridTorrentID) async throws -> [DebridFile] {
        throw DebridError.unauthorized
    }
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        throw DebridError.unauthorized
    }
    func delete(torrent: DebridTorrentID) async throws { throw DebridError.unauthorized }
}

/// Stage 7e §4.2. `DownloadRecord` stored a torrent triple, so a restored
/// direct download rebuilt with `("direct", "direct")` and resuming asked a
/// provider that does not exist — an open known gap. Persisting the source
/// fixes direct and hosted with one migration rather than two.
@Suite struct DownloadSourcePersistenceTests {
    private let root = URL(fileURLWithPath: "/tmp/fetch-restore", isDirectory: true)

    private func record(sourceJSON: String?, infoHash: String = "") -> DownloadRecord {
        let record = DownloadRecord(
            infoHash: infoHash,
            providerID: "torbox",
            debridTorrentID: "77",
            debridFileID: "3",
            displayName: "movie.mkv",
            relativePath: "movie.mkv",
            destinationPath: root.path,
            originalFilename: "movie.mkv",
            totalBytes: 1024)
        record.sourceJSON = sourceJSON
        return record
    }

    private func json(_ source: DownloadSource) -> String {
        String(data: try! JSONEncoder().encode(source), encoding: .utf8)!
    }

    /// **The migration's whole promise.** A row written before the column
    /// existed rebuilds exactly as it did — the torrent triple from the
    /// columns that are already there.
    @Test func aRowWithNoStoredSourceRebuildsTheTorrentTriple() throws {
        let request = try #require(record(sourceJSON: nil, infoHash: "abc").makeRequest())

        #expect(request.source == .debridTorrent(
            provider: DebridProviderID(rawValue: "torbox"),
            torrent: DebridTorrentID(rawValue: "77"),
            file: DebridFileID(rawValue: "3")))
    }

    /// The known gap, closed: a direct download comes back with its URL
    /// instead of the triple `("direct", "direct")`.
    @Test func aRestoredDirectDownloadKeepsItsURL() throws {
        let url = URL(string: "https://archive.org/download/x/book.epub")!
        let request = try #require(record(sourceJSON: json(.directHTTP(url: url))).makeRequest())

        #expect(request.source == .directHTTP(url: url))
        #expect(request.directURL == url)
    }

    @Test func aRestoredHostedDownloadKeepsItsDebridHandle() throws {
        let source = DownloadSource.debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821"))
        let request = try #require(record(sourceJSON: json(source)).makeRequest())

        #expect(request.source == source)
    }

    /// A corrupt or truncated value falls back to the columns rather than
    /// refusing to restore the row. Losing a download to a bad string in one
    /// field would be worse than resuming it the old way.
    @Test func anUnreadableStoredSourceFallsBackToTheColumns() throws {
        let request = try #require(record(sourceJSON: "{not json").makeRequest())

        #expect(request.source == .debridTorrent(
            provider: DebridProviderID(rawValue: "torbox"),
            torrent: DebridTorrentID(rawValue: "77"),
            file: DebridFileID(rawValue: "3")))
    }

    /// §6: a debrid CDN URL must never be persisted. The two debrid cases
    /// encode identifiers only, and `.directHTTP` encodes a public address —
    /// which is the rule expressed as a type rather than as a convention.
    @Test func onlyThePublicURLIsEverEncoded() throws {
        let hosted = json(.debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821")))

        #expect(!hosted.contains("http"))
        #expect(json(.directHTTP(url: URL(string: "https://archive.org/x")!))
            .contains("archive.org"))
    }
}

/// The write side. A column nothing writes is the recurring failure this repo
/// keeps finding; these assert the round trip, not just the read.
@Suite struct DownloadSourceRoundTripTests {
    private func request(_ source: DownloadSource) -> DownloadRequest {
        DownloadRequest(
            source: source,
            file: DebridFile(
                id: DebridFileID(rawValue: "3"), name: "movie.mkv",
                shortName: "movie.mkv", size: 1024, mimeType: nil),
            subfolder: nil,
            destinationRoot: URL(fileURLWithPath: "/tmp/fetch-roundtrip", isDirectory: true),
            groupKey: DownloadGroupKey(rawValue: "k"))
    }

    private func roundTrip(_ source: DownloadSource) throws -> DownloadSource? {
        let record = DownloadRecord(
            infoHash: "", providerID: "torbox", debridTorrentID: "77",
            debridFileID: "3", displayName: "movie.mkv", relativePath: "movie.mkv",
            destinationPath: "/tmp/fetch-roundtrip", originalFilename: "movie.mkv",
            totalBytes: 1024,
            sourceJSON: DownloadStore.encode(source))
        return record.makeRequest()?.source
    }

    @Test func aHostedSourceSurvivesTheRoundTrip() throws {
        let source = DownloadSource.debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821"))
        #expect(try roundTrip(source) == source)
    }

    @Test func aDirectSourceSurvivesTheRoundTrip() throws {
        let source = DownloadSource.directHTTP(
            url: URL(string: "https://archive.org/download/x/book.epub")!)
        #expect(try roundTrip(source) == source)
    }

    @Test func aTorrentSourceSurvivesTheRoundTrip() throws {
        let source = DownloadSource.debridTorrent(
            provider: DebridProviderID(rawValue: "torbox"),
            torrent: DebridTorrentID(rawValue: "77"),
            file: DebridFileID(rawValue: "3"))
        #expect(try roundTrip(source) == source)
    }

    /// A request carries the source it was built with, all the way to what
    /// gets stored.
    @Test func aRequestsSourceIsWhatGetsEncoded() throws {
        let hosted = DownloadSource.debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821"))

        let encoded = try #require(DownloadStore.encode(request(hosted).source))
        let decoded = try JSONDecoder().decode(
            DownloadSource.self, from: Data(encoded.utf8))

        #expect(decoded == hosted)
    }

    /// The stored form is stable, so a save that changes nothing writes
    /// nothing different.
    @Test func encodingIsDeterministic() {
        let hosted = DownloadSource.debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821"))

        #expect(DownloadStore.encode(hosted) == DownloadStore.encode(hosted))
        #expect(DownloadStore.encode(hosted) == #"{"debridHosted":{"download":"4821","provider":"torbox"}}"#)
    }
}

/// Stage 7e §4. Submitting a hoster link and waiting for the debrid.
@Suite struct HostedEnqueueTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enqueue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let link = URL(string: "https://mediafire.com/file/abc/movie.mkv")!

    /// The queued row points at the debrid handle, not at the hoster page.
    @Test func enqueueingALinkProducesAHostedRequest() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = DownloadEngine(provider: QueueingDebrid(), maxConcurrent: 1)
        let request = try await engine.prepareHostedLink(
            link, subfolder: nil, destinationRoot: root)

        #expect(request.source == .debridHosted(
            provider: DebridProviderID(rawValue: "queueing"),
            download: DebridDownloadID(rawValue: "4821")))
        #expect(request.file.shortName == "movie.mkv")
    }

    /// A provider that reports the download failed must throw rather than
    /// queue a row that can never move.
    @Test func aFailedWebDownloadThrowsRatherThanQueueing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = DownloadEngine(provider: FailingWebDebrid(), maxConcurrent: 1)

        await #expect(throws: (any Error).self) {
            try await engine.prepareHostedLink(link, subfolder: nil, destinationRoot: root)
        }
    }

    /// A synchronous provider gets **one look, never a loop**: its download
    /// is already complete when submit returns.
    ///
    /// One look is not polling — for Real-Debrid and Premiumize
    /// `webDownload` makes no network request at all, it just reports what
    /// submit already established, and it is where the filename comes from.
    /// What must not happen is the poll loop, which would sleep waiting for a
    /// state change that happened before the first look.
    @Test func aSynchronousProviderIsLookedAtOnceNotPolled() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = SynchronousWebDebrid()
        let engine = DownloadEngine(provider: provider, maxConcurrent: 1)
        _ = try await engine.prepareHostedLink(link, subfolder: nil, destinationRoot: root)

        #expect(provider.polls.count == 1)
    }
}

/// Queues, then reports complete on the first poll.
private struct QueueingDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "queueing")
    let displayName = "Queueing"

    func submitLink(_ url: URL) async throws -> DebridDownloadID {
        DebridDownloadID(rawValue: "4821")
    }
    func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
        DebridWebDownload(
            id: id, name: "movie.mkv", size: 2048, progress: 1,
            state: .completed, files: [])
    }
    func downloadURL(web id: DebridDownloadID) async throws -> URL {
        URL(string: "https://cdn.example/movie.mkv")!
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

private struct FailingWebDebrid: DebridProvider {
    let id = DebridProviderID(rawValue: "failingweb")
    let displayName = "FailingWeb"

    func submitLink(_ url: URL) async throws -> DebridDownloadID {
        DebridDownloadID(rawValue: "1")
    }
    func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
        DebridWebDownload(
            id: id, name: "", size: nil, progress: 0,
            state: .failed(reason: "host refused"), files: [])
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
    func downloadURL(web id: DebridDownloadID) async throws -> URL {
        URL(string: "https://example.com")!
    }
}

/// Real-Debrid's shape: nothing to poll, and it records any attempt to.
private final class SynchronousWebDebrid: DebridProvider, @unchecked Sendable {
    let id = DebridProviderID(rawValue: "sync")
    let displayName = "Sync"
    private let counter = Counted()
    var polls: (count: Int, _unused: Void) { (counter.value, ()) }

    var hostedLinksNeedPreparing: Bool { false }

    func submitLink(_ url: URL) async throws -> DebridDownloadID {
        DebridDownloadID(rawValue: url.absoluteString)
    }
    func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
        counter.increment()
        return DebridWebDownload(
            id: id, name: "movie.mkv", size: nil, progress: 1,
            state: .completed, files: [])
    }
    func downloadURL(web id: DebridDownloadID) async throws -> URL {
        URL(string: "https://cdn.example/movie.mkv")!
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


/// A counter usable from an async context — `NSLock` is not.
private final class Counted: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
