import Testing
import Foundation
@testable import FetchKit

@Suite struct ItemFolderTests {
    private let destination = URL(fileURLWithPath: "/tmp/fetch-item-folder", isDirectory: true)

    private func landing(_ relativePath: String) -> URL {
        var url = destination
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url.standardizedFileURL
    }

    @Test func aFileLandsInsideTheItemsFolder() {
        let path = ItemFolder.relativePath(folder: "Pokemon Hindi Openings", file: "S01.mp4")
        let url = landing(path)

        #expect(url.deletingLastPathComponent().lastPathComponent == "Pokemon Hindi Openings")
        #expect(url.lastPathComponent == "S01.mp4")
        #expect(url.pathComponents.count == destination.pathComponents.count + 2)
    }

    @Test func nestingInsideTheItemIsPreserved() {
        let path = ItemFolder.relativePath(folder: "Old Cartoons", file: "Show/Season 01/Ep.mkv")
        let url = landing(path)

        #expect(url.lastPathComponent == "Ep.mkv")
        #expect(url.pathComponents.count == destination.pathComponents.count + 4)
        #expect(url.path.hasPrefix(destination.path + "/Old Cartoons/"))
    }

    @Test func aSeparatorInTheItemNameDoesNotBecomeADirectory() {
        let path = ItemFolder.relativePath(folder: "AC/DC Live", file: "track.mp3")
        let url = landing(path)

        #expect(url.pathComponents.count == destination.pathComponents.count + 2)
        #expect(url.lastPathComponent == "track.mp3")
    }

    @Test func traversalInTheItemNameCannotEscape() {
        let path = ItemFolder.relativePath(folder: "../../etc", file: "passwd")
        let url = landing(path)

        #expect(url.path.hasPrefix(destination.path + "/"))
        #expect(url.path != "/etc/passwd")
    }

    @Test func anUnusableFolderNameLeavesTheFileWhereItWas() {
        let path = ItemFolder.relativePath(folder: "   ", file: "book.epub")
        let url = landing(path)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(url.lastPathComponent == "book.epub")
    }

    @Test func groupedPathsLetTheDownloadsRowRecoverTheName() throws {
        let files = ["S01.mp4", "S03.mp4", "S04.mp4"]
        let grouped = files.map { ItemFolder.relativePath(folder: "Pokemon Openings", file: $0) }

        #expect(DownloadGrouping.displayName(forPaths: grouped) == "Pokemon Openings")
        #expect(DownloadGrouping.displayName(forPaths: files) == nil)
    }
}
