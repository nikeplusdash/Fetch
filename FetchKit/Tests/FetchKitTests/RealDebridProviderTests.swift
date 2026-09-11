import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct RealDebridProviderTests {
    private func makeProvider() -> RealDebridProvider {
        RealDebridProvider(
            apiKey: Redacted("test-token"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private let hashA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"


    @Test func realDebridReportsReadinessFromItsAccountListing() async throws {
        #expect(makeProvider().canReportCacheStatus)

        StubURLProtocol.reset([.json("[]")])
        _ = try await makeProvider().checkCached(hashes: ["aaaa"], listFiles: false)

        let asked = try #require(StubURLProtocol.recordedRequests().first?.url)
        #expect(asked.path.hasSuffix("/torrents"))
    }


    @Test func addingAMagnetAlsoSelectsFiles() async throws {
        StubURLProtocol.reset([
            .json(#"{"id":"rd-1","uri":"https://real-debrid.com/t/rd-1"}"#),
            .json("", status: 204),
        ])

        let id = try await makeProvider().submitMagnet(rawMagnet: "magnet:?xt=urn:btih:\(hashA)")
        #expect(id.rawValue == "rd-1")

        let requests = StubURLProtocol.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path.hasSuffix("torrents/addMagnet") == true)
        #expect(requests[1].url?.path.hasSuffix("torrents/selectFiles/rd-1") == true)

        let body = try #require(StubURLProtocol.recordedBody(at: 1).map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("files=all"))
    }

    @Test func selectingASubsetSendsTheFileIDs() async throws {
        StubURLProtocol.reset([.json("", status: 204)])

        try await makeProvider().selectFiles(
            torrent: DebridTorrentID(rawValue: "rd-1"),
            fileIDs: [DebridFileID(rawValue: "2"), DebridFileID(rawValue: "5")])

        let request = try #require(StubURLProtocol.recordedRequests().last)
        let body = try #require(StubURLProtocol.lastRecordedBody().map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("files=2%2C5") || body.contains("files=2,5"))
    }


    @Test func progressIsConvertedFromPercentToFraction() async throws {
        StubURLProtocol.reset([.json("""
        {"id":"rd-1","hash":"AAAA","filename":"Some.Release","bytes":1000,
         "progress":42.5,"status":"downloading","files":[],"links":[]}
        """)])

        let torrent = try await makeProvider().torrent(id: DebridTorrentID(rawValue: "rd-1"))
        #expect(torrent.progress == 0.425)
        #expect(torrent.state == .downloading)
        #expect(torrent.infoHashHex == "aaaa")
    }

    @Test func filesCarryTheirFullPathAndShortName() async throws {
        StubURLProtocol.reset([.json("""
        {"id":"rd-1","hash":"aa","filename":"Pack","bytes":300,"progress":100,
         "status":"downloaded",
         "files":[{"id":1,"path":"Pack/S01E01.mkv","bytes":100,"selected":1},
                  {"id":2,"path":"Pack/S01E02.mkv","bytes":200,"selected":1}],
         "links":["https://rd/1","https://rd/2"]}
        """)])

        let files = try await makeProvider().files(in: DebridTorrentID(rawValue: "rd-1"))
        #expect(files.map(\.name) == ["Pack/S01E01.mkv", "Pack/S01E02.mkv"])
        #expect(files.map(\.shortName) == ["S01E01.mkv", "S01E02.mkv"])
    }

    @Test func statusesMapOntoTheProtocolStates() {
        #expect(RealDebridProvider.state(from: "magnet_conversion") == .queued)
        #expect(RealDebridProvider.state(from: "waiting_files_selection") == .queued)
        #expect(RealDebridProvider.state(from: "downloading") == .downloading)
        #expect(RealDebridProvider.state(from: "downloaded") == .completed)
        #expect(RealDebridProvider.state(from: "virus") == .failed(reason: "virus"))
        #expect(RealDebridProvider.state(from: "something_new") == .unknown("something_new"))
    }


    @Test func theLinkForAFileIsFoundByItsPositionAmongSelectedFiles() async throws {
        let info = """
        {"id":"rd-1","hash":"aa","filename":"Pack","bytes":300,"progress":100,
         "status":"downloaded",
         "files":[{"id":1,"path":"Pack/A.mkv","bytes":100,"selected":1},
                  {"id":2,"path":"Pack/B.mkv","bytes":200,"selected":1}],
         "links":["https://rd/first","https://rd/second"]}
        """
        StubURLProtocol.reset([
            .json(info),
            .json(#"{"download":"https://direct.rd/second-file"}"#),
        ])

        let url = try await makeProvider().downloadURL(
            torrent: DebridTorrentID(rawValue: "rd-1"),
            file: DebridFileID(rawValue: "2"))

        #expect(url.absoluteString == "https://direct.rd/second-file")
        #expect(StubURLProtocol.recordedRequests().count == 2)

        let unrestrict = try #require(StubURLProtocol.recordedRequests().last)
        #expect(unrestrict.url?.path.hasSuffix("unrestrict/link") == true)
        let body = try #require(StubURLProtocol.lastRecordedBody().map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("second"))
    }

    @Test func aFileNotInTheTorrentIsNotFound() async throws {
        StubURLProtocol.reset([.json("""
        {"id":"rd-1","hash":"aa","filename":"Pack","bytes":100,"progress":100,
         "status":"downloaded",
         "files":[{"id":1,"path":"Pack/A.mkv","bytes":100,"selected":1}],
         "links":["https://rd/first"]}
        """)])

        await #expect(throws: DebridError.fileNotFound) {
            _ = try await makeProvider().downloadURL(
                torrent: DebridTorrentID(rawValue: "rd-1"),
                file: DebridFileID(rawValue: "99"))
        }
    }

    @Test func aRejectedTokenIsReportedAsUnauthorized() async throws {
        StubURLProtocol.reset([.json("{}", status: 401)])
        await #expect(throws: DebridError.unauthorized) {
            _ = try await makeProvider().validateCredentials()
        }
    }

    @Test func aFourOhFourFromRealDebridIsFileNotFound() async throws {
        StubURLProtocol.reset([.json("{}", status: 404)])
        await #expect(throws: DebridError.fileNotFound) {
            _ = try await makeProvider().validateCredentials()
        }
    }

    @Test func aServerErrorFromRealDebridIsNotFileNotFound() async throws {
        StubURLProtocol.reset([.json("{}", status: 500)])
        await #expect(throws: DebridError.self) {
            _ = try await makeProvider().validateCredentials()
        }
        StubURLProtocol.reset([.json("{}", status: 500)])
        do {
            _ = try await makeProvider().validateCredentials()
            Issue.record("expected a throw")
        } catch let error as DebridError {
            #expect(error != .fileNotFound)
        }
    }
}

@Suite(.serialized, .usesStubURLProtocol) struct RealDebridLinkPositionTests {
    private func provider() -> RealDebridProvider {
        RealDebridProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    @Test func aZeroByteFileDoesNotShiftEveryLinkAfterIt() async throws {
        let info = """
        {"id":"rd-1","status":"downloaded",
         "files":[{"id":1,"path":"Pack/marker.nfo","bytes":0,"selected":1},
                  {"id":2,"path":"Pack/A.mkv","bytes":100,"selected":1}],
         "links":["https://rd/marker","https://rd/movie"]}
        """
        StubURLProtocol.reset([
            .json(info),
            .json(#"{"download":"https://direct.rd/movie"}"#),
        ])

        _ = try await provider().downloadURL(
            torrent: DebridTorrentID(rawValue: "rd-1"),
            file: DebridFileID(rawValue: "2"))

        let body = try #require(StubURLProtocol.lastRecordedBody()
            .map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("movie"), "asked to unrestrict the wrong link")
    }

    @Test func aDeselectedFileIsNotCounted() async throws {
        let info = """
        {"id":"rd-1","status":"downloaded",
         "files":[{"id":1,"path":"Pack/skip.mkv","bytes":900,"selected":0},
                  {"id":2,"path":"Pack/A.mkv","bytes":100,"selected":1}],
         "links":["https://rd/movie"]}
        """
        StubURLProtocol.reset([
            .json(info),
            .json(#"{"download":"https://direct.rd/movie"}"#),
        ])

        _ = try await provider().downloadURL(
            torrent: DebridTorrentID(rawValue: "rd-1"),
            file: DebridFileID(rawValue: "2"))

        let body = try #require(StubURLProtocol.lastRecordedBody()
            .map { String(decoding: $0, as: UTF8.self) })
        #expect(body.contains("movie"))
    }
}

@Suite(.serialized, .usesStubURLProtocol) struct RealDebridAccountCacheTests {
    private func provider() -> RealDebridProvider {
        RealDebridProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private let mine = """
    [{"hash":"AAAA","filename":"Held","bytes":500,"status":"downloaded"},
     {"hash":"bbbb","filename":"Still going","bytes":900,"status":"downloading"}]
    """

    @Test func aFinishedTorrentOnTheAccountIsCached() async throws {
        StubURLProtocol.reset([.json(mine)])
        let result = try await provider().checkCached(hashes: ["aaaa"], listFiles: false)
        #expect(result["aaaa"]?.size == 500)
    }

    @Test func theComparisonIgnoresCase() async throws {
        StubURLProtocol.reset([.json(mine)])
        let result = try await provider().checkCached(hashes: ["AAAA"], listFiles: false)
        #expect((result["aaaa"]?.size ?? 0) > 0)
    }

    @Test func anUnfinishedTorrentIsNotCached() async throws {
        StubURLProtocol.reset([.json(mine)])
        let result = try await provider().checkCached(hashes: ["bbbb"], listFiles: false)
        #expect(result["bbbb"]?.size == 0)
    }

    @Test func everyHashAskedAboutIsAnswered() async throws {
        StubURLProtocol.reset([.json(mine)])
        let result = try await provider().checkCached(
            hashes: ["aaaa", "cccc", "dddd"], listFiles: false)
        #expect(Set(result.keys) == ["aaaa", "cccc", "dddd"])
    }

    @Test func aHeldTorrentWithNoSizeIsStillAHit() async throws {
        StubURLProtocol.reset([.json(#"[{"hash":"eeee","status":"downloaded"}]"#)])
        let result = try await provider().checkCached(hashes: ["eeee"], listFiles: false)
        #expect((result["eeee"]?.size ?? 0) > 0)
    }
}

@Suite(.serialized, .usesStubURLProtocol) struct RealDebridUnrestrictErrorTests {
    private func provider() -> RealDebridProvider {
        RealDebridProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    @Test func theServicesOwnReasonIsReported() async throws {
        StubURLProtocol.reset([
            .json(#"{"id":"t","status":"downloaded","files":[{"id":1,"path":"/a.m4a","bytes":9,"selected":1}],"links":["https://rd/one"]}"#),
            .json(#"{"error":"hoster_unavailable","error_code":23}"#),
        ])

        await #expect(throws: DebridError.providerRejected(detail: "hoster_unavailable (23)")) {
            _ = try await self.provider().downloadURL(
                torrent: DebridTorrentID(rawValue: "t"), file: DebridFileID(rawValue: "1"))
        }
    }

    @Test func aSilentRefusalKeepsTheOldWording() async throws {
        StubURLProtocol.reset([
            .json(#"{"id":"t","status":"downloaded","files":[{"id":1,"path":"/a.m4a","bytes":9,"selected":1}],"links":["https://rd/one"]}"#),
            .json("{}"),
        ])

        await #expect(throws: DebridError.providerRejected(detail: "no link returned")) {
            _ = try await self.provider().downloadURL(
                torrent: DebridTorrentID(rawValue: "t"), file: DebridFileID(rawValue: "1"))
        }
    }
}
