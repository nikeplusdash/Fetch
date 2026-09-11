import Foundation
import FetchPluginAPI

public struct IndexerServerID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from d: any Decoder) throws {
        rawValue = try d.singleValueContainer().decode(String.self)
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer(); try c.encode(rawValue)
    }
}

/**
 One indexer reachable through a server — a Prowlarr indexer, or the single
 endpoint of a standalone Torznab server.

 The id stays a `SearchProviderID` because that is what `SearchAggregator`
 fans out over and what `SearchResult.sources` records. The two-level shape
 is a configuration concern; the search layer still sees a flat list.
 */
public struct SubIndexer: Sendable, Codable, Equatable, Identifiable {
    public var id: SearchProviderID
    public var name: String
    public var torznabURL: URL
    public var isEnabled: Bool

    public var areas: Set<SearchCategory>?

    public var advertisedCategories: [TorznabCategory]?

    public var lastLatency: TimeInterval?

    public var lastProbeFailure: String?

    public var lastTestedAt: Date?

    public var health: IndexerHealth?
    public var isMissingFromServer: Bool

    public init(
        id: SearchProviderID,
        name: String,
        torznabURL: URL,
        isEnabled: Bool = true,
        areas: Set<SearchCategory>? = nil,
        advertisedCategories: [TorznabCategory]? = nil,
        lastLatency: TimeInterval? = nil,
        lastProbeFailure: String? = nil,
        lastTestedAt: Date? = nil,
        health: IndexerHealth? = nil,
        isMissingFromServer: Bool = false
    ) {
        self.id = id
        self.name = name
        self.torznabURL = torznabURL
        self.isEnabled = isEnabled
        self.areas = areas
        self.advertisedCategories = advertisedCategories
        self.lastLatency = lastLatency
        self.lastProbeFailure = lastProbeFailure
        self.lastTestedAt = lastTestedAt
        self.health = health
        self.isMissingFromServer = isMissingFromServer
    }

    /**
     Records a probe outcome. A success clears any earlier failure, so an
     indexer that has been fixed stops being marked broken.
     */
    public mutating func recordProbe(latency: TimeInterval, failure: String?) {
        lastLatency = latency
        lastProbeFailure = failure
        lastTestedAt = Date()
        var running = health ?? IndexerHealth()
        running.record(latency: latency, failure: failure)
        health = running
    }


    /**
     Whether this indexer is asked for a given pill.

     **`.all` always says yes.** That pill sends no categories at all, so
     there is no area to match it against — and a user who reserved a tracker
     for Books still wants its books when searching everything. Taking an
     indexer out of every search is what its own toggle is for.
     */
    public func serves(_ category: SearchCategory) -> Bool {
        guard let areas, !areas.isEmpty else { return true }
        return category == .all || areas.contains(category)
    }

    public var servesEveryArea: Bool { areas?.isEmpty ?? true }

    public var areaSummary: String {
        guard let areas, !areas.isEmpty else { return "Every area" }
        let named = SearchCategory.allCases.filter { areas.contains($0) }
        if named.count > 2 { return "\(named.count) areas" }
        return named.map(\.title).joined(separator: ", ")
    }

    public var advertisedCategorySummary: String? {
        guard let advertisedCategories, !advertisedCategories.isEmpty else { return nil }
        let standard = advertisedCategories.filter { $0.id < 10_000 }
        guard !standard.isEmpty else { return nil }

        var seen: Set<Int> = []
        var byTree: [Int: [TorznabCategory]] = [:]
        for category in standard where seen.insert(category.id).inserted {
            byTree[category.id / 1000 * 1000, default: []].append(category)
        }
        return byTree.keys.sorted().map { tree in
            byTree[tree]!.sorted { $0.id < $1.id }
                .map(\.name)
                .joined(separator: " · ")
        }
        .joined(separator: "\n")
    }

    public var probeSummary: String? {
        guard let lastLatency else { return nil }
        let milliseconds = Int((lastLatency * 1000).rounded())
        if let lastProbeFailure { return lastProbeFailure }
        return "\(milliseconds) ms"
    }
}

/**
 A configured indexer server and the indexers under it.

 **A standalone endpoint is a server with exactly one sub-indexer.** A
 Jackett aggregate URL, or any hand-entered Torznab endpoint, is stored this
 way too, so nothing downstream needs to distinguish "one endpoint" from "a
 Prowlarr with twelve" — they differ in data, not in code path.

 The API key is deliberately absent: it lives only in the credential store
 under `CredentialAccount(layer: "search", providerID: id.rawValue)`, **one
 entry per server**. The flat model this replaces stored the same Prowlarr
 key once per indexer, so rotating it meant N writes where a partial failure
 left a server half authenticated.
 */
public struct IndexerServerConfig: Sendable, Codable, Equatable, Identifiable {
    public var id: IndexerServerID
    public var displayName: String
    public var rootURL: URL
    public var isEnabled: Bool
    public var indexers: [SubIndexer]

    public init(
        id: IndexerServerID,
        displayName: String,
        rootURL: URL,
        isEnabled: Bool = true,
        indexers: [SubIndexer]
    ) {
        self.id = id
        self.displayName = displayName
        self.rootURL = rootURL
        self.isEnabled = isEnabled
        self.indexers = indexers
    }

    public var activeIndexers: [SubIndexer] {
        guard isEnabled else { return [] }
        return indexers.filter { $0.isEnabled && !$0.isMissingFromServer }
    }

    /**
     The active indexers reserved for this pill, which is what a search
     actually fans out over.

     Filtered here rather than inside the provider for the same reason
     `SearchAggregator.participants(for:)` filters rather than letting each
     provider return empty: an indexer that was never asked must not count
     toward "3 of 7 indexers", because the shortfall reads as indexers having
     failed.
     */
    public func activeIndexers(for category: SearchCategory) -> [SubIndexer] {
        activeIndexers.filter { $0.serves(category) }
    }

    public var enabledCount: Int {
        indexers.filter(\.isEnabled).count
    }
}
