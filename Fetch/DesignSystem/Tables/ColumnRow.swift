import SwiftUI
import FetchKit

/**
 How tall a row's cells sit and where they line up.

 `single` centres every cell in one band. `stacked` is for a row whose name
 cell carries a subline and a progress track under it: the short cells centre
 against the **first line** rather than against the whole stack, which is what
 stops a tall name from dragging SIZE, RATE and SOURCE down off the optical
 centre of the row.
 */
enum RowLayout: Equatable {
    case single
    case stacked(firstLineHeight: CGFloat)

    var bandHeight: CGFloat {
        switch self {
        case .single: RowMetrics.single
        case .stacked(let firstLine): firstLine
        }
    }

    var isStacked: Bool {
        if case .stacked = self { return true }
        return false
    }
}

/**
 Lays a row's cells out from a `ColumnSet`.

 A table's header and every one of its rows are both this view, given the
 same set, so they cannot be laid out differently. `inset` is the one thing a
 nested row overrides: file rows inside an expanded torrent sit in a card
 that is already inset, and applying the window's own margin again there
 would step them in twice. Numeric columns get their
 monospaced digits and their trailing edge here rather than at each call
 site, which is how SIZE stopped being ragged in one table and not another.
 */
struct ColumnRow<ID: Hashable & Sendable, Cell: View>: View {
    let set: ColumnSet<ID>
    let width: CGFloat
    var layout: RowLayout = .single
    var inset: CGFloat = WindowMetrics.contentInset
    @ViewBuilder let cell: (ColumnSpec<ID>) -> Cell

    var body: some View {
        HStack(alignment: layout.isStacked ? .top : .center, spacing: set.gap) {
            ForEach(set.visible(in: width)) { spec in
                cell(spec)
                    .modifier(NumericCell(isNumeric: spec.isNumeric))
                    .modifier(ColumnCellFrame(spec: spec, band: layout.bandHeight))
            }
        }
        .padding(.horizontal, inset)
    }
}

private struct ColumnCellFrame<ID: Hashable & Sendable>: ViewModifier {
    let spec: ColumnSpec<ID>
    let band: CGFloat

    func body(content: Content) -> some View {
        switch spec.sizing {
        case .fixed(let columnWidth):
            content.frame(width: columnWidth, height: band, alignment: alignment)
        case .flexible:
            content.frame(maxWidth: .infinity, minHeight: band, alignment: alignment)
        }
    }

    private var alignment: Alignment {
        spec.alignment == .trailing ? .trailing : .leading
    }
}

private struct NumericCell: ViewModifier {
    let isNumeric: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isNumeric {
            content.monospacedDigit()
        } else {
            content
        }
    }
}
