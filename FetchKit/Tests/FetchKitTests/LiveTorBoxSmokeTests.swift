import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Hits the real TorBox API. Skips silently unless FETCH_TORBOX_API_KEY is set,
/// so CI and normal `swift test` runs stay hermetic and no key lands in the repo.
@Suite(.serialized) struct LiveTorBoxSmokeTests {
    static var apiKey: String? {
        ProcessInfo.processInfo.environment["FETCH_TORBOX_API_KEY"]
    }

    private func makeProvider(_ key: String) -> TorBoxProvider {
        TorBoxProvider(apiKey: Redacted(key), client: HTTPClient())
    }

    @Test(.enabled(if: LiveTorBoxSmokeTests.apiKey != nil))
    func liveAccountValidates() async throws {
        let account = try await makeProvider(Self.apiKey!).validateCredentials()
        #expect(account.email != nil)
        print("LIVE account: plan=\(account.plan ?? "?") expires=\(String(describing: account.expiresAt))")
    }

    @Test(.enabled(if: LiveTorBoxSmokeTests.apiKey != nil))
    func liveCacheCheckIsTotalOverInput() async throws {
        let cached = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"   // Big Buck Bunny
        let bogus  = "0000000000000000000000000000000000000001"
        let result = try await makeProvider(Self.apiKey!).checkCached(
            hashes: [cached, bogus], listFiles: true)
        #expect(result.count == 2)                       // total function
        #expect(result[bogus]?.size == 0)                // filled-in miss
        print("LIVE cache: bbb.size=\(result[cached]?.size ?? -1) files=\(result[cached]?.files?.count ?? -1)")
    }

    /// The shape that a stub cannot prove: mylist?id= returns a SINGLE object.
    @Test(.enabled(if: LiveTorBoxSmokeTests.apiKey != nil))
    func liveTorrentByIdDecodesSingleObject() async throws {
        let key = Self.apiKey!
        let provider = makeProvider(key)
        let endpoint = Endpoint(
            baseURL: TorBoxProvider.defaultBaseURL,
            path: "/v1/api/torrents/mylist",
            queryItems: [URLQueryItem(name: "bypass_cache", value: "true")],
            headers: ["Authorization": "Bearer \(key)"])
        let all = try await HTTPClient().send(endpoint, as: TorBoxEnvelope<[TorBoxTorrentProbe]>.self)
        guard let first = all.data?.first else { return }

        let torrent = try await provider.torrent(id: DebridTorrentID(rawValue: String(first.id)))
        #expect(torrent.id.rawValue == String(first.id))
        #expect(!torrent.name.isEmpty)
        print("LIVE torrent: state=\(torrent.state) files=\(torrent.files.count) progress=\(torrent.progress)")

        if let file = torrent.files.first {
            let url = try await provider.downloadURL(torrent: torrent.id, file: file.id)
            #expect(url.scheme == "https")
            print("LIVE requestdl host=\(url.host() ?? "?")  (url withheld: carries token)")
        }
    }

    @Test(.enabled(if: LiveTorBoxSmokeTests.apiKey != nil))
    func liveMissingTorrentMapsToFileNotFound() async throws {
        await #expect(throws: DebridError.fileNotFound) {
            _ = try await makeProvider(Self.apiKey!).torrent(id: DebridTorrentID(rawValue: "999999999"))
        }
    }
}

struct TorBoxTorrentProbe: Decodable, Sendable { let id: Int }
