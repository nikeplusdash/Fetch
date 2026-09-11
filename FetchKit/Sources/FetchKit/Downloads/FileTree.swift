import Foundation
import FetchPluginAPI

/**
 One node in the hierarchical file tree the picker sheet renders with
 `OutlineGroup` (§12.2) — a torrent's flat file list is unusable
 presented flat for a season pack.
 */
public struct FileTreeNode: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case folder
        case file(DebridFile)
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let children: [FileTreeNode]?

    public var size: Int64 {
        switch kind {
        case .file(let file): file.size
        case .folder: (children ?? []).reduce(0) { $0 + $1.size }
        }
    }

    public var isFolder: Bool { children != nil }
}

/**
 Builds `FileTreeNode` trees from a torrent's flat file list.
 `DebridFile.name` is the file's full path within the torrent (e.g.
 `"Show/Season 01/S01E01.mkv"`) — this splits on `"/"` and groups.
 */
public enum FileTree {
    public static func build(from files: [DebridFile]) -> [FileTreeNode] {
        let root = Builder(name: "", path: "")
        for file in files {
            let components = file.name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { continue }
            root.insert(components: components, file: file, path: "")
        }
        return root.finalizeChildren()
    }

    private final class Builder {
        let name: String
        let path: String
        var file: DebridFile?
        var children: [String: Builder] = [:]
        var childOrder: [String] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func insert(components: [String], file: DebridFile, path parentPath: String) {
            guard let head = components.first else { return }
            let path = parentPath.isEmpty ? head : "\(parentPath)/\(head)"

            let node: Builder
            if let existing = children[head] {
                node = existing
            } else {
                node = Builder(name: head, path: path)
                children[head] = node
                childOrder.append(head)
            }

            if components.count == 1 {
                node.file = file
            } else {
                node.insert(components: Array(components.dropFirst()), file: file, path: path)
            }
        }

        func finalizeChildren() -> [FileTreeNode] {
            let nodes: [FileTreeNode] = childOrder.compactMap { key in
                guard let builder = children[key] else { return nil }
                if builder.children.isEmpty, let file = builder.file {
                    return FileTreeNode(id: builder.path, name: builder.name, kind: .file(file), children: nil)
                }
                return FileTreeNode(
                    id: builder.path, name: builder.name, kind: .folder,
                    children: builder.finalizeChildren()
                )
            }
            return nodes.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
