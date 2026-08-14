import Foundation
import FetchPluginAPI

/// Tri-state selection over a `FileTreeNode` tree (§12.2).
///
/// Lives here rather than in the picker view for two reasons: two pickers now
/// need it — a torrent's files and an Internet Archive item's — and the app
/// target has no test target, so logic that stays in a view is asserted only
/// by looking at it.
public enum FileTreeSelection {
    /// Every file path under `node`, or the node's own path when it is a file.
    public static func leafPaths(under node: FileTreeNode) -> [String] {
        switch node.kind {
        case .file: [node.id]
        case .folder: (node.children ?? []).flatMap(leafPaths(under:))
        }
    }

    /// `true` all, `false` none, **`nil` mixed**.
    ///
    /// Mixed has to be its own state: rendered as unchecked it would tell the
    /// user nothing under a folder is selected while three episodes are
    /// queued.
    public static func checkState(for node: FileTreeNode, selected: Set<String>) -> Bool? {
        switch node.kind {
        case .file:
            return selected.contains(node.id)
        case .folder:
            let leaves = leafPaths(under: node)
            guard !leaves.isEmpty else { return false }
            let count = leaves.filter(selected.contains).count
            if count == 0 { return false }
            if count == leaves.count { return true }
            return nil
        }
    }

    /// Selecting or clearing everything under `node`.
    ///
    /// A **mixed** folder completes rather than clears. Clearing would throw
    /// away choices the user already made, which is the destructive reading of
    /// an ambiguous click; completing is recoverable with one more click.
    public static func toggling(_ node: FileTreeNode, in selected: Set<String>) -> Set<String> {
        let leaves = leafPaths(under: node)
        var selected = selected
        if leaves.allSatisfy(selected.contains) {
            leaves.forEach { selected.remove($0) }
        } else {
            leaves.forEach { selected.insert($0) }
        }
        return selected
    }
}

/// The rows a tree shows for a given set of open folders.
///
/// Flattened rather than rendered recursively: a recursive SwiftUI view cannot
/// infer its own opaque return type, and a flat array lets the list stay lazy —
/// which matters when the tree is 2,398 files.
public struct FileTreeRow: Identifiable, Sendable, Equatable {
    public let node: FileTreeNode
    /// How many folders deep, for indentation.
    public let depth: Int
    public var id: String { node.id }
}

public extension FileTreeSelection {
    /// Depth-first, parents before children, skipping anything under a closed
    /// folder.
    static func rows(
        _ nodes: [FileTreeNode], expanded: Set<String>, depth: Int = 0
    ) -> [FileTreeRow] {
        var out: [FileTreeRow] = []
        for node in nodes {
            out.append(FileTreeRow(node: node, depth: depth))
            if node.isFolder, expanded.contains(node.id), let children = node.children {
                out.append(contentsOf: rows(children, expanded: expanded, depth: depth + 1))
            }
        }
        return out
    }

    /// Every folder id in the tree, for "expand all".
    static func folderIDs(_ nodes: [FileTreeNode]) -> Set<String> {
        var out: Set<String> = []
        for node in nodes where node.isFolder {
            out.insert(node.id)
            out.formUnion(folderIDs(node.children ?? []))
        }
        return out
    }
}
