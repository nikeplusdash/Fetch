import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct TorBoxTransferTests {
    static let hash = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"

    private func makeProvider() -> TorBoxProvider {
        TorBoxProvider(
            apiKey: Redacted("test-key"),
            client: HTTPClient(
                session: StubURLProtocol.makeSession(),
                policy: RetryPolicy(maxAttempts: 1),
                clock: TestClock()
            )
        )
    }

    @Test func submitMagnetReturnsTorrentID() async throws {
        StubURLProtocol.reset([
            .json(#"{"success":true,"detail":"queued","data":{"torrent_id":8842,"hash":"abc"}}"#)
        ])
        let id = try await makeProvider()
            .submitMagnet(rawMagnet: "magnet:?xt=urn:btih:\(Self.hash)")
        #expect(id == DebridTorrentID(rawValue: "8842"))
        #expect(StubURLProtocol.recordedRequests().first?.httpMethod == "POST")
    }

    @Test func submitMagnetRejectionSurfacesDetail() async {
        StubURLProtocol.reset([
            .json(#"{"success":false,"detail":"Active limit reached","data":null}"#)
        ])
        await #expect(throws: DebridError.providerRejected(detail: "Active limit reached")) {
            _ = try await makeProvider().submitMagnet(rawMagnet: "magnet:?xt=urn:btih:\(Self.hash)")
        }
    }

    @Test func torrentDecodesStateProgressAndFiles() async throws {
        // Shape verified against the live API: data is a single object.
        let json = """
        {"success":true,"data":{"id":8842,"hash":"\(Self.hash)","name":"Big Buck Bunny",
        "size":355856562,"progress":1,"download_state":"cached","download_finished":true,
        "download_present":true,"seeds":12,"download_speed":0,"eta":0,
        "files":[{"id":0,"name":"BBB/bbb.mp4","short_name":"bbb.mp4",
        "size":355856562,"mimetype":"video/mp4"}]}}
        """
        StubURLProtocol.reset([.json(json)])

        let torrent = try await makeProvider().torrent(id: DebridTorrentID(rawValue: "8842"))
        #expect(torrent.state == .completed)
        #expect(torrent.progress == 1)
        #expect(torrent.files.count == 1)
        #expect(torrent.files[0].name == "BBB/bbb.mp4")
        #expect(torrent.seeds == 12)
    }

    @Test func torrentPollingSendsBypassCache() async throws {
        StubURLProtocol.reset([.json(#"{"success":true,"data":{"id":1,"files":[]}}"#)])
        _ = try? await makeProvider().torrent(id: DebridTorrentID(rawValue: "1"))

        let query = try #require(StubURLProtocol.recordedRequests().first?.url?.query)
        #expect(query.contains("bypass_cache=true"))
        #expect(query.contains("id=1"))
    }

    /// A nonexistent id answers HTTP 500 with success:false — verified
    /// against the live API. It is not a 404 and not a 200-with-empty-data.
    @Test func missingTorrentThrowsFileNotFound() async {
        StubURLProtocol.reset([.json(
            #"{"success":false,"error":"DATABASE_ERROR","detail":"error","data":null}"#,
            status: 500)])
        await #expect(throws: DebridError.fileNotFound) {
            _ = try await makeProvider().torrent(id: DebridTorrentID(rawValue: "999"))
        }
    }

    @Test func unknownDownloadStateDoesNotTrap() async throws {
        let json = """
        {"success":true,"data":{"id":1,"hash":"\(Self.hash)","name":"x","size":1,
        "progress":0.5,"download_state":"some_new_state","files":[]}}
        """
        StubURLProtocol.reset([.json(json)])
        let torrent = try await makeProvider().torrent(id: DebridTorrentID(rawValue: "1"))
        #expect(torrent.state == .unknown("some_new_state"))
    }

    @Test func downloadURLUsesTokenQueryParamNotBearer() async throws {
        StubURLProtocol.reset([
            .json(#"{"success":true,"data":"https://cdn.torbox.app/abc/bbb.mp4"}"#)
        ])
        let url = try await makeProvider().downloadURL(
            torrent: DebridTorrentID(rawValue: "8842"),
            file: DebridFileID(rawValue: "0")
        )
        #expect(url.absoluteString == "https://cdn.torbox.app/abc/bbb.mp4")

        let request = try #require(StubURLProtocol.recordedRequests().first)
        let query = try #require(request.url?.query)
        #expect(query.contains("token=test-key"))
        #expect(query.contains("torrent_id=8842"))
        #expect(query.contains("file_id=0"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func validateCredentialsReturnsAccount() async throws {
        StubURLProtocol.reset([
            .json(#"{"success":true,"data":{"email":"a@b.c","plan":2,"premium_expires_at":null}}"#)
        ])
        let account = try await makeProvider().validateCredentials()
        #expect(account.email == "a@b.c")
    }

    @Test func unauthorizedMapsToUnauthorizedError() async {
        StubURLProtocol.reset([.json(#"{"detail":"bad"}"#, status: 401)])
        await #expect(throws: DebridError.unauthorized) {
            _ = try await makeProvider().validateCredentials()
        }
    }

    /// TorBox answers 200 with success:false for a rejected delete (e.g. a
    /// stale or invalid torrent_id). `sendRaw` alone would silently discard
    /// that and report the delete as successful.
    @Test func deleteRejectionThrowsProviderRejected() async {
        StubURLProtocol.reset([
            .json(#"{"success":false,"error":"NOT_FOUND","detail":"torrent not found","data":null}"#)
        ])
        await #expect(throws: DebridError.providerRejected(detail: "NOT_FOUND")) {
            try await makeProvider().delete(torrent: DebridTorrentID(rawValue: "1"))
        }
    }

    @Test func deleteSuccessPostsControlTorrentAndReturns() async throws {
        StubURLProtocol.reset([.json(#"{"success":true,"detail":"deleted","data":null}"#)])
        try await makeProvider().delete(torrent: DebridTorrentID(rawValue: "1"))
        #expect(StubURLProtocol.recordedRequests().first?.httpMethod == "POST")
    }

    /// A nonexistent id verifiably answers 500. 502/503/504 mean an outage on
    /// a torrent that still exists — conflating them with fileNotFound would
    /// make a poller drop a live download during a transient outage.
    @Test func serviceOutageDoesNotMapToFileNotFound() async {
        StubURLProtocol.reset([.json(
            #"{"success":false,"error":"SERVICE_UNAVAILABLE","detail":"down","data":null}"#,
            status: 503)])
        await #expect(throws: DebridError.network("http(503)")) {
            _ = try await makeProvider().torrent(id: DebridTorrentID(rawValue: "1"))
        }
    }
}
