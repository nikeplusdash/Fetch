import Foundation

/**
 The seams third-party extensions plug into. The runtime that loads them
 ships after M1; the contract is fixed now so built-ins prove it.
 */
public enum ExtensionKind: String, Codable, Sendable, CaseIterable {
    case searchProvider
    case debridProvider
    case releaseParser
    case metadataEnricher
    case namingStrategy
    case routingRule
    case postDownloadAction
}

/**
 Every built-in registers through this same protocol — if it cannot express
 a built-in, the contract is wrong.
 */
public protocol DebridProvider: Sendable {
    var id: DebridProviderID { get }
    var displayName: String { get }

    var canReportCacheStatus: Bool { get }

    func previewFiles(rawMagnet: String, infoHashHex: String) async throws -> [DebridFile]?

    func validateCredentials() async throws -> DebridAccount
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry]
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent
    func files(in id: DebridTorrentID) async throws -> [DebridFile]
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL
    func delete(torrent: DebridTorrentID) async throws

    func listAccountContents() async throws -> [DebridCloudItem]


    func supportedHosts() async throws -> [DebridHost]

    func submitLink(_ url: URL) async throws -> DebridDownloadID

    func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload

    func downloadURL(web: DebridDownloadID) async throws -> URL

    var hostedLinksNeedPreparing: Bool { get }
}

extension DebridProvider {
    public var canReportCacheStatus: Bool { true }

    /**
     No web-download support, which is the honest answer for a provider
     that has not implemented it.

     This is what makes §5's "degrades to invisible rather than broken" true
     by construction rather than by discipline: a provider reporting no
     hosts never wins host routing, so the three methods below are never
     called on it.
     */
    public func supportedHosts() async throws -> [DebridHost] { [] }

    /**
     Nothing, which is the honest answer for a provider that has not
     implemented account listing — the same shape, for the same reason, as
     `supportedHosts()` above. A provider reporting no contents simply
     contributes no Cloud rows, rather than failing the whole fan-out.
     */
    public func listAccountContents() async throws -> [DebridCloudItem] { [] }

    public func submitLink(_ url: URL) async throws -> DebridDownloadID {
        throw DebridError.unsupportedOperation
    }
    public func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
        throw DebridError.unsupportedOperation
    }
    public func downloadURL(web: DebridDownloadID) async throws -> URL {
        throw DebridError.unsupportedOperation
    }

    public var hostedLinksNeedPreparing: Bool { true }

    /**
     The TorBox shape, which is also the only one expressible through
     `checkCached`. Services that preview differently override this.
     */
    public func previewFiles(
        rawMagnet: String, infoHashHex: String
    ) async throws -> [DebridFile]? {
        let entry = try await checkCached(
            hashes: [infoHashHex], listFiles: true)[infoHashHex.lowercased()]
        guard let files = entry?.files, !files.isEmpty else { return nil }
        return files
    }
}

/**
 Torznab (Jackett/Prowlarr) is the first `searchProvider` extension; both
 happen to be compiled in (§3, the dogfooding rule).
 */
public protocol SearchProvider: Sendable {
    var id: SearchProviderID { get }
    var displayName: String { get }

    func capabilities() async throws -> ProviderCapabilities
    func search(_ query: SearchQuery) async throws -> [SearchResult]
}

public extension SearchProvider {
    func participates(in categories: [TorznabCategory]) async -> Bool {
        guard !categories.isEmpty else { return true }
        guard let caps = try? await capabilities() else { return true }
        return CategoryIntersection.resolve(
            requested: categories, advertised: caps.categories) != .skip
    }
}
