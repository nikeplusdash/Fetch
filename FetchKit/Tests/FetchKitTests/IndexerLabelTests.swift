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

    @Test func severalIndexersBecomeACount() {
        #expect(IndexerLabel.text(for: [id("a"), id("b")], naming: { _ in "X" })
            == "2 indexers")
        #expect(IndexerLabel.text(for: [id("a"), id("b"), id("c")], naming: { _ in "X" })
            == "3 indexers")
    }

    @Test func noSourcesIsAnEmDash() {
        #expect(IndexerLabel.text(for: [], naming: { _ in "X" }) == IndexerLabel.none)
    }

    @Test func anUnresolvedSourceFallsBackToItsRawID() {
        #expect(IndexerLabel.text(for: [id("orphan")], naming: { _ in nil }) == "orphan")
    }

    @Test func unresolvedSourcesStillCount() {
        #expect(IndexerLabel.text(for: [id("a"), id("b")], naming: { _ in nil })
            == "2 indexers")
    }
}
