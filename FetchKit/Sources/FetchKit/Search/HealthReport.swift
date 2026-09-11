import Foundation
import FetchPluginAPI

/**
 What the Health pane says, and in what order.

 **A table of numbers is not a health screen.** Average latency and a hit
 rate are facts; "this indexer has failed two searches in three, switch it
 off" is the thing worth opening a pane for. The verdicts and the ordering
 live here rather than in the view because they are the actual content —
 and because the app target has no test bundle, so a threshold written in a
 `View` is a threshold nothing checks.
 */
public enum HealthReport {

    /**
     How an indexer is doing, worst first.

     Thresholds are deliberately coarse. The question this answers is "is
     there anything here I should do something about", and a scale with five
     shades of nearly-fine invites reading tea leaves.
     */
    public enum Verdict: Int, Sendable, Comparable, CaseIterable {
        case untested = 0
        case healthy = 1
        case slow = 2
        case unreliable = 3
        case failing = 4

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .untested: "Not used yet"
            case .healthy: "Healthy"
            case .slow: "Slow"
            case .unreliable: "Unreliable"
            case .failing: "Failing"
            }
        }
    }

    public static let failingRate = 0.5
    public static let unreliableRate = 0.2
    public static let slowSeconds: TimeInterval = 10
    public static let minimumAttempts = 4

    public static func verdict(for health: IndexerHealth?) -> Verdict {
        guard let health, health.attempts > 0 else { return .untested }
        if let rate = health.failureRate, health.attempts >= minimumAttempts {
            if rate >= failingRate { return .failing }
            if rate >= unreliableRate { return .unreliable }
        }
        if let average = health.averageLatency, average >= slowSeconds { return .slow }
        return .healthy
    }


    public struct IndexerRow: Identifiable, Sendable, Equatable {
        public let id: SearchProviderID
        public let serverID: IndexerServerID
        public let name: String
        public let isEnabled: Bool
        public let isMissingFromServer: Bool
        public let health: IndexerHealth
        public let verdict: Verdict
        public let areaSummary: String

        public var timings: (fastest: String, slowest: String, average: String)? {
            guard health.answered > 0, health.isConsistent,
                  let fastest = health.fastestLatency
            else { return nil }
            return (
                Self.seconds(fastest),
                Self.seconds(health.slowestLatency),
                Self.seconds(health.averageLatency))
        }

        /**
         Public because the pane formats the same quantities in its own
         rows, and two spellings of "17%" on one screen is one too many.
         */
        public static func percent(_ value: Double?) -> String {
            guard let value else { return "—" }
            return "\(Int((value * 100).rounded()))%"
        }

        public static func seconds(_ value: TimeInterval?) -> String {
            guard let value else { return "—" }
            return value < 1
                ? "\(Int((value * 1000).rounded())) ms"
                : String(format: "%.1fs", value)
        }
    }

    /**
     Every indexer under every server, **worst first**.

     Worst first because the pane exists to surface a problem, not to list an
     inventory: an install with eleven healthy indexers and one that fails
     every search should open on the one that fails. Ties break on slowest
     average, then on name so the order is stable between repaints.

     Disabled indexers are included and sorted last. Leaving them out would
     make the pane forget the thing it just advised you to do.
     */
    public static func indexerRows(_ servers: [IndexerServerConfig]) -> [IndexerRow] {
        servers.flatMap { server in
            server.indexers.map { indexer in
                let health = indexer.health ?? IndexerHealth()
                return IndexerRow(
                    id: indexer.id,
                    serverID: server.id,
                    name: server.indexers.count > 1
                        ? "\(server.displayName) · \(indexer.name)"
                        : server.displayName,
                    isEnabled: server.isEnabled && indexer.isEnabled,
                    isMissingFromServer: indexer.isMissingFromServer,
                    health: health,
                    verdict: verdict(for: indexer.health),
                    areaSummary: indexer.areaSummary)
            }
        }
        .sorted { a, b in
            if a.isEnabled != b.isEnabled { return a.isEnabled }
            if a.verdict != b.verdict { return a.verdict > b.verdict }
            let aSlow = a.health.averageLatency ?? 0
            let bSlow = b.health.averageLatency ?? 0
            if aSlow != bSlow { return aSlow > bSlow }
            return a.name < b.name
        }
    }


    public struct DebridRow: Identifiable, Sendable, Equatable {
        public let id: DebridProviderID
        public let name: String
        public let isEnabled: Bool
        public let canReportCacheStatus: Bool
        public let stats: DebridCacheStats

        public var hitRateText: String {
            guard canReportCacheStatus else { return "Unsupported" }
            guard stats.checked > 0 else { return "" }
            return IndexerRow.percent(stats.hitRate)
        }
    }

    public static let minimumDebridChecks = 25
    public static let coldRate = 0.05

    /**
     Configured services, **best hit rate first**.

     The opposite order to indexers on purpose: this list answers "which of
     these is doing the work", and the one at the top is the answer. A
     service that cannot report goes last — it has no rate to compare.
     */
    public static func debridRows(
        providers: [(id: DebridProviderID, name: String, canReport: Bool, isEnabled: Bool)],
        stats: [DebridProviderID: DebridCacheStats]
    ) -> [DebridRow] {
        providers.map { provider in
            DebridRow(
                id: provider.id,
                name: provider.name,
                isEnabled: provider.isEnabled,
                canReportCacheStatus: provider.canReport,
                stats: stats[provider.id] ?? DebridCacheStats())
        }
        .sorted { a, b in
            if a.canReportCacheStatus != b.canReportCacheStatus {
                return a.canReportCacheStatus
            }
            let aRate = a.stats.hitRate ?? -1
            let bRate = b.stats.hitRate ?? -1
            if aRate != bRate { return aRate > bRate }
            return a.name < b.name
        }
    }


    /**
     What the pane's header says, so the user knows whether to read further.
     */
    public static func headline(_ rows: [IndexerRow]) -> String {
        let live = rows.filter(\.isEnabled)
        guard !live.isEmpty else { return "No indexers are switched on." }
        let bad = live.filter { $0.verdict >= .unreliable }
        guard bad.isEmpty else {
            return bad.count == 1
                ? "\(bad[0].name) is \(bad[0].verdict.title.lowercased())."
                : "\(bad.count) indexers need attention."
        }
        let slow = live.filter { $0.verdict == .slow }
        guard slow.isEmpty else {
            return slow.count == 1
                ? "\(slow[0].name) is slowing searches down."
                : "\(slow.count) indexers are slowing searches down."
        }
        let tested = live.filter { $0.health.attempts > 0 }
        return tested.isEmpty
            ? "Nothing measured yet. Run a search."
            : "All \(live.count) indexers are healthy."
    }
}
