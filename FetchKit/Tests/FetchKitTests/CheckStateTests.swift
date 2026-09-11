import Foundation
import Testing
import FetchPluginAPI
@testable import FetchKit

@Suite("Check state")
struct CheckStateTests {
    private func file(_ path: String) -> FileTreeNode {
        let debrid = DebridFile(
            id: DebridFileID(rawValue: path), name: path,
            shortName: path, size: 10, mimeType: nil)
        return FileTreeNode(id: path, name: path, kind: .file(debrid), children: nil)
    }

    private func folder(_ path: String, _ children: [FileTreeNode]) -> FileTreeNode {
        FileTreeNode(id: path, name: path, kind: .folder, children: children)
    }

    @Test("A selected file is on, an unselected one off")
    func fileStates() {
        #expect(CheckStateRule.state(of: file("a"), selected: ["a"]) == .on)
        #expect(CheckStateRule.state(of: file("a"), selected: []) == .off)
    }

    @Test("A folder whose files are all selected is on")
    func folderAllOn() {
        let tree = folder("f", [file("a"), file("b")])
        #expect(CheckStateRule.state(of: tree, selected: ["a", "b"]) == .on)
    }

    @Test("A folder with some files selected is mixed")
    func folderMixed() {
        let tree = folder("f", [file("a"), file("b")])
        #expect(CheckStateRule.state(of: tree, selected: ["a"]) == .mixed)
    }

    @Test("A folder with no files selected is off")
    func folderOff() {
        let tree = folder("f", [file("a"), file("b")])
        #expect(CheckStateRule.state(of: tree, selected: []) == .off)
    }

    @Test("Mixed propagates up through nesting")
    func nestedMixed() {
        let tree = folder("root", [folder("f", [file("a"), file("b")]), file("c")])
        #expect(CheckStateRule.state(of: tree, selected: ["a", "c"]) == .mixed)
    }

    @Test("A nested folder fully chosen reads on all the way up")
    func nestedAllOn() {
        let tree = folder("root", [folder("f", [file("a"), file("b")]), file("c")])
        #expect(CheckStateRule.state(of: tree, selected: ["a", "b", "c"]) == .on)
    }

    @Test("An empty folder is off, never mixed")
    func emptyFolderIsOff() {
        #expect(CheckStateRule.state(of: folder("f", []), selected: []) == .off)
    }

    @Test("Toggling a mixed folder selects all of its files")
    func toggleMixedSelectsAll() {
        let tree = folder("f", [file("a"), file("b")])
        #expect(CheckStateRule.toggled(tree, in: ["a"]) == ["a", "b"])
    }

    @Test("Toggling a fully selected folder clears its files")
    func toggleOnClears() {
        let tree = folder("f", [file("a"), file("b")])
        #expect(CheckStateRule.toggled(tree, in: ["a", "b"]).isEmpty)
    }

    @Test("Toggling a folder leaves files outside it alone")
    func toggleKeepsOutsiders() {
        let tree = folder("f", [file("a")])
        #expect(CheckStateRule.toggled(tree, in: ["a", "outside"]) == ["outside"])
    }

    @Test("Toggling one file leaves its siblings alone")
    func toggleFileIsLocal() {
        #expect(CheckStateRule.toggled(file("a"), in: ["b"]) == ["a", "b"])
        #expect(CheckStateRule.toggled(file("a"), in: ["a", "b"]) == ["b"])
    }
}
