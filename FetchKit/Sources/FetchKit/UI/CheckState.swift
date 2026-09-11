import Foundation

public enum CheckState: Sendable, Equatable {
    case on, off, mixed
}

/**
 What a checkbox shows for a node in a file tree, and what toggling it does.

 A folder is `mixed` when only some of the files under it are chosen — the
 state the picker had no glyph for, so it drew an empty box and said
 something untrue about the folder. Nesting is followed to the files: a
 folder of folders is `on` only when every file beneath it is chosen.

 Selection is keyed by node id, which `FileTree` sets to the file's path
 within the torrent — the same key the picker sheet already tracks.
 */
public enum CheckStateRule {
    public static func state(of node: FileTreeNode, selected: Set<String>) -> CheckState {
        let ids = fileIDs(of: node)
        guard !ids.isEmpty else { return .off }
        let chosen = ids.filter { selected.contains($0) }.count
        if chosen == 0 { return .off }
        return chosen == ids.count ? .on : .mixed
    }

    /**
     Ticking a folder that is `off` or `mixed` takes all of its files;
     ticking one that is `on` gives them all back. Files elsewhere in the
     tree are never touched.
     */
    public static func toggled(_ node: FileTreeNode, in selected: Set<String>) -> Set<String> {
        let ids = fileIDs(of: node)
        guard !ids.isEmpty else { return selected }
        var next = selected
        if state(of: node, selected: selected) == .on {
            next.subtract(ids)
        } else {
            next.formUnion(ids)
        }
        return next
    }

    private static func fileIDs(of node: FileTreeNode) -> [String] {
        guard let children = node.children else { return [node.id] }
        return children.flatMap(fileIDs)
    }
}
