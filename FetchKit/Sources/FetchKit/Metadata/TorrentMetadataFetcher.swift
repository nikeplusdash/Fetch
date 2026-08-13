import Foundation

/// Fetches a torrent's file list by infohash, without joining the swarm.
///
/// **Why not DHT.** The complete way to resolve a magnet is BEP 9 metadata
/// exchange over DHT and peers — what a torrent client does. It is also the one
/// thing a debrid client must not do: connecting to peers announces the user's
/// IP to everyone sharing that torrent, which is exactly what paying for a
/// debrid avoids. This is a plain HTTPS GET to one host instead, the same
/// posture as talking to an indexer.
///
/// **It is best-effort by design.** Public caches do not hold every hash,
/// especially new or obscure ones. Every failure — miss, timeout, malformed
/// body, unreachable host — returns nil, and the caller falls back to whatever
/// it would have done before. Nothing here may turn a working flow into an
/// error.
public actor TorrentMetadataFetcher {
    /// Public `.torrent` caches, tried in order. Kept as data so adding one is
    /// an edit, not a code change — and so it is obvious to a reader exactly
    /// which third parties this app will contact.
    public static let defaultSources: [String] = [
        "https://itorrents.org/torrent/{HASH}.torrent",
    ]

    private let sources: [String]
    private let client: any HTTPClientProtocol
    /// Well under a real torrent; anything larger is not something to parse.
    static let maxBytes = 8 * 1024 * 1024

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public init(
        sources: [String] = TorrentMetadataFetcher.defaultSources,
        client: any HTTPClientProtocol = HTTPClient()
    ) {
        self.sources = sources
        self.client = client
    }

    /// The file list, or nil when no source could supply it.
    public func files(forInfoHash hash: String) async -> [TorrentMetadata.File]? {
        // Caches key on the uppercase hex form.
        let normalized = hash.uppercased()
        guard normalized.count == 40 else { return nil }

        for template in sources {
            guard let url = URL(string: template.replacingOccurrences(
                of: "{HASH}", with: normalized)) else { continue }

            do {
                let endpoint = Endpoint(
                    baseURL: url, path: "",
                    // Verified against itorrents.org: without a browser
                    // User-Agent it answers 403 to every request, so the
                    // feature would have missed silently, every time.
                    headers: ["User-Agent": Self.userAgent],
                    timeout: 10,      // a preview must not stall the sheet
                    isRetryable: false)
                let (data, response) = try await client.sendRaw(endpoint)

                // Verification is not optional here. itorrents.org returns a
                // byte-identical decoy for any hash it does not hold —
                // confirmed live: three unrelated hashes produced the same
                // 45,728-byte body containing an `.exe`. Unverified, every
                // uncached torrent would show a fabricated file list.
                guard (200...299).contains(response.statusCode),
                      data.count <= Self.maxBytes,
                      let metadata = TorrentMetadata.parse(data, expectedInfoHash: normalized),
                      !metadata.files.isEmpty
                else { continue }

                return metadata.files
            } catch {
                // A cache being down is not an error the user needs to see.
                continue
            }
        }
        return nil
    }
}
