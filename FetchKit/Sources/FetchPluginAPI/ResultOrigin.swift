import Foundation
import CryptoKit

/**
 One way a search result can actually be obtained.

 The v1 design made `SearchResult.id` **be** an `InfoHash`, so §7 dropped any
 result without one — Internet Archive, Gutenberg, and every hoster link were
 discarded in the Torznab parser before they could render. This makes a
 torrent one case rather than the case.

 A single result often has several: an Anna's Archive book may exist as a
 collection torrent, a MediaFire mirror, and a partner-server link. Which one
 Fetch actually uses is resolved against live availability, not committed to
 at parse time.
 */
public enum ResultOrigin: Sendable, Codable, Hashable {
    case torrent(infoHash: InfoHash, magnet: MagnetLink, targetPath: String?)
    case hosted(url: URL, host: HostID, format: DocumentFormat? = nil)
    case direct(url: URL, format: DocumentFormat? = nil)

    public var documentFormat: DocumentFormat? {
        switch self {
        case .torrent: nil
        case .hosted(_, _, let format), .direct(_, let format): format
        }
    }

    public var preferenceRank: Int {
        switch self {
        case .direct:  0
        case .hosted:  1
        case .torrent: 2
        }
    }

    public var isUsable: Bool {
        switch self {
        case .torrent:
            return true
        case .hosted(let url, _, _), .direct(let url, _):
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "https" || scheme == "http"
        }
    }

    public var url: URL? {
        switch self {
        case .torrent: nil
        case .hosted(let url, _, _), .direct(let url, _): url
        }
    }
}

/**
 A result's identity, defined for every origin.

 The amended drop rule (§3) turns on this: v1 dropped a result for want of an
 infohash because an infohash was the only identity it had. With an ID for
 all three origins, a result is dropped only when it has no candidates at all.
 */
public struct ResultID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(origin: ResultOrigin) {
        switch origin {
        case .torrent(let infoHash, _, let targetPath):
            if let targetPath, !targetPath.isEmpty {
                rawValue = "btih:\(infoHash.hex)/\(Self.digest(targetPath))"
            } else {
                rawValue = "btih:\(infoHash.hex)"
            }
        case .hosted(let url, _, _), .direct(let url, _):
            rawValue = "url:\(Self.digest(Self.normalise(url)))"
        }
    }

    init(sourceKey: String) {
        rawValue = "key:\(Self.digest(sourceKey))"
    }

    init(unreachable title: String) {
        rawValue = "unreachable:\(Self.digest(title))"
    }

    static func normalise(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let scheme = components?.scheme { components?.scheme = scheme.lowercased() }
        if let host = components?.host { components?.host = host.lowercased() }
        var string = components?.string ?? url.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        return string
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public init(from d: any Decoder) throws {
        rawValue = try d.singleValueContainer().decode(String.self)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue)
    }
}

/**
 What a queued download actually points at.

 §6's rule that **no CDN URL is ever persisted** holds for the two debrid
 cases: they store identifiers and re-resolve on demand, because a debrid
 link is credentialed and expires. `.directHTTP` persists its URL because
 there the URL *is* the identity — it is a public address, not a token.
 */
public enum DownloadSource: Sendable, Codable, Hashable {
    case debridTorrent(
        provider: DebridProviderID, torrent: DebridTorrentID, file: DebridFileID)
    case debridHosted(provider: DebridProviderID, download: DebridDownloadID)
    case directHTTP(url: URL)

    public var needsPreparing: Bool {
        switch self {
        case .directHTTP: false
        case .debridTorrent, .debridHosted: true
        }
    }
}
