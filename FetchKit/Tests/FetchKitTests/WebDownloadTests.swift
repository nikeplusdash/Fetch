import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct WebDownloadTests {
    private func torbox() -> TorBoxProvider {
        TorBoxProvider(
            apiKey: Redacted("test-token"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private func realDebrid() -> RealDebridProvider {
        RealDebridProvider(
            apiKey: Redacted("test-token"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }


    private let hostersJSON = """
    {"success":true,"detail":"ok","data":[
      {"name":"mediafire","domains":["mediafire.com"],"status":true},
      {"name":"1fichier","domains":["1fichier.com","alterupload.com"],"status":true},
      {"name":"rapidgator","domains":["rapidgator.net"],"status":false}
    ]}
    """

    @Test func torboxReportsItsSupportedHosts() async throws {
        StubURLProtocol.reset([.json(hostersJSON)])
        let hosts = try await torbox().supportedHosts()

        #expect(hosts.count == 3)
        #expect(hosts.first?.id == HostID(rawValue: "mediafire"))
    }

    @Test func aHostReportedDownIsCarriedNotDropped() async throws {
        StubURLProtocol.reset([.json(hostersJSON)])
        let hosts = try await torbox().supportedHosts()

        let rapidgator = hosts.first { $0.id == HostID(rawValue: "rapidgator") }
        #expect(rapidgator != nil)
        #expect(rapidgator?.isActive == false)
    }

    @Test func aHostsSeveralDomainsAreAllCarried() async throws {
        StubURLProtocol.reset([.json(hostersJSON)])
        let hosts = try await torbox().supportedHosts()

        let fichier = hosts.first { $0.id == HostID(rawValue: "1fichier") }
        #expect(fichier?.domains.count == 2)
        #expect(fichier?.matches(URL(string: "https://alterupload.com/x")!) == true)
    }


    @Test func torboxSubmittingALinkReturnsTheDownloadID() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"detail":"ok","data":{"webdownload_id":"4821","hash":"abc"}}
        """)])

        let id = try await torbox().submitLink(URL(string: "https://mediafire.com/file/x")!)
        #expect(id == DebridDownloadID(rawValue: "4821"))
    }

    @Test func torboxReportsASuccessFalseBodyAsAnError() async throws {
        StubURLProtocol.reset([.json("""
        {"success":false,"detail":"host not supported","data":null}
        """)])

        await #expect(throws: DebridError.self) {
            try await torbox().submitLink(URL(string: "https://x.com/y")!)
        }
    }

    @Test func torboxPollingReportsProgressAndState() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"detail":"ok","data":[
          {"id":4821,"name":"movie.mkv","size":1048576,"progress":0.5,
           "download_state":"downloading","files":[]}
        ]}
        """)])

        let web = try await torbox().webDownload(id: DebridDownloadID(rawValue: "4821"))
        #expect(web.name == "movie.mkv")
        #expect(web.size == 1_048_576)
        #expect(web.progress == 0.5)
        #expect(web.state == .downloading)
    }

    @Test func torboxAnUnknownDownloadIDIsFileNotFound() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"detail":"ok","data":[]}
        """)])

        await #expect(throws: DebridError.fileNotFound) {
            try await torbox().webDownload(id: DebridDownloadID(rawValue: "9999"))
        }
    }

    @Test func torboxResolvesAFreshDownloadURL() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"detail":"ok","data":"https://cdn.torbox.app/x/movie.mkv?token=abc"}
        """)])

        let url = try await torbox().downloadURL(web: DebridDownloadID(rawValue: "4821"))
        #expect(url.host() == "cdn.torbox.app")
    }

    @Test func torboxWebDownloadsArePolled() {
        #expect(torbox().hostedLinksNeedPreparing)
    }


    @Test func realDebridDoesNotNeedPreparing() {
        #expect(!realDebrid().hostedLinksNeedPreparing)
    }

    @Test func realDebridSubmitValidatesTheLink() async throws {
        StubURLProtocol.reset([.json(unrestricted)])

        let id = try await realDebrid().submitLink(
            URL(string: "https://rapidgator.net/file/x")!)

        #expect(!StubURLProtocol.recordedRequests().isEmpty)
        #expect(id.rawValue == "https://rapidgator.net/file/x")
    }

    @Test func realDebridPollingMakesNoRequest() async throws {
        StubURLProtocol.reset([])

        let web = try await realDebrid().webDownload(
            id: DebridDownloadID(rawValue: "https://rapidgator.net/file/movie.mkv"))

        #expect(web.state == .completed)
        #expect(web.progress == 1.0)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    @Test func realDebridResolvesTheLinkWhenAsked() async throws {
        StubURLProtocol.reset([.json(unrestricted)])

        let url = try await realDebrid().downloadURL(
            web: DebridDownloadID(rawValue: "https://rapidgator.net/file/x"))

        #expect(url.host() == "cdn.real-debrid.com")
    }


    private func premiumize() -> PremiumizeProvider {
        PremiumizeProvider(
            apiKey: Redacted("test-token"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    @Test func premiumizeReportsItsDirectDownloadDomains() async throws {
        StubURLProtocol.reset([.json("""
        {"directdl":["mediafire.com","1fichier.com"],"cache":["mediafire.com"]}
        """)])

        let hosts = try await premiumize().supportedHosts()

        #expect(hosts.map(\.id.rawValue).sorted() == ["1fichier", "mediafire"])
        #expect(hosts.first { $0.id == HostID(rawValue: "mediafire") }?
            .matches(URL(string: "https://www.mediafire.com/file/x")!) == true)
    }

    @Test func premiumizeAnUnexpectedShapeYieldsNoHosts() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success"}
        """)])

        #expect(try await premiumize().supportedHosts().isEmpty)
    }

    @Test func premiumizeDoesNotNeedPreparing() {
        #expect(!premiumize().hostedLinksNeedPreparing)
    }

    @Test func premiumizeResolvesTheLinkWhenAsked() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","content":[
          {"path":"movie.mkv","size":2048,
           "link":"https://cdn.premiumize.me/dl/abc/movie.mkv"}]}
        """)])

        let url = try await premiumize().downloadURL(
            web: DebridDownloadID(rawValue: "https://mediafire.com/file/x"))

        #expect(url.host() == "cdn.premiumize.me")
    }

    @Test func premiumizeReportsAnErrorStatusAsAnError() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"error","message":"unsupported host"}
        """)])

        await #expect(throws: DebridError.self) {
            try await premiumize().downloadURL(
                web: DebridDownloadID(rawValue: "https://x.com/y"))
        }
    }

    @Test func premiumizeSubmitValidatesTheLink() async throws {
        StubURLProtocol.reset([.json(directDL)])

        let id = try await premiumize().submitLink(
            URL(string: "https://mediafire.com/file/x")!)

        #expect(!StubURLProtocol.recordedRequests().isEmpty)
        #expect(id.rawValue == "https://mediafire.com/file/x")
    }

    @Test func premiumizePollingMakesNoRequest() async throws {
        StubURLProtocol.reset([])

        let web = try await premiumize().webDownload(
            id: DebridDownloadID(rawValue: "https://mediafire.com/file/movie.mkv"))

        #expect(web.state == .completed)
        #expect(web.progress == 1.0)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }


    @Test func realDebridDispatchesThroughTheProtocol() async throws {
        let provider: any DebridProvider = realDebrid()
        #expect(!provider.hostedLinksNeedPreparing)

        StubURLProtocol.reset([.json(unrestricted)])
        let url = try await provider.downloadURL(
            web: DebridDownloadID(rawValue: "https://rapidgator.net/file/x"))
        #expect(url.host() == "cdn.real-debrid.com")
    }

    @Test func premiumizeDispatchesThroughTheProtocol() async throws {
        let provider: any DebridProvider = premiumize()
        #expect(!provider.hostedLinksNeedPreparing)

        StubURLProtocol.reset([.json(directDL)])
        let url = try await provider.downloadURL(
            web: DebridDownloadID(rawValue: "https://mediafire.com/file/x"))
        #expect(url.host() == "cdn.premiumize.me")
    }

    @Test func torboxStillNeedsPreparing() {
        let provider: any DebridProvider = torbox()
        #expect(provider.hostedLinksNeedPreparing)
    }

    private let unrestricted = """
    {"id":"XYZ123","filename":"movie.mkv","filesize":2048,
     "link":"https://rapidgator.net/file/x",
     "download":"https://cdn.real-debrid.com/d/XYZ123/movie.mkv"}
    """

    private let directDL = """
    {"status":"success","content":[
      {"path":"movie.mkv","size":2048,
       "link":"https://cdn.premiumize.me/d/XYZ123/movie.mkv"}]}
    """
}
