import Testing
import Foundation
@testable import FetchPluginAPI

@Suite struct DebridDTOTests {
    @Test func unknownTorrentStateRoundTripsRatherThanTrapping() throws {
        let json = Data(#""some_future_state""#.utf8)
        let state = try JSONDecoder().decode(DebridTorrentState.self, from: json)
        #expect(state == .unknown("some_future_state"))

        let encoded = try JSONEncoder().encode(state)
        #expect(String(data: encoded, encoding: .utf8) == #""some_future_state""#)
    }

    @Test(arguments: [
        ("queued", DebridTorrentState.queued),
        ("downloading", .downloading),
        ("completed", .completed),
        ("stalled", .stalled),
    ]) func decodesKnownStates(_ raw: String, _ expected: DebridTorrentState) throws {
        let decoded = try JSONDecoder().decode(
            DebridTorrentState.self, from: Data("\"\(raw)\"".utf8)
        )
        #expect(decoded == expected)
    }

    @Test func debridFileRoundTrips() throws {
        let file = DebridFile(
            id: DebridFileID(rawValue: "3"),
            name: "Show/S01E01.mkv",
            shortName: "S01E01.mkv",
            size: 1024,
            mimeType: "video/x-matroska"
        )
        let data = try JSONEncoder().encode(file)
        #expect(try JSONDecoder().decode(DebridFile.self, from: data) == file)
    }

    @Test func cacheEntryCarriesAPIVersion() {
        let entry = CacheEntry(
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            name: "x", size: 1, files: nil
        )
        #expect(entry.apiVersion == currentAPIVersion)
    }
}
