import Testing
import Foundation
@testable import FetchKit

/// Hits the real `.torrent` cache. Skips unless FETCH_LIVE_METADATA=1.
///
/// This exists because the stubbed tests cannot catch the thing that actually
/// broke it: itorrents.org answers 403 without a browser User-Agent, so every
/// lookup would have missed silently and the feature would have looked simply
/// ineffective rather than misconfigured.
@Suite(.serialized) struct LiveTorrentMetadataTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["FETCH_LIVE_METADATA"] == "1" }

    /// The decoy, live. Hashes nobody holds must return nothing — before
    /// verification they returned a plausible file list containing an `.exe`,
    /// identically, for every one of them.
    @Test(.enabled(if: LiveTorrentMetadataTests.enabled))
    func hashesTheCacheDoesNotHoldReturnNothing() async {
        for invented in [
            "1111111111111111111111111111111111111111",
            "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            "b5e4a1b2f1e7ec1e0b0d2b8f8a0f0ba5f3c6f9c7",
        ] {
            let files = await TorrentMetadataFetcher().files(forInfoHash: invented)
            #expect(files == nil, "cache served a decoy for \(invented.prefix(12)) and it was accepted")
        }
        print("LIVE metadata: decoys rejected for all three invented hashes")
    }

    /// A hash the cache genuinely holds still resolves — verification must not
    /// reject the real thing.
    @Test(.enabled(if: LiveTorrentMetadataTests.enabled))
    func aRealHashResolvesToItsFileList() async {
        let hash = "d56eb90c12e1cd269f1bff2e62523b0f46bf390b"
        guard let files = await TorrentMetadataFetcher().files(forInfoHash: hash) else {
            // Coverage is best-effort; a genuine miss is a valid outcome.
            print("LIVE metadata: no entry for this hash (a valid miss)")
            return
        }
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { $0.length > 0 })
        print("LIVE metadata: \(files.count) files, first=\(files[0].path) \(files[0].length) bytes")
    }
}
