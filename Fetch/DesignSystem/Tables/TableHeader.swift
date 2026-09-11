import SwiftUI
import FetchKit

/**
 A table's column titles, which are also its sort control.

 Built from the same `ColumnSet` as its rows, so a title always sits over the
 cells it names. This replaces two header treatments that disagreed about
 font, tracking, height and inset, and the trick of hosting one header inside
 a second scroll-disabled `List` so its inset would match the rows'.

 A column that names a `sortKey` becomes a button; one that does not is a
 label. The chevron is laid out either way, so a heading does not shift
 sideways when it becomes the sorted one.
 */
struct TableHeader<ID: Hashable & Sendable>: View {
    let set: ColumnSet<ID>
    let width: CGFloat
    var activeSort: String?
    var ascending: Bool = false
    var onSort: ((String) -> Void)?

    var body: some View {
        ColumnRow(set: set, width: width) { spec in
            if spec.title.isEmpty && spec.symbol == nil {
                Color.clear
            } else if let key = spec.sortKey, let onSort {
                Button { onSort(key) } label: { label(spec) }
                    .buttonStyle(.plain)
                    .help(spec.help ?? "Sort by \(spec.title.lowercased())")
                    .accessibilityLabel(spec.title.isEmpty ? key : spec.title)
                    .accessibilityAddTraits(isActive(spec) ? [.isButton, .isSelected] : .isButton)
            } else {
                label(spec)
            }
        }
        .frame(height: RowMetrics.headerHeight)
    }

    @ViewBuilder
    private func label(_ spec: ColumnSpec<ID>) -> some View {
        let active = isActive(spec)
        HStack(spacing: Spacing.s2) {
            if spec.alignment == .trailing { Spacer(minLength: 0) }
            if let symbol = spec.symbol {
                Image(systemName: symbol).font(.system(size: IconSize.sm))
            }
            if !spec.title.isEmpty {
                Text(spec.title).lineLimit(1).fixedSize()
            }
            if spec.sortKey != nil {
                Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(active ? 1 : 0)
                    .accessibilityHidden(!active)
            }
            if spec.alignment == .leading { Spacer(minLength: 0) }
        }
        .font(FetchFont.caption2)
        .textCase(.uppercase)
        .tracking(0.7)
        .fontWeight(active ? .semibold : .medium)
        .foregroundStyle(active ? Palette.textPrimary : Palette.textTertiary)
        .contentShape(Rectangle())
    }

    private func isActive(_ spec: ColumnSpec<ID>) -> Bool {
        guard let key = spec.sortKey, let activeSort else { return false }
        return key == activeSort
    }
}
