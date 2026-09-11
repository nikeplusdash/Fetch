import Foundation
import Testing
@testable import FetchKit

@Suite("Table columns")
struct TableColumnsTests {
    @Test("Results keep the order the header reads left to right")
    func resultsOrder() {
        #expect(TableColumns.results.columns.map(\.id) == [.cache, .kind, .name, .size, .seeds, .source])
    }

    @Test("Exactly one results column is flexible, and it is the name")
    func resultsOneFlexible() {
        let flexible = TableColumns.results.columns.filter {
            if case .flexible = $0.sizing { return true } else { return false }
        }
        #expect(flexible.map(\.id) == [.name])
    }

    @Test("Size and seeds are numeric, so the renderer right-aligns them with monospaced digits")
    func resultsNumericColumns() {
        let numeric = TableColumns.results.columns.filter(\.isNumeric).map(\.id)
        #expect(numeric == [.size, .seeds])
    }

    @Test("The Library set drops Rate and keeps every other column in order")
    func libraryDropsRate() {
        #expect(TableColumns.downloads(showsRate: false).columns.map(\.id) == [.status, .name, .size, .added])
        #expect(TableColumns.downloads(showsRate: true).columns.map(\.id) == [.status, .name, .size, .rate, .added])
    }

    @Test("Glyph columns carry no title")
    func glyphColumnsHaveNoTitle() {
        #expect(TableColumns.results.columns.first { $0.id == .cache }?.title == "")
        #expect(TableColumns.downloads.columns.first { $0.id == .status }?.title == "")
        #expect(TableColumns.files.columns.first { $0.id == .checkbox }?.title == "")
    }

    @Test("Every set uses the one column gap")
    func oneGap() {
        #expect(TableColumns.results.gap == TableColumns.downloads.gap)
        #expect(TableColumns.downloads.gap == TableColumns.files.gap)
    }

    @Test("File rows are name-flexible with numeric percent and size")
    func fileColumns() {
        #expect(TableColumns.files.columns.map(\.id) == [.checkbox, .glyph, .name, .percent, .size, .control])
        #expect(TableColumns.files.columns.filter(\.isNumeric).map(\.id) == [.percent, .size])
    }
}
