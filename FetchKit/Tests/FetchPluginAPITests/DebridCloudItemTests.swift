import Testing
import Foundation
@testable import FetchPluginAPI

@Suite("Debrid cloud items")
struct DebridCloudItemTests {
    private func file(_ name: String) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: "f1"), name: name,
            shortName: (name as NSString).lastPathComponent, size: 5, mimeType: nil)
    }

    @Test("A torrent item's id is provider, kind marker and torrent id")
    func torrentIdentity() {
        let item = DebridCloudItem(
            provider: DebridProviderID(rawValue: "torbox"),
            origin: .torrent(DebridTorrentID(rawValue: "42")),
            name: "Sintel", size: 1_000, infoHashHex: "abc", addedAt: nil, files: [])
        #expect(item.id == "torbox:t:42")
    }

    @Test("A web item's id carries the other kind marker, so the two never collide")
    func webIdentity() {
        let item = DebridCloudItem(
            provider: DebridProviderID(rawValue: "torbox"),
            origin: .web(DebridDownloadID(rawValue: "42")),
            name: "Sintel", size: 1_000, infoHashHex: nil, addedAt: nil, files: [])
        #expect(item.id == "torbox:w:42")
    }

    @Test("replacingFiles swaps files and keeps everything else")
    func replacingFilesIsNonDestructive() {
        let item = DebridCloudItem(
            provider: DebridProviderID(rawValue: "rd"),
            origin: .torrent(DebridTorrentID(rawValue: "9")),
            name: "Big Buck Bunny", size: 5, infoHashHex: nil, addedAt: nil, files: [])
        let hydrated = item.replacingFiles([file("a/b.mkv")])
        #expect(hydrated.files == [file("a/b.mkv")])
        #expect(hydrated.name == item.name)
        #expect(hydrated.origin == item.origin)
        #expect(hydrated.id == item.id)
    }

    @Test("An origin survives a Codable round trip, which the playback token needs")
    func originRoundTrips() throws {
        for origin: DebridCloudItem.Origin in [
            .torrent(DebridTorrentID(rawValue: "t:1")),
            .web(DebridDownloadID(rawValue: "w/2")),
        ] {
            let data = try JSONEncoder().encode(origin)
            #expect(try JSONDecoder().decode(DebridCloudItem.Origin.self, from: data) == origin)
        }
    }
}
