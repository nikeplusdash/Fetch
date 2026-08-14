import Testing
import Foundation
@testable import FetchKit

@Suite struct MagnetLinkTests {
    static let hash = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"

    @Test func parsesMinimalMagnet() {
        let link = MagnetLink("magnet:?xt=urn:btih:\(Self.hash)")
        #expect(link?.infoHash.hex == Self.hash)
        #expect(link?.displayName == nil)
        #expect(link?.trackers.isEmpty == true)
    }

    @Test func parsesDisplayNameAndTrackers() {
        let raw = "magnet:?xt=urn:btih:\(Self.hash)"
            + "&dn=Big+Buck+Bunny"
            + "&tr=udp%3A%2F%2Ftracker.example%3A1337"
            + "&tr=udp%3A%2F%2Fother.example%3A80"
        let link = MagnetLink(raw)
        #expect(link?.displayName == "Big Buck Bunny")
        #expect(link?.trackers.count == 2)
        #expect(link?.trackers.first?.absoluteString == "udp://tracker.example:1337")
    }

    @Test func percentEncodedDisplayNameIsDecoded() {
        let link = MagnetLink("magnet:?xt=urn:btih:\(Self.hash)&dn=Some%20Movie%20%282024%29")
        #expect(link?.displayName == "Some Movie (2024)")
    }

    @Test func preservesRawVerbatimForProviderSubmission() {
        let raw = "magnet:?xt=urn:btih:\(Self.hash)&dn=x&tr=not%20a%20url&xl=123"
        #expect(MagnetLink(raw)?.raw == raw)
    }

    @Test func skipsV2HashAndFindsBtih() {
        // Some indexers emit a btmh (v2) xt alongside the btih (v1) one.
        let raw = "magnet:?xt=urn:btmh:1220caf1e1&xt=urn:btih:\(Self.hash)"
        #expect(MagnetLink(raw)?.infoHash.hex == Self.hash)
    }

    @Test func acceptsBase32Hash() {
        let raw = "magnet:?xt=urn:btih:3WBFL3G4PSSV7MF37AJSHWDQMLNR63I4"
        #expect(MagnetLink(raw)?.infoHash.hex == Self.hash)
    }

    @Test func dropsUnparseableTrackersButKeepsLink() {
        let raw = "magnet:?xt=urn:btih:\(Self.hash)&tr=%00%01&tr=udp%3A%2F%2Fok.example%3A80"
        let link = MagnetLink(raw)
        #expect(link != nil)
        #expect(link?.trackers.count == 1)
    }

    @Test(arguments: [
        "http://example.com/not-a-magnet",
        "magnet:?dn=no-hash-here",
        "magnet:?xt=urn:btih:tooshort",
        "magnet:?xt=urn:btmh:1220caf1e1",     // v2 only, no v1 hash
        "",
    ]) func rejectsInvalid(_ raw: String) {
        #expect(MagnetLink(raw) == nil)
    }
}
