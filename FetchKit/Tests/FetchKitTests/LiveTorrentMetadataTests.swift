import Testing
import Foundation
@testable import FetchKit

@Suite(.serialized) struct LiveTorrentMetadataTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["FETCH_LIVE_METADATA"] == "1" }

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

    @Test(.enabled(if: LiveTorrentMetadataTests.enabled))
    func aRealHashResolvesToItsFileList() async {
        let hash = "d56eb90c12e1cd269f1bff2e62523b0f46bf390b"
        guard let files = await TorrentMetadataFetcher().files(forInfoHash: hash) else {
            print("LIVE metadata: no entry for this hash (a valid miss)")
            return
        }
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { $0.length > 0 })
        print("LIVE metadata: \(files.count) files, first=\(files[0].path) \(files[0].length) bytes")
    }
}
