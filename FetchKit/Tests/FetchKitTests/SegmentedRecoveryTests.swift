import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct SegmentedRecoveryTests {
    private static let size = 1_000
    private static var content: Data { Data((0..<size).map { UInt8($0 % 251) }) }

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


    @Test func anExpiredLinkIsReResolvedAndTheDownloadFinishes() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let whole = Self.content

        StubURLProtocol.reset(handler: { request in
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
        #expect(await vendor.count == 2)
    }

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
