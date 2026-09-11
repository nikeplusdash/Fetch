import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct HostedDownloadTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let hosterLink = URL(string: "https://mediafire.com/file/abc/movie.mkv")!


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

    @Test func aRowWithNoStoredSourceRebuildsTheTorrentTriple() throws {
        let request = try #require(record(sourceJSON: nil, infoHash: "abc").makeRequest())

        #expect(request.source == .debridTorrent(
            provider: DebridProviderID(rawValue: "torbox"),
            torrent: DebridTorrentID(rawValue: "77"),
            file: DebridFileID(rawValue: "3")))
    }

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

    @Test func anUnreadableStoredSourceFallsBackToTheColumns() throws {
        let request = try #require(record(sourceJSON: "{not json").makeRequest())

        #expect(request.source == .debridTorrent(
            provider: DebridProviderID(rawValue: "torbox"),
            torrent: DebridTorrentID(rawValue: "77"),
            file: DebridFileID(rawValue: "3")))
    }

    @Test func onlyThePublicURLIsEverEncoded() throws {
        let hosted = json(.debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821")))

        #expect(!hosted.contains("http"))
        #expect(json(.directHTTP(url: URL(string: "https://archive.org/x")!))
            .contains("archive.org"))
    }
}

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

    @Test func aRequestsSourceIsWhatGetsEncoded() throws {
        let hosted = DownloadSource.debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821"))

        let encoded = try #require(DownloadStore.encode(request(hosted).source))
        let decoded = try JSONDecoder().decode(
            DownloadSource.self, from: Data(encoded.utf8))

        #expect(decoded == hosted)
    }

    @Test func encodingIsDeterministic() {
        let hosted = DownloadSource.debridHosted(
            provider: DebridProviderID(rawValue: "torbox"),
            download: DebridDownloadID(rawValue: "4821"))

        #expect(DownloadStore.encode(hosted) == DownloadStore.encode(hosted))
        #expect(DownloadStore.encode(hosted) == #"{"debridHosted":{"download":"4821","provider":"torbox"}}"#)
    }
}

@Suite struct HostedEnqueueTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enqueue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let link = URL(string: "https://mediafire.com/file/abc/movie.mkv")!

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

    @Test func aFailedWebDownloadThrowsRatherThanQueueing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = DownloadEngine(provider: FailingWebDebrid(), maxConcurrent: 1)

        await #expect(throws: (any Error).self) {
            try await engine.prepareHostedLink(link, subfolder: nil, destinationRoot: root)
        }
    }

    @Test func aSynchronousProviderIsLookedAtOnceNotPolled() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = SynchronousWebDebrid()
        let engine = DownloadEngine(provider: provider, maxConcurrent: 1)
        _ = try await engine.prepareHostedLink(link, subfolder: nil, destinationRoot: root)

        #expect(provider.polls.count == 1)
    }
}

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
