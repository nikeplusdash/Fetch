import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct IndexerLabelTests {
    private func id(_ raw: String) -> SearchProviderID { SearchProviderID(rawValue: raw) }

    @Test func oneKnownIndexerGetsItsName() {
        #expect(IndexerLabel.text(for: [id("a")], naming: { _ in "Prowlarr · 1337x" })
            == "Prowlarr · 1337x")
    }

    /// Several become a count: four server names in a table column truncate to
    /// nothing a user can read.
    @Test func severalIndexersBecomeACount() {
        #expect(IndexerLabel.text(for: [id("a"), id("b")], naming: { _ in "X" })
            == "2 indexers")
        #expect(IndexerLabel.text(for: [id("a"), id("b"), id("c")], naming: { _ in "X" })
            == "3 indexers")
    }

    @Test func noSourcesIsAnEmDash() {
        #expect(IndexerLabel.text(for: [], naming: { _ in "X" }) == IndexerLabel.none)
    }

    /// A result from a server the user has since removed keeps its raw id
    /// rather than vanishing — the row stays explainable.
    @Test func anUnresolvedSourceFallsBackToItsRawID() {
        #expect(IndexerLabel.text(for: [id("orphan")], naming: { _ in nil }) == "orphan")
    }

    /// The count does not care whether the names resolved, so a removed server
    /// still contributes to "2 indexers" rather than silently dropping out.
    @Test func unresolvedSourcesStillCount() {
        #expect(IndexerLabel.text(for: [id("a"), id("b")], naming: { _ in nil })
            == "2 indexers")
    }
}
