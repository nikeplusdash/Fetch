import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct FileTreeSelectionTests {
    private func file(_ path: String, _ size: Int64 = 100) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: path), name: path,
            shortName: (path as NSString).lastPathComponent, size: size, mimeType: nil)
    }

    private var tree: [FileTreeNode] {
        FileTree.build(from: [
            file("Show/Season 01/E01.mkv"),
            file("Show/Season 01/E02.mkv"),
            file("Show/Season 02/E01.mkv"),
            file("readme.txt"),
        ])
    }

    private func node(_ path: String) -> FileTreeNode {
        func find(_ nodes: [FileTreeNode]) -> FileTreeNode? {
            for node in nodes {
                if node.id == path { return node }
                if let hit = node.children.flatMap(find) { return hit }
            }
            return nil
        }
        return find(tree)!
    }

    @Test func aFolderCollectsEveryDescendantFile() {
        #expect(FileTreeSelection.leafPaths(under: node("Show")).sorted() == [
            "Show/Season 01/E01.mkv",
            "Show/Season 01/E02.mkv",
            "Show/Season 02/E01.mkv",
        ])
    }

    @Test func anEmptySelectionLeavesEveryFolderUnchecked() {
        #expect(FileTreeSelection.checkState(for: node("Show"), selected: []) == false)
    }

    @Test func aFullyChosenFolderIsChecked() {
        let all = Set(FileTreeSelection.leafPaths(under: node("Show")))
        #expect(FileTreeSelection.checkState(for: node("Show"), selected: all) == true)
    }

    @Test func aPartlyChosenFolderIsMixed() {
        let selected: Set<String> = ["Show/Season 01/E01.mkv"]
        #expect(FileTreeSelection.checkState(for: node("Show"), selected: selected) == nil)
        #expect(FileTreeSelection.checkState(
            for: node("Show/Season 02"), selected: selected) == false)
        #expect(FileTreeSelection.checkState(
            for: node("Show/Season 01"), selected: selected) == nil)
    }

    @Test func togglingAMixedFolderCompletesIt() {
        var selected: Set<String> = ["Show/Season 01/E01.mkv"]
        selected = FileTreeSelection.toggling(node("Show"), in: selected)

        #expect(selected == Set(FileTreeSelection.leafPaths(under: node("Show"))))
    }

    @Test func togglingAFullFolderClearsIt() {
        var selected = Set(FileTreeSelection.leafPaths(under: node("Show")))
        selected = FileTreeSelection.toggling(node("Show"), in: selected)
        #expect(selected.isEmpty)
    }

    @Test func togglingOneFolderLeavesSiblingsAlone() {
        var selected: Set<String> = ["Show/Season 02/E01.mkv"]
        selected = FileTreeSelection.toggling(node("Show/Season 01"), in: selected)

        #expect(selected.contains("Show/Season 02/E01.mkv"))
        #expect(selected.contains("Show/Season 01/E01.mkv"))
    }

    @Test func togglingAFileFlipsOnlyIt() {
        var selected: Set<String> = []
        selected = FileTreeSelection.toggling(node("readme.txt"), in: selected)
        #expect(selected == ["readme.txt"])

        selected = FileTreeSelection.toggling(node("readme.txt"), in: selected)
        #expect(selected.isEmpty)
    }
}

@Suite struct FileTreeRowsTests {
    private func file(_ path: String) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: path), name: path,
            shortName: (path as NSString).lastPathComponent, size: 10, mimeType: nil)
    }

    private var tree: [FileTreeNode] {
        FileTree.build(from: [
            file("Show/Season 01/E01.mkv"),
            file("Show/Season 02/E01.mkv"),
            file("readme.txt"),
        ])
    }

    @Test func closedFoldersHideTheirChildren() {
        let rows = FileTreeSelection.rows(tree, expanded: [])
        #expect(rows.map(\.node.name) == ["Show", "readme.txt"])
        #expect(rows.allSatisfy { $0.depth == 0 })
    }

    @Test func openingAFolderRevealsOneLevel() {
        let rows = FileTreeSelection.rows(tree, expanded: ["Show"])
        #expect(rows.map(\.node.name) == ["Show", "Season 01", "Season 02", "readme.txt"])
    }

    @Test func depthCountsFoldersNotRows() {
        let rows = FileTreeSelection.rows(tree, expanded: ["Show", "Show/Season 01"])
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.node.name, $0.depth) })

        #expect(byName["Show"] == 0)
        #expect(byName["Season 01"] == 1)
        #expect(byName["E01.mkv"] == 2)
        #expect(byName["readme.txt"] == 0)
    }

    @Test func parentsPrecedeChildren() {
        let rows = FileTreeSelection.rows(tree, expanded: FileTreeSelection.folderIDs(tree))
        let names = rows.map(\.node.name)
        #expect(names.firstIndex(of: "Season 01")! < names.firstIndex(of: "E01.mkv")!)
    }

    @Test func folderIDsFindsNestedFolders() {
        #expect(FileTreeSelection.folderIDs(tree) == ["Show", "Show/Season 01", "Show/Season 02"])
    }
}
