import SwiftUI

/// The results list's columns, declared once.
///
/// **Six attempts failed before this existed.** The header and the rows each
/// built their own `HStack` and each applied its own `.frame(width:)` calls
/// from the same `ColumnWidth` constants — which looks like sharing and is
/// not. Every fix matched one more number and left the next mismatch to be
/// discovered from a screenshot: the list's row inset, a section's content
/// indent, a safe-area inset, and finally six points of horizontal padding
/// hidden inside `ResultRowChrome`.
///
/// Two view trees that must agree about geometry will not, however carefully
/// they are written. There is one tree now. A column's width, its alignment
/// and the gap between them are stated here and nowhere else, so the header
/// cannot drift from the rows because there is nothing left to drift.
/// **The row's actions are not a column, and no longer an overlay either.**
/// They were a column once, reserving 64 points at the trailing edge so that
/// revealing them on hover could not shift anything — which worked, and left
/// Source stranded 64 points short of the right-hand edge with dead space
/// beyond it. Then they were an overlay over that trailing edge, which fixed
/// the dead space and covered the indexer name instead: the one column a
/// reader checks to see *where* a result came from, hidden by two buttons
/// acting on something a whole table's width away.
///
/// They now sit at the end of the **name** column, where the thing they act on
/// is. Their reserved width makes the name that much shorter, which is a
/// column giving up space it has rather than a column being covered up.
struct ResultColumns<Ready: View, Kind: View, Name: View,
                     Size: View, Seeds: View, Source: View>: View {
    /// `.top` for rows, so a two-line title keeps its neighbours on the first
    /// line; `.center` for the header, which is one line by construction.
    var alignment: VerticalAlignment = .center
    @ViewBuilder var ready: Ready
    @ViewBuilder var kind: Kind
    @ViewBuilder var name: Name
    @ViewBuilder var size: Size
    @ViewBuilder var seeds: Seeds
    @ViewBuilder var source: Source

    var body: some View {
        HStack(alignment: alignment, spacing: Spacing.s8) {
            // Leading, not centred. Centred, a badge and a pill of differing
            // intrinsic widths sat at differing offsets down the column, which
            // reads as a wobble rather than as a column.
            ready.frame(width: ColumnWidth.cache, alignment: .leading)
            kind.frame(width: ColumnWidth.kind, alignment: .leading)
            name.frame(maxWidth: .infinity, alignment: .leading)
            size.frame(width: ColumnWidth.size, alignment: .trailing)
            // Trailing, against the right edge of its column like the two
            // numeric columns beside it. The pair is a constant width — the
            // meter and the count each have a reserved slot — so pinning it to
            // either edge keeps the bars in one line down the column and the
            // digits in another.
            seeds.frame(width: ColumnWidth.count, alignment: .trailing)
            source.frame(width: ColumnWidth.source, alignment: .trailing)
        }
    }
}
