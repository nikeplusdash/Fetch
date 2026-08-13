import Foundation

/// The seams third-party extensions plug into. The runtime that loads them
/// ships after M1; the contract is fixed now so built-ins prove it.
public enum ExtensionKind: String, Codable, Sendable, CaseIterable {
    case searchProvider
    case debridProvider
    case releaseParser
    case metadataEnricher
    case namingStrategy
    case routingRule
    case postDownloadAction
}

/// Every built-in registers through this same protocol — if it cannot express
/// a built-in, the contract is wrong.
public protocol DebridProvider: Sendable {
    var id: DebridProviderID { get }
    var displayName: String { get }

    /// Whether this service offers a **side-effect-free** way to ask if a hash
    /// is cached. False means it is excluded from badge checks entirely, rather
    /// than reporting every hash as a miss.
    ///
    /// Real-Debrid is the reason this exists: it disabled
    /// `/torrents/instantAvailability`, and the only remaining way to learn
    /// whether it holds a torrent is to add the torrent to the account — which
    /// a badge check must never do. Defaulted to `true` so a provider that can
    /// answer needs no boilerplate.
    var canReportCacheStatus: Bool { get }

    /// A **side-effect-free** file list for a magnet, or nil when this service
    /// cannot produce one without adding the torrent to the account (§6).
    ///
    /// The three services do this differently, which is why it is a protocol
    /// member rather than an assumption: TorBox answers from
    /// `checkCached(listFiles: true)`, Premiumize from `/transfer/directdl`
    /// (whose `/cache/check` carries no files at all), and Real-Debrid cannot
    /// do it — its file ids only exist after `addMagnet`.
    ///
    /// Assuming the TorBox shape produced an empty picker for every Premiumize
    /// result: a cached hit, zero files, and a disabled Download button for a
    /// magnet that was plainly available.
    func previewFiles(rawMagnet: String, infoHashHex: String) async throws -> [DebridFile]?

    func validateCredentials() async throws -> DebridAccount
    func checkCached(hashes: [String], listFiles: Bool) async throws -> [String: CacheEntry]
    func submitMagnet(rawMagnet: String) async throws -> DebridTorrentID
    func torrent(id: DebridTorrentID) async throws -> DebridTorrent
    func files(in id: DebridTorrentID) async throws -> [DebridFile]
    func downloadURL(torrent: DebridTorrentID, file: DebridFileID) async throws -> URL
    func delete(torrent: DebridTorrentID) async throws

    // MARK: - Web downloads (amendment §5, 7e)

    /// Which file hosts this service can unrestrict.
    ///
    /// Coverage is a property of the *debrid*, so this is per-provider rather
    /// than a Fetch-wide table: a user with two debrids has two lists, and a
    /// Rapidgator link may be reachable through one and not the other.
    ///
    /// A provider without web downloads returns `[]` — see the default below.
    func supportedHosts() async throws -> [DebridHost]

    /// Queues a hoster link at the debrid.
    func submitLink(_ url: URL) async throws -> DebridDownloadID

    /// Progress of a queued link, so the same poller that watches a torrent
    /// can watch this.
    func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload

    /// A fresh, credentialed HTTPS URL for a completed web download.
    ///
    /// Re-resolved rather than stored, exactly as for a torrent: §6's rule is
    /// that no CDN URL is ever persisted, because a debrid link is
    /// credentialed and expires.
    func downloadURL(web: DebridDownloadID) async throws -> URL

    /// Whether a submitted link has to be polled before it can be fetched.
    ///
    /// True for TorBox, which queues the link and reports progress. **False
    /// for Real-Debrid**, whose `/unrestrict/link` is synchronous — one POST
    /// returns the final link, and polling it would wait for something that
    /// finished before the first poll.
    var hostedLinksNeedPreparing: Bool { get }
}

extension DebridProvider {
    public var canReportCacheStatus: Bool { true }

    /// No web-download support, which is the honest answer for a provider
    /// that has not implemented it.
    ///
    /// This is what makes §5's "degrades to invisible rather than broken" true
    /// by construction rather than by discipline: a provider reporting no
    /// hosts never wins host routing, so the three methods below are never
    /// called on it.
    public func supportedHosts() async throws -> [DebridHost] { [] }

    public func submitLink(_ url: URL) async throws -> DebridDownloadID {
        throw DebridError.unsupportedOperation
    }
    public func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
        throw DebridError.unsupportedOperation
    }
    public func downloadURL(web: DebridDownloadID) async throws -> URL {
        throw DebridError.unsupportedOperation
    }

    /// The TorBox shape: queue, then poll. A provider whose unrestrict is
    /// synchronous overrides this to false.
    public var hostedLinksNeedPreparing: Bool { true }

    /// The TorBox shape, which is also the only one expressible through
    /// `checkCached`. Services that preview differently override this.
    public func previewFiles(
        rawMagnet: String, infoHashHex: String
    ) async throws -> [DebridFile]? {
        let entry = try await checkCached(
            hashes: [infoHashHex], listFiles: true)[infoHashHex.lowercased()]
        guard let files = entry?.files, !files.isEmpty else { return nil }
        return files
    }
}

/// Torznab (Jackett/Prowlarr) is the first `searchProvider` extension; both
/// happen to be compiled in (§3, the dogfooding rule).
public protocol SearchProvider: Sendable {
    var id: SearchProviderID { get }
    var displayName: String { get }

    func capabilities() async throws -> ProviderCapabilities
    func search(_ query: SearchQuery) async throws -> [SearchResult]
}

public extension SearchProvider {
    /// Whether this provider carries any of the requested categories.
    ///
    /// Default: derived from `capabilities()`. A provider that advertises no
    /// categories participates in everything — absence of caps is not evidence
    /// of absence of coverage — and so does one whose caps fetch fails, because
    /// an unreachable provider should report as a failure the user can see
    /// rather than vanish from the indexer count.
    func participates(in categories: [TorznabCategory]) async -> Bool {
        guard !categories.isEmpty else { return true }
        guard let caps = try? await capabilities() else { return true }
        return CategoryIntersection.resolve(
            requested: categories, advertised: caps.categories) != .skip
    }
}
