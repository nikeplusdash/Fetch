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
struct ResultColumns<Ready: View, Kind: View, Name: View,
                     Size: View, Seeds: View, Source: View, Trailing: View>: View {
    /// `.top` for rows, so a two-line title keeps its neighbours on the first
    /// line; `.center` for the header, which is one line by construction.
    var alignment: VerticalAlignment = .center
    @ViewBuilder var ready: Ready
    @ViewBuilder var kind: Kind
    @ViewBuilder var name: Name
    @ViewBuilder var size: Size
    @ViewBuilder var seeds: Seeds
    @ViewBuilder var source: Source
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: alignment, spacing: Spacing.s8) {
            // Leading, not centred. Centred, a badge and a pill of differing
            // intrinsic widths sat at differing offsets down the column, which
            // reads as a wobble rather than as a column.
            ready.frame(width: ColumnWidth.cache, alignment: .leading)
            kind.frame(width: ColumnWidth.kind, alignment: .leading)
            name.frame(maxWidth: .infinity, alignment: .leading)
            size.frame(width: ColumnWidth.size, alignment: .trailing)
            // Leading so the meters line up with each other: centred, a
            // two-digit count pushed its bars left of a one-digit count's.
            seeds.frame(width: ColumnWidth.count, alignment: .leading)
            source.frame(width: ColumnWidth.source, alignment: .trailing)
            trailing
        }
    }
}
