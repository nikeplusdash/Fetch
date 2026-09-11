import SwiftUI
import FetchKit
import FetchPluginAPI

/**
 A file tree that actually looks like one.

 Replaces `OutlineGroup`, which only indents and draws disclosure arrows
 when it sits inside a `List`. Both pickers render into a `ScrollView` — a
 `List` inside a fixed-height sheet fought the sheet's own sizing — so
 `OutlineGroup` produced a correctly *nested* structure rendered as a flat
 wall of rows. The hierarchy was real and invisible, which is the worst of
 both.

 **The rows own their own grid now.** This used to draw the indentation and
 the chevron itself, in front of a `FileTreeRowView` that started at the
 checkbox — so the depth pushed every column of the row sideways and the
 sheet had no columns, only rows that happened to line up at one depth. It
 hands `depth` to the row and the row spends it inside the name cell alone.

 It measures its own width for the rows' column set rather than taking one:
 both sheets that show a tree put it in a `ScrollView` that already decides
 how wide it is.
 */
struct FileTreeOutlineView: View {
    let nodes: [FileTreeNode]
    let checkState: (FileTreeNode) -> CheckState
    let onToggle: (FileTreeNode) -> Void

    @Binding var expanded: Set<String>

    @State private var width: CGFloat = 0

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(FileTreeSelection.rows(nodes, expanded: expanded)) { row in
                FileTreeRowView(
                    node: row.node,
                    depth: row.depth,
                    width: width,
                    checkState: checkState(row.node),
                    isExpanded: row.node.isFolder
                        ? expanded.contains(row.node.id) : nil,
                    onToggleExpanded: row.node.isFolder
                        ? { toggleOpen(row.node.id) } : nil,
                    onToggle: { onToggle(row.node) })
                    .background(
                        row.node.isFolder && row.depth == 0
                            ? Palette.rowAlternate.opacity(0.5) : .clear)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func toggleOpen(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
