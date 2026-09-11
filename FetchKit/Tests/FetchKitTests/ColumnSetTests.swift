import Foundation
import Testing
@testable import FetchKit

@Suite("Column sets")
struct ColumnSetTests {
    private enum Col: Hashable, Sendable { case glyph, name, size, rate }

    private var set: ColumnSet<Col> {
        ColumnSet(columns: [
            ColumnSpec(id: .glyph, title: "", sizing: .fixed(24)),
            ColumnSpec(id: .name, title: "NAME", sizing: .flexible(min: 120)),
            ColumnSpec(id: .size, title: "SIZE", sizing: .fixed(64), alignment: .trailing, isNumeric: true),
            ColumnSpec(id: .rate, title: "RATE", sizing: .fixed(80), alignment: .trailing, isNumeric: true, dropsBelow: 700),
        ], gap: 16)
    }

    @Test("Every column is visible in a wide container")
    func wideKeepsAll() {
        #expect(set.visible(in: 1200).map(\.id) == [.glyph, .name, .size, .rate])
    }

    @Test("A column drops below its breakpoint")
    func narrowDropsRate() {
        #expect(set.visible(in: 640).map(\.id) == [.glyph, .name, .size])
    }

    @Test("The breakpoint is inclusive at its own width")
    func exactlyAtBreakpointKeeps() {
        #expect(set.visible(in: 700).map(\.id).contains(.rate))
    }

    @Test("A column with no breakpoint never drops")
    func noBreakpointNeverDrops() {
        #expect(set.visible(in: 1).map(\.id) == [.glyph, .name, .size])
    }

    @Test("without() removes one column and keeps order")
    func withoutRemoves() {
        #expect(set.without(.rate).columns.map(\.id) == [.glyph, .name, .size])
    }

    @Test("without() on an absent id changes nothing")
    func withoutAbsentIsIdentity() {
        #expect(set.without(.rate).without(.rate).columns.map(\.id) == [.glyph, .name, .size])
    }

    @Test("Minimum width sums fixed widths, flexible minimums and the gaps between visible columns")
    func minimumWidth() {
        let wide: CGFloat = 24 + 120 + 64 + 80 + 48
        let narrow: CGFloat = 24 + 120 + 64 + 32
        #expect(set.minimumWidth(in: 1200) == wide)
        #expect(set.minimumWidth(in: 640) == narrow)
    }

    @Test("A column's width can be asked for by id, and an absent one answers nil")
    func widthOfColumn() {
        #expect(set.width(of: .glyph) == 24)
        #expect(set.width(of: .name) == 120)
        #expect(ColumnSet<Col>(columns: [], gap: 16).width(of: .glyph) == nil)
    }

    @Test("Numeric columns declare trailing alignment")
    func numericIsTrailing() {
        for column in set.columns where column.isNumeric {
            #expect(column.alignment == .trailing)
        }
    }
}
