import Foundation
import FetchPluginAPI

/// Turns feed items that carry only a `.torrent` URL into real results, by
/// fetching the file and reading its infohash.
///
/// **This is not P2P.** No peer is contacted and no announce is made: it is an
/// HTTPS GET to the user's own indexer, which already holds the tracker cookie
/// that makes the file reachable, followed by a local bencode parse. Same
/// posture as `TorrentFile` reading one off disk, and the same reason both
/// exist rather than BEP 9 over DHT.
///
/// **Why it is bounded rather than "fetch them all".** Every one of these costs
/// the indexer a round trip to the tracker — the file is not sitting in
/// Jackett, it is fetched on demand. A query that returned eighty login-gated
/// results would otherwise turn one search into eighty-one requests against a
/// server that is frequently a Raspberry Pi. So: the best `maxItems` by seeders,
/// `maxConcurrent` at a time, and a short per-file timeout. Whatever does not
/// resolve is simply absent, exactly as it was before this existed — this can
/// add results and can never remove or delay one.
enum TorrentFileResolver {
    /// How many `.torrent` files one search will fetch from one indexer.
    ///
    /// Ordered by seeders, so the cap keeps the results most likely to be
    /// wanted rather than whichever the tracker happened to list first.
    static let maxItems = 25
    /// In flight at once, per indexer.
    ///
    /// Deliberately small. The fan-out already runs every indexer at the same
    /// time, so this multiplies: eleven indexers each pulling four files is
    /// forty-four concurrent requests to one host, which is where a small
    /// server starts queueing rather than answering.
    static let maxConcurrent = 4
    /// A `.torrent` is tens of kilobytes. Anything slower than this is the
    /// tracker being unreachable, and a search must not wait on it.
    static let perFileTimeout: TimeInterval = 15
    /// Well above any real `.torrent`; a body larger than this is not one.
    static let maxBytes = 8 * 1024 * 1024

    static func resolve(
        _ items: [TorznabFeedParser.UnresolvedItem],
        client: any HTTPClientProtocol
    ) async -> [SearchResult] {
        guard !items.isEmpty else { return [] }
        let wanted = items.sorted { $0.seeders > $1.seeders }.prefix(maxItems)

        var resolved: [SearchResult] = []
        await withTaskGroup(of: SearchResult?.self) { group in
            var next = wanted.startIndex
            func addTask() {
                guard next < wanted.endIndex else { return }
                let item = wanted[next]
                next = wanted.index(after: next)
                group.addTask { await fetch(item, client: client) }
            }
            for _ in 0..<min(maxConcurrent, wanted.count) { addTask() }
            while let result = await group.next() {
                if let result { resolved.append(result) }
                addTask()
            }
        }
        // Seeder order, so a caller appending these to the feed's own results
        // gets a stable list rather than one that depends on which tracker
        // answered first.
        return resolved.sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) }
    }

    private static func fetch(
        _ item: TorznabFeedParser.UnresolvedItem, client: any HTTPClientProtocol
    ) async -> SearchResult? {
        let endpoint = Endpoint(
            baseURL: item.torrentURL,
            path: "",
            timeout: perFileTimeout,
            // One attempt. A retry doubles the load on the indexer for an
            // item that is a bonus rather than the search itself.
            isRetryable: false)
        guard let (data, response) = try? await client.sendRaw(endpoint),
              (200...299).contains(response.statusCode),
              data.count <= maxBytes,
              // **No `expectedInfoHash`.** There is nothing to check it
              // against — the hash is what is being learned here, and the file
              // came from the user's own indexer rather than from a public
              // cache that serves decoys. `TorrentFile` documents the same
              // reasoning for a file read off disk.
              let torrent = TorrentFile.parse(data)
        else { return nil }
        return item.resolved(with: torrent)
    }
}
