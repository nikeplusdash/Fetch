import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct FileTreeTests {
    private func file(_ name: String, size: Int64 = 100) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: name), name: name,
            shortName: (name as NSString).lastPathComponent, size: size, mimeType: nil
        )
    }

    @Test func emptyInputProducesEmptyTree() {
        #expect(FileTree.build(from: []).isEmpty)
    }

    @Test func singleFileNoDirectoryProducesOneFileNode() {
        let nodes = FileTree.build(from: [file("movie.mkv")])
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "movie.mkv")
        #expect(nodes[0].children == nil)
        if case .file(let f) = nodes[0].kind {
            #expect(f.name == "movie.mkv")
        } else {
            Issue.record("expected .file kind")
        }
    }

    @Test func nestedPathProducesNestedFolders() {
        let nodes = FileTree.build(from: [file("Show/Season 01/S01E01.mkv")])
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "Show")
        #expect(nodes[0].children?.count == 1)

        let season = try? #require(nodes[0].children?.first)
        #expect(season?.name == "Season 01")
        #expect(season?.children?.count == 1)
        #expect(season?.children?.first?.name == "S01E01.mkv")
    }

    @Test func siblingFilesAtRootAndInFolderBothAppear() {
        let nodes = FileTree.build(from: [
            file("readme.txt", size: 10),
            file("Season 01/S01E01.mkv"),
            file("Season 01/S01E02.mkv"),
        ])
        // Folders sort before files at the same level.
        #expect(nodes.map(\.name) == ["Season 01", "readme.txt"])
        #expect(nodes[0].children?.count == 2)
    }

    @Test func folderAggregateSizeSumsDescendantFiles() {
        let nodes = FileTree.build(from: [
            file("Season 01/S01E01.mkv", size: 1000),
            file("Season 01/S01E02.mkv", size: 2000),
        ])
        #expect(nodes[0].size == 3000)
    }

    @Test func foldersAndFilesSortAlphabeticallyWithinTheirGroup() {
        let nodes = FileTree.build(from: [
            file("b.mkv"), file("a.mkv"),
            file("Zeta/x.mkv"), file("Alpha/y.mkv"),
        ])
        #expect(nodes.map(\.name) == ["Alpha", "Zeta", "a.mkv", "b.mkv"])
    }

    @Test func nodeIDIsTheFullRelativePath() {
        let nodes = FileTree.build(from: [file("Show/Season 01/S01E01.mkv")])
        #expect(nodes[0].id == "Show")
        #expect(nodes[0].children?.first?.id == "Show/Season 01")
        #expect(nodes[0].children?.first?.children?.first?.id == "Show/Season 01/S01E01.mkv")
    }

    @Test func deeplyNestedMultiFileTorrentBuildsCorrectly() {
        let files = [
            file("Movie.1080p.mkv", size: 5_000_000_000),
            file("Extras/Trailer.mkv", size: 50_000_000),
            file("Extras/Behind The Scenes.mkv", size: 100_000_000),
            file("Movie.nfo", size: 1024),
        ]
        let nodes = FileTree.build(from: files)
        #expect(nodes.count == 3)   // "Extras" folder + two root files
        #expect(nodes[0].name == "Extras")
        #expect(nodes[0].children?.count == 2)
        #expect(nodes[0].size == 150_000_000)
    }
}
