import Foundation
import FetchPluginAPI

/// How a result names the indexer or indexers it came from.
///
/// Three views spelled this identically — the two result rows and the search
/// screen's own table — which meant the same result could have been labelled
/// three ways after any one of them was edited.
public enum IndexerLabel {
    /// Shown when a result has no source at all, or none that resolves.
    public static let none = "—"

    /// One indexer gets its name; several get a count, because listing four
    /// server names in a table column truncates to nothing useful.
    ///
    /// `naming` returns nil for an id no configured server claims — a result
    /// still in the list from a server the user has since removed. Those fall
    /// back to the raw id rather than disappearing, so the row stays
    /// explainable instead of silently losing its provenance.
    public static func text(
        for sources: [SearchProviderID],
        naming: (SearchProviderID) -> String?
    ) -> String {
        let names = sources.map { naming($0) ?? $0.rawValue }
        if names.count > 1 { return "\(names.count) indexers" }
        return names.first ?? none
    }
}
