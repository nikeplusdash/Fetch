import Foundation
import FetchPluginAPI

enum TorrentFileResolver {
    static let maxItems = 25
    static let maxConcurrent = 4
    static let perFileTimeout: TimeInterval = 15
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
        return resolved.sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) }
    }

    private static func fetch(
        _ item: TorznabFeedParser.UnresolvedItem, client: any HTTPClientProtocol
    ) async -> SearchResult? {
        let endpoint = Endpoint(
            baseURL: item.torrentURL,
            path: "",
            timeout: perFileTimeout,
            isRetryable: false)
        guard let (data, response) = try? await client.sendRaw(endpoint),
              (200...299).contains(response.statusCode),
              data.count <= maxBytes,
              let torrent = TorrentFile.parse(data)
        else { return nil }
        return item.resolved(with: torrent)
    }
}
