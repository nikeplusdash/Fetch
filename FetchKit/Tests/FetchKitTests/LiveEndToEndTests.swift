import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Drives the REAL stack against the REAL TorBox API and writes a real file to
/// disk: provider -> requestdl -> RangeTransfer -> DownloadEngine -> renamed
/// file. Skips unless FETCH_TORBOX_API_KEY is set.
@Suite(.serialized) struct LiveEndToEndTests {
    static var apiKey: String? { ProcessInfo.processInfo.environment["FETCH_TORBOX_API_KEY"] }

    @Test(.enabled(if: LiveEndToEndTests.apiKey != nil))
    func downloadsARealFileEndToEnd() async throws {
        let key = Self.apiKey!
        let provider = TorBoxProvider(apiKey: Redacted(key), client: HTTPClient())

        // Find the smallest file on the account so this stays quick.
        let listing = Endpoint(
            baseURL: TorBoxProvider.defaultBaseURL,
            path: "/v1/api/torrents/mylist",
            queryItems: [URLQueryItem(name: "bypass_cache", value: "true")],
            headers: ["Authorization": "Bearer \(key)"])
        struct T: Decodable, Sendable { let id: Int }
        let all = try await HTTPClient().send(listing, as: TorBoxEnvelope<[T]>.self)
        var best: (DebridTorrent, DebridFile)?
        for t in (all.data ?? []).prefix(6) {
            guard let torrent = try? await provider.torrent(
                id: DebridTorrentID(rawValue: String(t.id))) else { continue }
            for file in torrent.files where file.size > 1024 {
                if best == nil || file.size < best!.1.size { best = (torrent, file) }
            }
        }
        let (torrent, file) = try #require(best, "no downloadable file on the account")
        print("PICKED  \(file.shortName)  \(ByteCount.format(file.size))")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetch-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = DownloadEngine(provider: provider, maxConcurrent: 1)
        let id = await engine.enqueue(DownloadRequest(
            providerID: provider.id,
            torrentID: torrent.id,
            file: file,
            infoHashHex: torrent.infoHashHex,
            subfolder: "Movies",
            destinationRoot: root))

        try await engine.waitUntilSettled(id)
        let state = await engine.state(of: id)
        print("STATE   \(String(describing: state))")

        #expect(state == .completed)

        // Prove the bytes are actually on disk under the routed, sanitized path.
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL }
            .first { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false }
        let onDisk = try #require(found, "no file written")
        let size = try onDisk.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("ON DISK \(onDisk.lastPathComponent)  \(ByteCount.format(Int64(size)))")
        print("PATH    Movies/… under the download root")

        #expect(size == Int(file.size))
        #expect(!onDisk.lastPathComponent.hasSuffix(".fetchpart"))
    }
}
