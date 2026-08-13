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
    /// Set when the server no longer lists this indexer. Kept rather than
    /// deleted: an indexer switched off in Prowlarr for an afternoon must not
    /// lose its toggle state here.
    public var isMissingFromServer: Bool

    public init(
        id: SearchProviderID,
        name: String,
        torznabURL: URL,
        isEnabled: Bool = true,
        lastLatency: TimeInterval? = nil,
        lastProbeFailure: String? = nil,
        lastTestedAt: Date? = nil,
        isMissingFromServer: Bool = false
    ) {
        self.id = id
        self.name = name
        self.torznabURL = torznabURL
        self.isEnabled = isEnabled
        self.lastLatency = lastLatency
        self.lastProbeFailure = lastProbeFailure
        self.lastTestedAt = lastTestedAt
        self.isMissingFromServer = isMissingFromServer
    }

    /// Records a probe outcome. A success clears any earlier failure, so an
    /// indexer that has been fixed stops being marked broken.
    public mutating func recordProbe(latency: TimeInterval, failure: String?) {
        lastLatency = latency
        lastProbeFailure = failure
        lastTestedAt = Date()
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

    public var enabledCount: Int {
        indexers.filter(\.isEnabled).count
    }
}
