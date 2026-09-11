import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite("Cloud playback tokens")
struct CloudPlaybackTokenTests {
    @Test("a token round-trips through its encoded string")
    func roundTrip() {
        let token = CloudPlaybackToken(
            provider: DebridProviderID(rawValue: "rd"),
            origin: .torrent(DebridTorrentID(rawValue: "id:with/awkward:chars")),
            file: DebridFileID(rawValue: "file/7"))

        #expect(CloudPlaybackToken(encoded: token.encoded()) == token)
    }

    @Test("a web origin round-trips too, and is not confused for a torrent")
    func webRoundTrips() {
        let web = CloudPlaybackToken(
            provider: DebridProviderID(rawValue: "pm"),
            origin: .web(DebridDownloadID(rawValue: "7")),
            file: DebridFileID(rawValue: "7"))
        let torrent = CloudPlaybackToken(
            provider: DebridProviderID(rawValue: "pm"),
            origin: .torrent(DebridTorrentID(rawValue: "7")),
            file: DebridFileID(rawValue: "7"))

        #expect(CloudPlaybackToken(encoded: web.encoded()) == web)
        #expect(web.encoded() != torrent.encoded())
    }

    @Test("garbage decodes to nil rather than trapping")
    func rejectsGarbage() {
        #expect(CloudPlaybackToken(encoded: "not base64 !!!") == nil)
        #expect(CloudPlaybackToken(encoded: "") == nil)
    }

    @Test("base64 of something that is not a token is also nil")
    func rejectsWellFormedNonsense() {
        let base64 = Data("{\"hello\":true}".utf8).base64EncodedString()

        #expect(CloudPlaybackToken(encoded: base64) == nil)
    }

    /**
     The join spec §7 asks for: tokens built the way the Cloud screen builds
     them, run through the plan, with one link refused. Until this feature
     every cloud item was handed an empty `resolved:` map and dropped, so
     this is the first assertion that the path carries anything at all.
     */
    @Test("a half-resolved cloud playlist plays what it can and names what it cannot")
    func aPartialCloudPlaylistPlays() {
        let item = DebridCloudItem(
            provider: DebridProviderID(rawValue: "rd"),
            origin: .torrent(DebridTorrentID(rawValue: "1")),
            name: "Show", size: 0, infoHashHex: nil, addedAt: nil,
            files: ["Show/ep1.mkv", "Show/ep2.mkv", "Show/ep3.mkv"].map {
                DebridFile(
                    id: DebridFileID(rawValue: $0), name: $0,
                    shortName: ($0 as NSString).lastPathComponent, size: 1, mimeType: nil)
            })

        let candidates = item.files.map { file in
            PlaylistCandidate(
                path: file.name,
                source: .cloud(token: CloudPlaybackToken(
                    provider: item.provider, origin: item.origin, file: file.id).encoded()))
        }
        let items = PlaylistPlan.items(from: candidates)
        #expect(items.count == 3)

        var resolved: [String: URL] = [:]
        for (index, candidate) in candidates.enumerated() where index != 1 {
            guard case .cloud(let token) = candidate.source else { continue }
            resolved[token] = URL(string: "https://example.com/\(index)")!
        }

        let resolution = PlaylistPlan.resolution(for: items, resolved: resolved)
        #expect(resolution.urls.count == 2)
        #expect(resolution.missing == ["ep2.mkv"])
        #expect(resolution.opens)
        #expect(resolution.notice?.contains("Playing 2 of 3") == true)
    }

    @Test("two files of one torrent get different tokens")
    func tokensArePerFile() {
        let provider = DebridProviderID(rawValue: "rd")
        let origin = DebridCloudItem.Origin.torrent(DebridTorrentID(rawValue: "1"))
        let first = CloudPlaybackToken(
            provider: provider, origin: origin, file: DebridFileID(rawValue: "a"))
        let second = CloudPlaybackToken(
            provider: provider, origin: origin, file: DebridFileID(rawValue: "b"))

        #expect(first.encoded() != second.encoded())
    }
}
