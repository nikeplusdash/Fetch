import Foundation
import CryptoKit

/// One way a search result can actually be obtained.
///
/// The v1 design made `SearchResult.id` **be** an `InfoHash`, so §7 dropped any
/// result without one — Internet Archive, Gutenberg, and every hoster link were
/// discarded in the Torznab parser before they could render. This makes a
/// torrent one case rather than the case.
///
/// A single result often has several: an Anna's Archive book may exist as a
/// collection torrent, a MediaFire mirror, and a partner-server link. Which one
/// Fetch actually uses is resolved against live availability, not committed to
/// at parse time.
public enum ResultOrigin: Sendable, Codable, Hashable {
    /// `targetPath` names one file inside the torrent when the source already
    /// knows which is wanted (§6.1's AACIDs). Nil means "let the user pick".
    case torrent(infoHash: InfoHash, magnet: MagnetLink, targetPath: String?)
    /// A file behind a hoster a debrid can unrestrict.
    case hosted(url: URL, host: HostID, format: DocumentFormat? = nil)
    /// Plain HTTPS. No debrid, no account, no queue — Internet Archive and
    /// Gutenberg are entirely this case.
    case direct(url: URL, format: DocumentFormat? = nil)

    /// What edition of a document this candidate is, where the source knows.
    ///
    /// 7d ranks *within* a result: one Gutenberg book is one result with a
    /// candidate per format, so "prefer EPUB over a scanned PDF" is a question
    /// about candidate order, not result order. The provider has this — it
    /// used to discard it at `.map { .direct(url:) }` — and the ranking
    /// cannot ask for it any later.
    ///
    /// A torrent has none: it is a container, not an edition.
    public var documentFormat: DocumentFormat? {
        switch self {
        case .torrent: nil
        case .hosted(_, _, let format), .direct(_, let format): format
        }
    }

    /// §4's resolution order, as far as it can be decided at parse time.
    ///
    /// `.direct` outranks `.hosted` deliberately: unrestricting costs debrid
    /// quota and a round trip for a file Fetch can simply GET.
    ///
    /// A torrent ranks last **here** even though §4 puts a *cached* torrent
    /// first, because at parse time nobody has asked the debrid yet. The
    /// cached-wins rule applies once the cache check answers, which is a
    /// different decision at a different moment.
    public var preferenceRank: Int {
        switch self {
        case .direct:  0
        case .hosted:  1
        case .torrent: 2
        }
    }

    /// Whether Fetch will act on this origin at all.
    ///
    /// Origins are attacker-controlled strings from untrusted search sources
    /// (amendment §8). A `file:` URL would let a search result name a path on
    /// the user's own disk; `http` stays allowed because §13 permits it for LAN
    /// indexers, which is why a Jackett on 10.0.0.181 works.
    public var isUsable: Bool {
        switch self {
        case .torrent:
            return true
        case .hosted(let url, _, _), .direct(let url, _):
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "https" || scheme == "http"
        }
    }

    /// The URL this origin points at, for the two cases that have one.
    public var url: URL? {
        switch self {
        case .torrent: nil
        case .hosted(let url, _, _), .direct(let url, _): url
        }
    }
}

/// A result's identity, defined for every origin.
///
/// The amended drop rule (§3) turns on this: v1 dropped a result for want of an
/// infohash because an infohash was the only identity it had. With an ID for
/// all three origins, a result is dropped only when it has no candidates at all.
public struct ResultID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(origin: ResultOrigin) {
        switch origin {
        case .torrent(let infoHash, _, let targetPath):
            // Unchanged from v1 for a whole torrent, so dedup across indexers
            // keeps collapsing two listings of the same torrent into one row.
            //
            // A targetPath extends it rather than replacing it: §6.1's case is
            // thousands of separately-wanted books inside one 300 GB container,
            // which are genuinely different results.
            if let targetPath, !targetPath.isEmpty {
                rawValue = "btih:\(infoHash.hex)/\(Self.digest(targetPath))"
            } else {
                rawValue = "btih:\(infoHash.hex)"
            }
        case .hosted(let url, _, _), .direct(let url, _):
            // Hosted and direct share identity for the same URL: the
            // difference is how Fetch reaches the file, not which file it is.
            // The format is deliberately not part of it: the same file at the
            // same URL is the same file however it was labelled.
            rawValue = "url:\(Self.digest(Self.normalise(url)))"
        }
    }

    /// Identity from the source's own key, for a result whose candidates are
    /// several editions of one item (7d §3.4).
    ///
    /// Digested like the URL case rather than interpolated raw: a provider's
    /// key is external text, and a key containing a colon would otherwise
    /// forge an ID in another namespace.
    init(sourceKey: String) {
        rawValue = "key:\(Self.digest(sourceKey))"
    }

    /// Identity for a result with no usable candidate. Keyed on the title so
    /// two different broken results stay two results.
    init(unreachable title: String) {
        rawValue = "unreachable:\(Self.digest(title))"
    }

    /// Case in scheme and host is not meaningful, and a trailing slash is not a
    /// different file. Without this the same Gutenberg book listed twice under
    /// different casing renders as two rows.
    ///
    /// Query and fragment are **kept**: `?download=1` and `#page=3` can select
    /// genuinely different content, and merging those would be worse than
    /// showing a duplicate.
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

/// What a queued download actually points at.
///
/// §6's rule that **no CDN URL is ever persisted** holds for the two debrid
/// cases: they store identifiers and re-resolve on demand, because a debrid
/// link is credentialed and expires. `.directHTTP` persists its URL because
/// there the URL *is* the identity — it is a public address, not a token.
public enum DownloadSource: Sendable, Codable, Hashable {
    case debridTorrent(
        provider: DebridProviderID, torrent: DebridTorrentID, file: DebridFileID)
    case debridHosted(provider: DebridProviderID, download: DebridDownloadID)
    case directHTTP(url: URL)

    /// Whether the download has to wait on a debrid before bytes can move.
    ///
    /// `.directHTTP` goes straight `queued → downloading`. Submitting a hoster
    /// link is asynchronous exactly like a magnet, so it does wait.
    public var needsPreparing: Bool {
        switch self {
        case .directHTTP: false
        case .debridTorrent, .debridHosted: true
        }
    }
}
