import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stage 7e §3.7. The three providers' web-download implementations.
///
/// Only TorBox is verifiable against a live service here; Premiumize and
/// Real-Debrid are stub-driven, like the rest of their coverage. What these
/// pin is the *shape* — especially the one place the three genuinely differ.
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

    // MARK: - TorBox: supported hosts

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

    /// A host the service reports as down arrives with `isActive: false`
    /// rather than being dropped: "MediaFire, reported down" is a different
    /// message from "unsupported host", and the user can act on the first.
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

    // MARK: - TorBox: submit and poll

    @Test func torboxSubmittingALinkReturnsTheDownloadID() async throws {
        StubURLProtocol.reset([.json("""
        {"success":true,"detail":"ok","data":{"webdownload_id":"4821","hash":"abc"}}
        """)])

        let id = try await torbox().submitLink(URL(string: "https://mediafire.com/file/x")!)
        #expect(id == DebridDownloadID(rawValue: "4821"))
    }

    /// TorBox answers HTTP 200 with `success: false` for real failures — the
    /// same trap the torrent path already guards.
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

    /// An id the service does not know is `fileNotFound`, not an empty
    /// download that would poll forever reporting 0%.
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

    // MARK: - Real-Debrid: the synchronous one

    /// **The asymmetry worth pinning.** RD's `/unrestrict/link` is
    /// synchronous: one POST returns the final link. Polling it would wait
    /// for something that finished before the first poll.
    @Test func realDebridDoesNotNeedPreparing() {
        #expect(!realDebrid().hostedLinksNeedPreparing)
    }

    /// Submitting validates the link against the service — so an unsupported
    /// host or a dead link fails *now*, with a real message, rather than
    /// becoming a queued download that never starts.
    @Test func realDebridSubmitValidatesTheLink() async throws {
        StubURLProtocol.reset([.json(unrestricted)])

        let id = try await realDebrid().submitLink(
            URL(string: "https://rapidgator.net/file/x")!)

        #expect(!StubURLProtocol.recordedRequests().isEmpty)
        // The handle is the hoster link, not the CDN URL: §6 forbids
        // persisting the latter, and it expires anyway.
        #expect(id.rawValue == "https://rapidgator.net/file/x")
    }

    /// **There is nothing to poll.** RD has no queue, so `webDownload`
    /// reports completed and makes no request at all — asserted on the
    /// recorded requests rather than inferred, because "it seemed fast" is
    /// not evidence.
    @Test func realDebridPollingMakesNoRequest() async throws {
        StubURLProtocol.reset([])

        let web = try await realDebrid().webDownload(
            id: DebridDownloadID(rawValue: "https://rapidgator.net/file/movie.mkv"))

        #expect(web.state == .completed)
        #expect(web.progress == 1.0)
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    /// The link is unrestricted at fetch time, so the CDN URL is fresh every
    /// time and never stored — the same rule the torrent path follows.
    @Test func realDebridResolvesTheLinkWhenAsked() async throws {
        StubURLProtocol.reset([.json(unrestricted)])

        let url = try await realDebrid().downloadURL(
            web: DebridDownloadID(rawValue: "https://rapidgator.net/file/x"))

        #expect(url.host() == "cdn.real-debrid.com")
    }

    // MARK: - Premiumize: also synchronous

    private func premiumize() -> PremiumizeProvider {
        PremiumizeProvider(
            apiKey: Redacted("test-token"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    /// `/services/list` reports coverage as a bare array of domains under
    /// `directdl` — no per-host id and no up/down flag.
    @Test func premiumizeReportsItsDirectDownloadDomains() async throws {
        StubURLProtocol.reset([.json("""
        {"directdl":["mediafire.com","1fichier.com"],"cache":["mediafire.com"]}
        """)])

        let hosts = try await premiumize().supportedHosts()

        #expect(hosts.map(\.id.rawValue).sorted() == ["1fichier", "mediafire"])
        #expect(hosts.first { $0.id == HostID(rawValue: "mediafire") }?
            .matches(URL(string: "https://www.mediafire.com/file/x")!) == true)
    }

    /// A shape Fetch does not recognise yields no hosts rather than throwing.
    /// Premiumize is unverified against the live service, so the failure mode
    /// that matters is the designed one: report nothing, never win routing,
    /// stay invisible — not take the whole paste sheet down.
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

    /// `status: error` on HTTP 200 is Premiumize's failure shape, the same
    /// trap as TorBox's `success: false`.
    @Test func premiumizeReportsAnErrorStatusAsAnError() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"error","message":"unsupported host"}
        """)])

        await #expect(throws: DebridError.self) {
            try await premiumize().downloadURL(
                web: DebridDownloadID(rawValue: "https://x.com/y"))
        }
    }

    /// Premiumize had no `submitLink` test at all — RD had two, Premiumize
    /// none — which meant the "validate now, not later" rule was only half
    /// covered even though both providers depend on it.
    @Test func premiumizeSubmitValidatesTheLink() async throws {
        StubURLProtocol.reset([.json(directDL)])

        let id = try await premiumize().submitLink(
            URL(string: "https://mediafire.com/file/x")!)

        #expect(!StubURLProtocol.recordedRequests().isEmpty)
        // The handle is the hoster link, not the CDN URL — same rule as RD.
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

    // MARK: - Dispatch through the existential

    /// Every other test in this file calls a *concrete* provider, which
    /// resolves `SynchronousHostedLinks`' members statically and would keep
    /// passing even if the conformance stopped being found. The engine holds
    /// `any DebridProvider`, where the witness is looked up at runtime — and
    /// `DebridProvider` supplies competing defaults that throw
    /// `unsupportedOperation` and return `hostedLinksNeedPreparing == true`.
    ///
    /// So without these, a resolution regression would silently break every
    /// hosted download for RD and Premiumize with a fully green suite.
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

    /// TorBox must **not** pick up the synchronous behaviour: it has a real
    /// queue, and reporting `needsPreparing == false` would have the engine
    /// fetch a URL for a download that has not been prepared yet.
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
