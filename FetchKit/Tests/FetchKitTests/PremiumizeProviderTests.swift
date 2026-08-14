import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stub-driven, because there is no Premiumize account to test against. These
/// pin the mapping from the documented JSON to the protocol's types; they
/// cannot prove the documentation matches the live service.
@Suite(.serialized, .usesStubURLProtocol) struct PremiumizeProviderTests {
    private func makeProvider() -> PremiumizeProvider {
        PremiumizeProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private let hashA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let hashB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    // MARK: - Cache

    /// The documented shape is parallel arrays positional to the request, which
    /// is easy to misalign — hence asserting on both entries, not just the hit.
    @Test func parallelArraysMapPositionallyOntoTheRequestedHashes() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","response":[true,false],
         "filename":["Big.Buck.Bunny.mkv",null],"filesize":["276445467",0]}
        """)])

        let result = try await makeProvider().checkCached(
            hashes: [hashA, hashB], listFiles: false)

        #expect(result[hashA]?.size == 276_445_467)
        #expect(result[hashA]?.name == "Big.Buck.Bunny.mkv")
        #expect(result[hashB]?.size == 0)
    }

    /// Same contract as TorBox: a caller gets an entry per hash it asked about.
    @Test func theCacheCheckIsTotalOverItsInput() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","response":[false,false],"filename":[null,null],"filesize":[0,0]}
        """)])

        let result = try await makeProvider().checkCached(
            hashes: [hashA, hashB], listFiles: false)
        #expect(result.count == 2)
    }

    /// A shorter array than documented must degrade, not trap — the crash
    /// would land on whichever user Premiumize changed the shape for first.
    @Test func aTruncatedResponseArrayDoesNotTrap() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","response":[true],"filename":["only.mkv"],"filesize":[10]}
        """)])

        let result = try await makeProvider().checkCached(
            hashes: [hashA, hashB], listFiles: false)
        #expect(result[hashA]?.size == 10)
        #expect(result[hashB]?.size == 0)
    }

    @Test func aFailureStatusIsReportedRatherThanReadAsAllMisses() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"error","message":"invalid api key"}
        """)])

        await #expect(throws: DebridError.self) {
            _ = try await makeProvider().checkCached(hashes: [hashA], listFiles: false)
        }
    }

    @Test func unauthorizedIsMappedNotSwallowed() async throws {
        StubURLProtocol.reset([.json("{}", status: 401)])
        await #expect(throws: DebridError.unauthorized) {
            _ = try await makeProvider().checkCached(hashes: [hashA], listFiles: false)
        }
    }

    /// Premiumize returns sizes as a number on some endpoints and a string on
    /// others; decoding one shape alone would break on the other.
    @Test func sizesDecodeFromBothNumberAndString() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","response":[true,true],
         "filename":["a","b"],"filesize":[1024,"2048"]}
        """)])

        let result = try await makeProvider().checkCached(
            hashes: [hashA, hashB], listFiles: false)
        #expect(result[hashA]?.size == 1024)
        #expect(result[hashB]?.size == 2048)
    }

    @Test func premiumizeCanReportCacheStatus() {
        #expect(makeProvider().canReportCacheStatus)
    }

    // MARK: - Preview

    /// The reason Premiumize slots in cleanly: `directdl` yields a file list
    /// for cached content without creating a transfer (§6).
    @Test func directDLProvidesAPreviewFileListWithoutATransfer() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","content":[
          {"path":"Show/S01E01.mkv","size":100,"link":"https://x/1"},
          {"path":"Show/S01E02.mkv","size":200,"link":"https://x/2"}]}
        """)])

        let files = try await makeProvider().previewFiles(rawMagnet: "magnet:?xt=urn:btih:\(hashA)")

        #expect(files.map(\.name) == ["Show/S01E01.mkv", "Show/S01E02.mkv"])
        #expect(files.map(\.shortName) == ["S01E01.mkv", "S01E02.mkv"])
        #expect(files.map(\.size) == [100, 200])

        let request = try #require(StubURLProtocol.recordedRequests().last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.hasSuffix("transfer/directdl") == true)
    }

    // MARK: - Transfers

    @Test func submittingAMagnetReturnsTheTransferID() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","id":"tr-99","name":"Some.Release"}
        """)])

        let id = try await makeProvider().submitMagnet(rawMagnet: "magnet:?xt=urn:btih:\(hashA)")
        #expect(id.rawValue == "tr-99")

        let request = try #require(StubURLProtocol.recordedRequests().last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    /// Premiumize has no per-id transfer endpoint, so `torrent(id:)` filters
    /// the list — and an id that is not in it is a miss, not a crash.
    @Test func anUnknownTransferIDIsFileNotFound() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","transfers":[{"id":"other","name":"x","status":"finished"}]}
        """)])

        await #expect(throws: DebridError.fileNotFound) {
            _ = try await makeProvider().torrent(id: DebridTorrentID(rawValue: "tr-99"))
        }
    }

    @Test func transferStatusesMapOntoTheProtocolStates() {
        #expect(PremiumizeProvider.state(from: "waiting") == .queued)
        #expect(PremiumizeProvider.state(from: "running") == .downloading)
        #expect(PremiumizeProvider.state(from: "seeding") == .uploading)
        #expect(PremiumizeProvider.state(from: "finished") == .completed)
        #expect(PremiumizeProvider.state(from: "timeout") == .failed(reason: "timeout"))
    }

    /// An unrecognized status must round-trip rather than being forced into a
    /// nearby case — a new Premiumize state should read as unknown, not as
    /// "completed".
    @Test func anUnrecognizedStatusStaysUnknown() {
        #expect(PremiumizeProvider.state(from: "reticulating") == .unknown("reticulating"))
    }
}

/// Each service previews differently, and assuming otherwise emptied the
/// picker for every Premiumize result.
@Suite(.serialized, .usesStubURLProtocol) struct ProviderPreviewTests {
    private let hash = "d56eb90c12e1cd269f1bff2e62523b0f46bf390b"
    private let magnet = "magnet:?xt=urn:btih:d56eb90c12e1cd269f1bff2e62523b0f46bf390b"

    /// Premiumize's `/cache/check` returns no files by design, so a preview
    /// built on it always came back empty. `directdl` is its file list.
    @Test func premiumizePreviewsThroughDirectDLNotTheCacheCheck() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","content":[
          {"path":"Show.S01E04.mkv","size":1460000000,"link":"https://x/1"}]}
        """)])

        let provider = PremiumizeProvider(
            apiKey: Redacted("k"), client: HTTPClient(session: StubURLProtocol.makeSession()))
        let files = try await provider.previewFiles(rawMagnet: magnet, infoHashHex: hash)

        #expect(files?.count == 1)
        #expect(files?.first?.size == 1_460_000_000)

        let request = try #require(StubURLProtocol.recordedRequests().last)
        #expect(request.url?.path.hasSuffix("transfer/directdl") == true,
                "must not go through cache/check, which carries no files")
    }

    /// Real-Debrid genuinely cannot preview — nil is the honest answer, and
    /// the picker routes to Prepare on it.
    @Test func realDebridReportsNoPreviewWithoutAskingAnything() async throws {
        StubURLProtocol.reset([.json("{}")])

        let provider = RealDebridProvider(
            apiKey: Redacted("k"), client: HTTPClient(session: StubURLProtocol.makeSession()))
        let files = try await provider.previewFiles(rawMagnet: magnet, infoHashHex: hash)

        #expect(files == nil)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    /// TorBox keeps the default: its `checkCached(listFiles: true)` is exactly
    /// the shape the protocol's default implementation expects.
    @Test func torBoxPreviewsThroughItsCacheCheck() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"data":{"d56eb90c12e1cd269f1bff2e62523b0f46bf390b":
          {"hash":"d56eb90c12e1cd269f1bff2e62523b0f46bf390b","name":"Show","size":1460000000,
           "files":[{"id":1,"name":"Show.S01E04.mkv","short_name":"Show.S01E04.mkv",
                     "size":1460000000,"mimetype":"video/x-matroska"}]}}}
        """)])

        let provider = TorBoxProvider(
            apiKey: Redacted("k"), client: HTTPClient(session: StubURLProtocol.makeSession()))
        let files = try await provider.previewFiles(rawMagnet: magnet, infoHashHex: hash)

        #expect(files?.count == 1)
        #expect(files?.first?.shortName == "Show.S01E04.mkv")
    }

    /// A cached hit with an empty file list is nil, not an empty array — the
    /// caller must be able to tell "no preview" from "a torrent with no files".
    @Test func anEmptyFileListReadsAsNoPreview() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"data":{"d56eb90c12e1cd269f1bff2e62523b0f46bf390b":
          {"hash":"d56eb90c12e1cd269f1bff2e62523b0f46bf390b","name":"X","size":10,"files":[]}}}
        """)])

        let provider = TorBoxProvider(
            apiKey: Redacted("k"), client: HTTPClient(session: StubURLProtocol.makeSession()))
        #expect(try await provider.previewFiles(rawMagnet: magnet, infoHashHex: hash) == nil)
    }
}

/// A finished Premiumize transfer has to report its files.
///
/// `torrent(id:)` mapped a present `folder_id` to an *empty* array — always —
/// so a Premiumize torrent reported no files however finished it was. Since
/// `DebridTorrent.isReady` requires a non-empty list, the poll never ended:
/// the row sat preparing for good and nothing was ever queued, while
/// Premiumize had long since finished. The list was one call away.
@Suite(.serialized, .usesStubURLProtocol) struct PremiumizeReadinessTests {
    private func provider() -> PremiumizeProvider {
        PremiumizeProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private let finished = """
    {"status":"success","transfers":[
      {"id":"t-1","name":"Album","status":"finished","progress":1,"folder_id":"f-9"}]}
    """
    private let folder = """
    {"status":"success","content":[
      {"id":"file-1","name":"01.flac","size":100,"type":"file"},
      {"id":"file-2","name":"02.flac","size":200,"type":"file"}]}
    """

    @Test func aFinishedTransferReportsItsFilesAndIsReady() async throws {
        StubURLProtocol.reset([.json(finished), .json(folder)])

        let torrent = try await provider().torrent(id: DebridTorrentID(rawValue: "t-1"))

        #expect(torrent.files.count == 2)
        #expect(torrent.isReady, "the poll would never end")
    }

    /// A transfer still running has no folder to list, and asking anyway would
    /// be a round trip per poll for an answer that is not ready.
    @Test func aRunningTransferIsNotReadyAndAsksForNoFolder() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","transfers":[
          {"id":"t-1","name":"Album","status":"running","progress":0.4}]}
        """)])

        let torrent = try await provider().torrent(id: DebridTorrentID(rawValue: "t-1"))

        #expect(!torrent.isReady)
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }
}

/// The two shapes a finished Premiumize transfer actually takes.
///
/// Both reported no files at all, which the engine reads as "not ready yet" —
/// so the row polled for ever and, once that became a reported failure, said
/// "ready but lists no files".
@Suite(.serialized, .usesStubURLProtocol) struct PremiumizeFileShapesTests {
    private func provider() -> PremiumizeProvider {
        PremiumizeProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    /// The commonest shape there is — a book, one track. Premiumize sets
    /// `file_id` and leaves `folder_id` nil, and `file_id` was decoded and
    /// never read.
    @Test func aSingleFileTransferReportsItsOneFile() async throws {
        StubURLProtocol.reset([
            .json("""
            {"status":"success","transfers":[
              {"id":"t-1","name":"Book","status":"finished","progress":1,"file_id":"f-1"}]}
            """),
            .json(#"{"status":"success","name":"HEATED RIVALRY.epub","size":900}"#),
        ])

        let torrent = try await provider().torrent(id: DebridTorrentID(rawValue: "t-1"))

        #expect(torrent.files.map(\.name) == ["HEATED RIVALRY.epub"])
        #expect(torrent.isReady)
    }

    /// A torrent with directories listed only its subfolders, filtered them
    /// out for not being files, and returned nothing.
    @Test func nestedFoldersAreDescendedIntoWithTheirPaths() async throws {
        StubURLProtocol.reset(handler: { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("transfer/list") {
                return .json("""
                {"status":"success","transfers":[
                  {"id":"t-2","name":"Show","status":"finished","progress":1,"folder_id":"root"}]}
                """)
            }
            if url.contains("id=root") {
                return .json("""
                {"status":"success","content":[
                  {"id":"s1","name":"Season 1","type":"folder"}]}
                """)
            }
            return .json("""
            {"status":"success","content":[
              {"id":"e1","name":"S01E01.mkv","size":10,"type":"file"},
              {"id":"e2","name":"S01E02.mkv","size":20,"type":"file"}]}
            """)
        })

        let torrent = try await provider().torrent(id: DebridTorrentID(rawValue: "t-2"))

        // Paths, not bare names: the selection the user made was against a
        // list that carries folders, and a bare filename matches none of it.
        #expect(torrent.files.map(\.name) == ["Season 1/S01E01.mkv", "Season 1/S01E02.mkv"])
        #expect(torrent.isReady)
    }
}

/// A refusal to preview is an answer, not a failure.
@Suite(.serialized, .usesStubURLProtocol) struct PremiumizePreviewRefusalTests {
    private func provider() -> PremiumizeProvider {
        PremiumizeProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    /// Premiumize says this for a magnet it does not already hold. It is not
    /// an error — it is the service saying it cannot list a torrent it has not
    /// got — and rethrowing it put that sentence on screen in place of the
    /// file picker, when the caller has the torrent's own metadata to fall
    /// back on.
    @Test func anUnsupportedLinkMeansNoPreviewRatherThanAnError() async throws {
        StubURLProtocol.reset([
            .json(#"{"status":"error","message":"Unsupported link for direct download."}"#),
        ])

        let preview = try await provider().previewFiles(
            rawMagnet: "magnet:?xt=urn:btih:aa", infoHashHex: "aa")

        #expect(preview == nil)
    }

    /// A bad key is the user's to fix and must not be downgraded to "no
    /// preview available".
    @Test func anUnauthorizedResponseStillPropagates() async throws {
        StubURLProtocol.reset([.init(status: 401, body: Data())])

        await #expect(throws: DebridError.unauthorized) {
            _ = try await self.provider().previewFiles(
                rawMagnet: "magnet:?xt=urn:btih:aa", infoHashHex: "aa")
        }
    }
}
