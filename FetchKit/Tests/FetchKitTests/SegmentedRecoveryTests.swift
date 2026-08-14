import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// The engine's half of the `error 6` fix.
///
/// `SegmentedTransferTests` covers the status-to-error mapping. This covers
/// what the engine does with two of those errors, which is the part that turns
/// a dead download into a finished one:
///
/// - `.linkExpired` → re-resolve the debrid link **once** and carry on with the
///   segments that already landed.
/// - `.rangeNotSupported` → the link genuinely ignores `Range`, so fall back to
///   one whole-file stream rather than failing.
///
/// Both were reachable in the reported install (`segmentsPerFile = 3`,
/// `maxConcurrentDownloads = 5`), and neither existed: any non-206 answer was
/// terminal, which is why 80 files of one torrent failed while 224 succeeded,
/// and why quitting and relaunching — which asks for fresh links — "allowed the
/// downloads to continue".
@Suite(.serialized, .usesStubURLProtocol) struct SegmentedRecoveryTests {
    private static let size = 1_000
    private static var content: Data { Data((0..<size).map { UInt8($0 % 251) }) }

    /// Hands out a different link each time it is asked, so a test can tell a
    /// re-resolve from a retry against the same URL.
    private actor LinkVendor {
        private var issued = 0
        func next() -> URL {
            issued += 1
            return URL(string: "https://cdn.example/link\(issued)")!
        }
        var count: Int { issued }
    }

    private struct RelinkingDebrid: DebridProvider {
        let id = DebridProviderID(rawValue: "fake")
        let displayName = "Fake"
        let vendor: LinkVendor

        func validateCredentials() async throws -> DebridAccount {
            DebridAccount(email: nil, plan: nil, expiresAt: nil)
        }
        func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] { [:] }
        func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
            DebridTorrentID(rawValue: "1")
        }
        func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
            DebridTorrent(
                id: id, infoHashHex: "", name: "t", size: 0, progress: 1,
                state: .completed, files: [], seeds: nil, downloadSpeed: nil, eta: nil)
        }
        func files(in id: DebridTorrentID) async throws -> [DebridFile] { [] }
        func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
            await vendor.next()
        }
        func delete(torrent: DebridTorrentID) async throws {}
    }

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func request(root: URL) -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "fake"),
            torrentID: DebridTorrentID(rawValue: "1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "0"), name: "file.bin",
                shortName: "file.bin", size: Int64(Self.size), mimeType: nil),
            infoHashHex: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
            subfolder: "Movies",
            destinationRoot: root)
    }

    private func engine(provider: any DebridProvider, segments: Int) -> DownloadEngine {
        let configuration = StubURLProtocol.makeConfiguration()
        return DownloadEngine(
            provider: provider,
            transfer: RangeTransfer(body: ChunkedBody(configuration: configuration)),
            segmented: SegmentedTransfer(
                body: ChunkedBody(configuration: configuration),
                maxSegments: segments, retryDelay: 0),
            segmentsPerFile: segments,
            maxConcurrent: 1)
    }

    /// Serves the requested range as a well-formed 206, from `whole`.
    private static func serveRange(
        _ request: URLRequest, _ whole: Data
    ) -> StubURLProtocol.Response {
        guard let header = request.value(forHTTPHeaderField: "Range"),
              let spec = header.split(separator: "=").last
        else { return StubURLProtocol.Response(status: 200, body: whole) }

        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        let start = Int(bounds.first ?? "0") ?? 0
        let end = bounds.count > 1 ? (Int(bounds[1]) ?? whole.count - 1) : whole.count - 1
        return StubURLProtocol.Response(
            status: 206,
            headers: ["Content-Range": "bytes \(start)-\(end)/\(whole.count)"],
            body: Data(whole[start...min(end, whole.count - 1)]))
    }

    // MARK: - Expired link

    /// The first link 403s on every segment; the second works. The download
    /// must finish, whole and correct, without the user touching anything.
    @Test func anExpiredLinkIsReResolvedAndTheDownloadFinishes() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let whole = Self.content

        StubURLProtocol.reset(handler: { request in
            // Only the *first* issued link is dead, so a plain retry against
            // the same URL could never rescue this — nothing but a re-resolve
            // gets past it.
            if request.url?.absoluteString.hasSuffix("link1") == true {
                return StubURLProtocol.Response(status: 403)
            }
            return Self.serveRange(request, whole)
        })

        let vendor = LinkVendor()
        let engine = engine(provider: RelinkingDebrid(vendor: vendor), segments: 2)
        let id = await engine.enqueue(request(root: root))
        try await engine.waitUntilSettled(id)

        #expect(await engine.state(of: id) == .completed)
        let landed = root.appendingPathComponent("Movies/file.bin")
        #expect(try Data(contentsOf: landed) == whole)
        // Asked twice: once per attempt, not once per segment.
        #expect(await vendor.count == 2)
    }

    /// One re-resolve, not an unbounded loop. A debrid that hands out dead
    /// links forever must fail the download rather than spin on it.
    @Test func aSecondExpiryFailsRatherThanRelinkingForever() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.reset(handler: { _ in StubURLProtocol.Response(status: 403) })

        let vendor = LinkVendor()
        let engine = engine(provider: RelinkingDebrid(vendor: vendor), segments: 2)
        let id = await engine.enqueue(request(root: root))
        try await engine.waitUntilSettled(id)

        #expect(await engine.state(of: id) == .failed)
        #expect(await vendor.count == 2)
    }

    // MARK: - Range ignored

    /// A link that answers 200 to a range request is not a failed download —
    /// it is a download that has to be taken over one connection. This used to
    /// be `error 6` and a dead row.
    @Test func aLinkThatIgnoresRangeFallsBackToOneWholeFileTransfer() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let whole = Self.content

        StubURLProtocol.reset(handler: { _ in
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "\(whole.count)"], body: whole)
        })

        let vendor = LinkVendor()
        let engine = engine(provider: RelinkingDebrid(vendor: vendor), segments: 3)
        let id = await engine.enqueue(request(root: root))
        try await engine.waitUntilSettled(id)

        #expect(await engine.state(of: id) == .completed)
        let landed = root.appendingPathComponent("Movies/file.bin")
        #expect(try Data(contentsOf: landed) == whole)
    }

    /// The trap inside that fallback, and the reason it truncates first.
    ///
    /// `SegmentedTransfer.preallocate` grows the partial to the full length
    /// before the first request, so at the moment the fallback runs there is a
    /// full-size file of zeros on disk. `RangeTransfer` reads a partial's size
    /// as "how much is already done" — it would take its `offset ==
    /// expectedSize` shortcut, pass a `verify` that only compares sizes, and
    /// hand the engine a file of zeros to rename into place. Reported as a
    /// completed download, byte for byte wrong.
    @Test func theFallbackDoesNotRenameThePreallocatedZeroesIntoPlace() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let whole = Self.content

        StubURLProtocol.reset(handler: { _ in
            StubURLProtocol.Response(
                status: 200, headers: ["Content-Length": "\(whole.count)"], body: whole)
        })

        let vendor = LinkVendor()
        let engine = engine(provider: RelinkingDebrid(vendor: vendor), segments: 3)
        let id = await engine.enqueue(request(root: root))
        try await engine.waitUntilSettled(id)

        let landed = try Data(contentsOf: root.appendingPathComponent("Movies/file.bin"))
        #expect(landed.count == whole.count)
        #expect(landed.contains { $0 != 0 }, "the landed file is entirely zeroes")
    }
}
