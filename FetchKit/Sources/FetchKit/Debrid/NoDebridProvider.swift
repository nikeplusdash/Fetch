import Foundation
import FetchPluginAPI

/// The provider for downloads that have no provider.
///
/// `DownloadEngine` takes a `DebridProvider` because every download used to
/// need one. Direct HTTPS downloads (amendment §2) do not, and stage 7b's
/// claim is precisely that they work with no debrid configured at all.
///
/// Every method throws rather than returning a plausible value. A stub that
/// quietly succeeded would let a debrid call slip through unnoticed and turn
/// "never touches a debrid" from a guarantee into a hope.
public struct NoDebridProvider: DebridProvider {
    public let id = DebridProviderID(rawValue: "direct")
    public let displayName = "Direct"
    public let canReportCacheStatus = false

    public struct NotADebridDownload: Error, LocalizedError {
        public var errorDescription: String? {
            "This download is a direct HTTPS transfer and has no debrid service."
        }
    }

    public init() {}

    public func validateCredentials() async throws -> DebridAccount {
        throw NotADebridDownload()
    }
    public func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry] {
        [:]
    }
    public func previewFiles(rawMagnet: String, infoHashHex: String) async throws -> [DebridFile]? {
        nil
    }
    public func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID {
        throw NotADebridDownload()
    }
    public func torrent(id: DebridTorrentID) async throws -> DebridTorrent {
        throw NotADebridDownload()
    }
    public func files(in id: DebridTorrentID) async throws -> [DebridFile] {
        throw NotADebridDownload()
    }
    public func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL {
        throw NotADebridDownload()
    }
    public func delete(torrent: DebridTorrentID) async throws {}
}
