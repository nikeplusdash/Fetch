import Testing
import Foundation
@testable import FetchKit

/// A source item's files must land together, the way a torrent's do.
///
/// Found by running the app: eight files from one Internet Archive item landed
/// loose in `Movies/`, and the Downloads row said "8 files" instead of naming
/// the item. One cause, both symptoms — a torrent's relative path carries its
/// folder (`Tame Impala - 2025 - Deadbeat/folder.jpg`), so the files group on
/// disk *and* `DownloadGrouping.displayName` recovers the name from the shared
/// root. An IA item's path is relative to the item, so the item's identity was
/// dropped at enqueue.
@Suite struct ItemFolderTests {
    private let destination = URL(fileURLWithPath: "/tmp/fetch-item-folder", isDirectory: true)

    /// Where the file lands, never what the string contains — the repo has
    /// three bugs from doing it the other way.
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

    /// An IA item is a folder tree — `Show/Season 01/Ep.mkv` — and that nesting
    /// is real structure the picker showed the user. It has to survive.
    @Test func nestingInsideTheItemIsPreserved() {
        let path = ItemFolder.relativePath(folder: "Old Cartoons", file: "Show/Season 01/Ep.mkv")
        let url = landing(path)

        #expect(url.lastPathComponent == "Ep.mkv")
        #expect(url.pathComponents.count == destination.pathComponents.count + 4)
        #expect(url.path.hasPrefix(destination.path + "/Old Cartoons/"))
    }

    /// The item name is remote text. A separator in it must not become a
    /// directory level the source chose.
    @Test func aSeparatorInTheItemNameDoesNotBecomeADirectory() {
        let path = ItemFolder.relativePath(folder: "AC/DC Live", file: "track.mp3")
        let url = landing(path)

        #expect(url.pathComponents.count == destination.pathComponents.count + 2)
        #expect(url.lastPathComponent == "track.mp3")
    }

    /// Traversal in the item name must not walk out of the destination.
    @Test func traversalInTheItemNameCannotEscape() {
        let path = ItemFolder.relativePath(folder: "../../etc", file: "passwd")
        let url = landing(path)

        #expect(url.path.hasPrefix(destination.path + "/"))
        #expect(url.path != "/etc/passwd")
    }

    /// No usable folder name means no folder — one file at the root beats one
    /// file inside a directory called "Untitled", which is where a user would
    /// never think to look.
    @Test func anUnusableFolderNameLeavesTheFileWhereItWas() {
        let path = ItemFolder.relativePath(folder: "   ", file: "book.epub")
        let url = landing(path)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(url.lastPathComponent == "book.epub")
    }

    /// The grouping fix is the point, not a side effect: with the folder in
    /// the path, the Downloads row recovers the item's name instead of
    /// counting files.
    @Test func groupedPathsLetTheDownloadsRowRecoverTheName() throws {
        let files = ["S01.mp4", "S03.mp4", "S04.mp4"]
        let grouped = files.map { ItemFolder.relativePath(folder: "Pokemon Openings", file: $0) }

        #expect(DownloadGrouping.displayName(forPaths: grouped) == "Pokemon Openings")
        // What it did before the fix, and what the user saw.
        #expect(DownloadGrouping.displayName(forPaths: files) == nil)
    }
}
