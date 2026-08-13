import SwiftUI
import FetchKit
import FetchPluginAPI

/// A file tree that actually looks like one.
///
/// Replaces `OutlineGroup`, which only indents and draws disclosure arrows
/// when it sits inside a `List`. Both pickers render into a `ScrollView` — a
/// `List` inside a fixed-height sheet fought the sheet's own sizing — so
/// `OutlineGroup` produced a correctly *nested* structure rendered as a flat
/// wall of rows. The hierarchy was real and invisible, which is the worst of
/// both.
///
/// So indentation and the chevron are drawn explicitly, per depth.
struct FileTreeOutlineView: View {
    let nodes: [FileTreeNode]
    let checkState: (FileTreeNode) -> Bool?
    let onToggle: (FileTreeNode) -> Void

    /// Which folders are open, by node id.
    @Binding var expanded: Set<String>

    /// Wide enough for the guide rule to be legible as a column, narrow
    /// enough that four levels of an Archive.org collection still leave room
    /// for the filename.
    private static let indent: CGFloat = 14

    var body: some View {
        // Flattened to rows rather than rendered recursively: a SwiftUI view
        // that contains itself cannot infer its own opaque return type, and a
        // flat array keeps the stack lazy — which matters at 2,398 files.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(FileTreeSelection.rows(nodes, expanded: expanded)) { row in
                HStack(spacing: Spacing.s4) {
                    // One rule per level the row sits under, not blank space.
                    // Indentation alone does not read as hierarchy once rows
                    // vary in length — the eye needs a continuous edge to
                    // follow back to the parent, which is what makes a tree
                    // look like a tree rather than a list with margins.
                    ForEach(0..<row.depth, id: \.self) { _ in
                        Rectangle()
                            .fill(Palette.separator)
                            .frame(width: 1)
                            .frame(width: Self.indent, alignment: .leading)
                    }

                    if row.node.isFolder {
                        Button { toggleOpen(row.node.id) } label: {
                            Image(systemName: expanded.contains(row.node.id)
                                  ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.textTertiary)
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Files align with their siblings' names, not with the
                        // parent's chevron.
                        Color.clear.frame(width: 12, height: 1)
                    }

                    FileTreeRowView(
                        node: row.node,
                        checkState: checkState(row.node),
                        onToggle: { onToggle(row.node) })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Folder rows carry a little weight so a season heading is
                // distinguishable from the episodes under it at a glance.
                .background(
                    row.node.isFolder && row.depth == 0
                        ? Palette.rowAlternate.opacity(0.5) : .clear)
            }
        }
    }

    private func toggleOpen(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
