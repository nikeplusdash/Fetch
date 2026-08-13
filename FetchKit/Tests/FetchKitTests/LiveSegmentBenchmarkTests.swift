import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Measures whether more parallel ranges actually download faster.
///
/// No debrid documents a simultaneous-connection limit — TorBox's own users
/// have asked and there is no published answer — so the default segment count
/// is otherwise a guess. This replaces the guess with a number from the
/// account and connection that will actually be used.
///
/// Skips unless FETCH_TORBOX_API_KEY is set. Downloads to a temp directory and
/// deletes as it goes.
@Suite(.serialized) struct LiveSegmentBenchmarkTests {
    static var apiKey: String? { ProcessInfo.processInfo.environment["FETCH_TORBOX_API_KEY"] }
    /// Opt-in separately: this moves real gigabytes.
    static var enabled: Bool { ProcessInfo.processInfo.environment["FETCH_BENCHMARK"] == "1" }

    @Test(.enabled(if: LiveSegmentBenchmarkTests.apiKey != nil && LiveSegmentBenchmarkTests.enabled))
    func segmentCountsAreComparedOnOneRealFile() async throws {
        let key = Self.apiKey!
        let provider = TorBoxProvider(apiKey: Redacted(key), client: HTTPClient())

        // Largest file on the account, so the measurement is dominated by
        // throughput rather than by request setup.
        let listing = Endpoint(
            baseURL: TorBoxProvider.defaultBaseURL,
            path: "/v1/api/torrents/mylist",
            queryItems: [URLQueryItem(name: "bypass_cache", value: "true")],
            headers: ["Authorization": "Bearer \(key)"])
        struct T: Decodable, Sendable { let id: Int }
        let all = try await HTTPClient().send(listing, as: TorBoxEnvelope<[T]>.self)

        var best: (DebridTorrent, DebridFile)?
        for entry in (all.data ?? []).prefix(10) {
            guard let torrent = try? await provider.torrent(
                id: DebridTorrentID(rawValue: String(entry.id))) else { continue }
            for file in torrent.files where file.size > 50_000_000 {
                if best == nil || file.size > best!.1.size { best = (torrent, file) }
            }
        }
        let (torrent, file) = try #require(best, "no file over 50 MB on the account")

        // A bounded slice, not the whole file: four full runs of a multi-gigabyte
        // remux would take hours, and throughput is just as comparable over a
        // fixed prefix. Every run moves exactly these bytes.
        let sample = min(file.size, 200_000_000)
        // Size only, never the name: benchmark output gets pasted around.
        print("BENCH sampling \(ByteCount.format(sample)) of \(ByteCount.format(file.size))")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for segments in [1, 4, 8, 16] {
            // A fresh link per run: a reused one may be warm in the CDN and
            // would flatter whichever run came second.
            let url = try await provider.downloadURL(torrent: torrent.id, file: file.id)
            let partial = root.appendingPathComponent("run-\(segments).part")

            let started = Date()
            let map = try await SegmentedTransfer(maxSegments: segments).transfer(
                from: url, to: partial,
                map: SegmentMap(totalBytes: sample, segments: segments),
                onProgress: { _ in })
            let elapsed = Date().timeIntervalSince(started)

            #expect(map.isComplete)
            let onDisk = (try? FileManager.default
                .attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
            #expect(onDisk == sample, "segment count \(segments) produced a wrong-sized file")

            let mbPerSecond = Double(sample) / elapsed / 1_000_000
            print(String(
                format: "BENCH %2d segments: %6.1f s  %7.1f MB/s", segments, elapsed, mbPerSecond))

            try? FileManager.default.removeItem(at: partial)
        }
    }
}
