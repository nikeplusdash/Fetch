import Testing
import FetchPluginAPI
@testable import FetchKit

@Suite struct DownloadLibraryTests {
    private struct Row: Equatable {
        let name: String
        let kind: MediaKind
    }

    private func sections(_ rows: [Row]) -> [(kind: MediaKind, rows: [Row])] {
        DownloadLibrary.sections(rows, kind: \.kind, name: \.name)
    }

    /// Fixed order, not by count. A library whose sections reorder themselves
    /// as downloads land is one you cannot learn the shape of.
    @Test func sectionsAppearInAFixedOrderRegardlessOfSize() {
        let rows = [
            Row(name: "Sonata", kind: .music),
            Row(name: "Dune", kind: .movie),
            Row(name: "The Expanse", kind: .tv),
            Row(name: "Also music", kind: .music),
        ]
        #expect(sections(rows).map(\.kind) == [.movie, .tv, .music])
    }

    @Test func emptySectionsAreOmitted() {
        #expect(sections([Row(name: "Dune", kind: .movie)]).map(\.kind) == [.movie])
    }

    @Test func rowsWithinASectionSortByName() {
        let rows = [
            Row(name: "Zulu", kind: .movie),
            Row(name: "arrival", kind: .movie),
            Row(name: "Dune", kind: .movie),
        ]
        #expect(sections(rows).first?.rows.map(\.name) == ["arrival", "Dune", "Zulu"])
    }

    /// `.other` and an unmodelled kind both belong at the end, together —
    /// splitting them would give a section named after whatever string an
    /// indexer happened to send.
    @Test func unmodelledKindsCollectUnderOther() {
        let rows = [
            Row(name: "Mystery", kind: .unknown("hologram")),
            Row(name: "Thing", kind: .other),
            Row(name: "Dune", kind: .movie),
        ]
        let result = sections(rows)
        #expect(result.map(\.kind) == [.movie, .other])
        #expect(result.last?.rows.map(\.name) == ["Mystery", "Thing"])
    }

    @Test func everySectionHasATitle() {
        for kind in DownloadLibrary.sectionOrder {
            #expect(!DownloadLibrary.title(for: kind).isEmpty, "\(kind)")
        }
    }

    @Test func noRowsIsNoSections() {
        #expect(sections([]).isEmpty)
    }
}
