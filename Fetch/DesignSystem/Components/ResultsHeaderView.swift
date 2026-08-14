import SwiftUI
import FetchKit

/// The results list's column headings, which are also its sort control.
///
/// Sorting used to live only in the filters panel, as a `Picker` behind a
/// toolbar button — three clicks and a piece of knowledge to reorder a list by
/// size. Every table anyone has ever used sorts by clicking its headings, and
/// this list had headings' worth of fixed columns already; it just never drew
/// them.
///
/// **The widths are the row's own tokens**, not numbers that happen to match.
/// A header aligned by eye drifts the first time a column is retuned, and
/// `ColumnWidth` exists precisely so these two files cannot disagree.
struct ResultsHeaderView: View {
    /// Stated here so the container that pins it can reserve exactly this.
    static let height: CGFloat = 28

    @Environment(AppModel.self) private var model

    var body: some View {
        ResultColumns(
            ready: { heading("", .cache, symbol: "arrow.down.circle",
                             help: "Sort by what downloads straight away") },
            kind: { heading("Type", .kind) },
            name: { heading("Name", .name) },
            size: { heading("Size", .size, alignment: .trailing) },
            // Trailing, over the right edge the pair beneath it now sits on.
            seeds: { heading("Seeds", .seeders, alignment: .trailing) },
            source: { heading("Source", nil, alignment: .trailing) })
        // **Set apart from the rows, not merely smaller.** These were
        // sentence case in the same grey as a secondary value, so a heading
        // read as one more row that happened to be at the top. Small caps,
        // tracked out and quieter still, is the difference between a label for
        // a column and an entry in it.
        .font(FetchFont.caption2)
        .textCase(.uppercase)
        .tracking(0.7)
        .frame(height: Self.height)
        // A hairline of separation, not a slab: the window's own material is
        // already behind this, and painting an opaque bar over it puts a grey
        // rectangle across the top of a frosted window.
        .listRowBackground(Color.clear)
    }

    /// A heading with no sort key is a label, not a button — "Source" is not a
    /// meaningful order and offering it would be a control that does nothing
    /// useful.
    @ViewBuilder
    private func heading(
        _ title: String, _ sort: ResultSort?,
        alignment: Alignment = .leading, symbol: String? = nil, help: String? = nil
    ) -> some View {
        let isActive = sort != nil && model.searchSort == sort
        // The chevron's slot is reserved whether or not it is filled, so
        // sorting by a column does not shove that column's own heading
        // sideways out of line with the values under it.
        let content = HStack(spacing: Spacing.s2) {
            // A spacer on each side that the heading is not pinned to, so
            // `.center` gets both. It had only the two cases and centring a
            // heading would have quietly rendered it leading.
            if alignment != .leading { Spacer(minLength: 0) }
            if let symbol {
                Image(systemName: symbol).font(.system(size: IconSize.sm))
            }
            // One line, always. "Seeds" plus its sort chevron came to more
            // than the column was wide and broke across two, which pushed the
            // heading row taller than the values under it.
            if !title.isEmpty { Text(title).lineLimit(1).fixedSize() }
            Image(systemName: model.sortDescending ? "chevron.down" : "chevron.up")
                .font(.system(size: 8, weight: .bold))
                .opacity(isActive ? 1 : 0)
                .accessibilityHidden(!isActive)
            if alignment != .trailing { Spacer(minLength: 0) }
        }
        .foregroundStyle(isActive ? Palette.textPrimary : Palette.textTertiary)
        .fontWeight(isActive ? .semibold : .medium)
        .contentShape(Rectangle())

        if let sort {
            Button { model.applySort(sort) } label: { content }
                .buttonStyle(.plain)
                .help(help ?? "Sort by \(sort.title.lowercased())")
                .accessibilityLabel(title.isEmpty ? sort.title : title)
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        } else {
            content
        }
    }
}
