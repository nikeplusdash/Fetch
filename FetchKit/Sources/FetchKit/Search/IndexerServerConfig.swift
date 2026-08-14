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

/// One indexer reachable through a server — a Prowlarr indexer, or the single
/// endpoint of a standalone Torznab server.
///
/// The id stays a `SearchProviderID` because that is what `SearchAggregator`
/// fans out over and what `SearchResult.sources` records. The two-level shape
/// is a configuration concern; the search layer still sees a flat list.
public struct SubIndexer: Sendable, Codable, Equatable, Identifiable {
    public var id: SearchProviderID
    public var name: String
    public var torznabURL: URL
    public var isEnabled: Bool

    /// Which category pills this indexer is asked for, or nil for all of them.
    ///
    /// **A general Torznab fan-out asks every indexer everything**, and for a
    /// specialised tracker most of that is a wasted round trip the user waits
    /// through: an anime tracker has no answer for a Software query, a
    /// public-domain book site has none for Movies, and both still have to be
    /// asked before the search can finish. Naming the areas an indexer is good
    /// for takes it out of the searches it cannot answer — which shortens the
    /// wait, and stops one tracker's loosely-mapped categories bleeding into a
    /// pill it has no business in.
    ///
    /// **Optional on purpose.** Synthesised `Codable` decodes a missing key
    /// into `nil` only for an optional, so every indexer configured before this
    /// property existed reads back as "every area" rather than failing to
    /// decode — which for this type would silently empty the user's server
    /// list. An empty set means the same thing as nil for the same reason: it
    /// is not a state the UI produces, and reading it as "no areas at all"
    /// would turn a stray write into an indexer that is never asked anything.
    public var areas: Set<SearchCategory>?

    /// What this indexer's own `<caps>` said it carries, recorded at discovery.
    ///
    /// **The answer to "what should I reserve this for?"** Reserving Nyaa.si
    /// for Anime is obvious; reserving Knaben is not, and the only honest
    /// source for that is the indexer's own declaration. Jackett's `t=indexers`
    /// embeds every indexer's caps in the roster, so this costs nothing beyond
    /// the request discovery already makes.
    ///
    /// Optional for the same decoding reason as `areas`, and re-recorded on
    /// every rediscovery rather than kept fresh on a timer — an indexer's
    /// categories change when the user changes them in Jackett, which is a
    /// thing they do in another window and then come back from.
    public var advertisedCategories: [TorznabCategory]?

    /// Wall-clock round trip of the last probe — rather than any
    /// server-reported timing, because that is what the user actually waits
    /// through. Persisted so the edit sheet has something to show before Test
    /// All is pressed.
    public var lastLatency: TimeInterval?

    /// Why the last probe failed, or nil if it succeeded.
    ///
    /// **This replaced a result count**, which was meaningless twice over: the
    /// probe queried one arbitrary fixed term, and a count is only comparable
    /// between indexers of the same scope — an anime tracker returning nine
    /// results for a film query says nothing about the tracker. Worse, a
    /// failure recorded no count and rendered as `0`, so a timed-out indexer
    /// looked exactly like a working one that found nothing.
    public var lastProbeFailure: String?

    public var lastTestedAt: Date?

    /// What this indexer has done across every search, not just the last one.
    ///
    /// Optional for the same decoding reason as `areas`: an indexer stored
    /// before this existed reads back as "nothing recorded yet" rather than
    /// failing to decode and taking the user's whole server list with it.
    public var health: IndexerHealth?
    /// Set when the server no longer lists this indexer. Kept rather than
    /// deleted: an indexer switched off in Prowlarr for an afternoon must not
    /// lose its toggle state here.
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

    /// Records a probe outcome. A success clears any earlier failure, so an
    /// indexer that has been fixed stops being marked broken.
    public mutating func recordProbe(latency: TimeInterval, failure: String?) {
        lastLatency = latency
        lastProbeFailure = failure
        lastTestedAt = Date()
        // Every probe is also a data point. `recordProbe` is already called
        // from the search stream for every indexer on every search, so the
        // history costs nothing beyond the arithmetic.
        var running = health ?? IndexerHealth()
        running.record(latency: latency, failure: failure)
        health = running
    }

    // MARK: - Areas

    /// Whether this indexer is asked for a given pill.
    ///
    /// **`.all` always says yes.** That pill sends no categories at all, so
    /// there is no area to match it against — and a user who reserved a tracker
    /// for Books still wants its books when searching everything. Taking an
    /// indexer out of every search is what its own toggle is for.
    public func serves(_ category: SearchCategory) -> Bool {
        guard let areas, !areas.isEmpty else { return true }
        return category == .all || areas.contains(category)
    }

    /// True when no area has been reserved — the default.
    public var servesEveryArea: Bool { areas?.isEmpty ?? true }

    /// The menu's own label, in pill order so two indexers with the same areas
    /// read the same. Named here rather than in the view because the app target
    /// has no test bundle.
    public var areaSummary: String {
        guard let areas, !areas.isEmpty else { return "Every area" }
        let named = SearchCategory.allCases.filter { areas.contains($0) }
        if named.count > 2 { return "\(named.count) areas" }
        return named.map(\.title).joined(separator: ", ")
    }

    /// What the info icon says this indexer carries, one tree per line.
    ///
    /// **Only the standard tree.** Jackett hands every indexer's own
    /// categories through as well — Nyaa.si advertises 34, of which 25 are
    /// numbers like `140679 Anime` that mean something inside that tracker and
    /// nothing here. They are kept in `advertisedCategories` because they are
    /// what the indexer said, and left out of this because a tooltip listing
    /// them is a tooltip nobody reads.
    ///
    /// Grouped by top-level bucket in ID order, so the shape of what an indexer
    /// covers is readable at a glance rather than a run-on of 30 names.
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

    /// What the edit sheet shows: the wait, and the reason when there was no
    /// answer. Never a count.
    public var probeSummary: String? {
        guard let lastLatency else { return nil }
        let milliseconds = Int((lastLatency * 1000).rounded())
        if let lastProbeFailure { return lastProbeFailure }
        return "\(milliseconds) ms"
    }
}

/// A configured indexer server and the indexers under it.
///
/// **A standalone endpoint is a server with exactly one sub-indexer.** A
/// Jackett aggregate URL, or any hand-entered Torznab endpoint, is stored this
/// way too, so nothing downstream needs to distinguish "one endpoint" from "a
/// Prowlarr with twelve" — they differ in data, not in code path.
///
/// The API key is deliberately absent: it lives only in the credential store
/// under `CredentialAccount(layer: "search", providerID: id.rawValue)`, **one
/// entry per server**. The flat model this replaces stored the same Prowlarr
/// key once per indexer, so rotating it meant N writes where a partial failure
/// left a server half authenticated.
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

    /// Enablement is a conjunction: turning a server off silences everything
    /// under it without touching the individual toggles, so turning it back on
    /// restores exactly the previous selection.
    public var activeIndexers: [SubIndexer] {
        guard isEnabled else { return [] }
        return indexers.filter { $0.isEnabled && !$0.isMissingFromServer }
    }

    /// The active indexers reserved for this pill, which is what a search
    /// actually fans out over.
    ///
    /// Filtered here rather than inside the provider for the same reason
    /// `SearchAggregator.participants(for:)` filters rather than letting each
    /// provider return empty: an indexer that was never asked must not count
    /// toward "3 of 7 indexers", because the shortfall reads as indexers having
    /// failed.
    public func activeIndexers(for category: SearchCategory) -> [SubIndexer] {
        activeIndexers.filter { $0.serves(category) }
    }

    public var enabledCount: Int {
        indexers.filter(\.isEnabled).count
    }
}
