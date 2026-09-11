import Testing
import Foundation
@testable import FetchKit

@Suite struct BookFilenameTests {
    private let destination = URL(fileURLWithPath: "/tmp/fetch-test-destination", isDirectory: true)

    private func landing(_ name: String) -> URL {
        destination.appendingPathComponent(name).standardizedFileURL
    }

    @Test func nameCombinesTitleAuthorAndExtension() {
        let name = BookFilename.make(
            title: "Frankenstein; or, the Modern Prometheus",
            author: "Mary Wollstonecraft Shelley",
            format: .epub)

        #expect(landing(name).lastPathComponent
            == "Frankenstein; or, the Modern Prometheus — Mary Wollstonecraft Shelley.epub")
    }

    @Test func missingAuthorLeavesTheTitleAlone() {
        let name = BookFilename.make(title: "Beowulf", author: nil, format: .text)
        #expect(landing(name).lastPathComponent == "Beowulf.txt")
    }

    @Test func aTitleContainingASlashStaysInsideTheDestination() {
        let name = BookFilename.make(title: "Either/Or", author: "Kierkegaard", format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(url.pathComponents.count == destination.pathComponents.count + 1)
    }

    @Test func aTitleOfDotDotCannotEscapeTheDestination() {
        let name = BookFilename.make(title: "../../etc/passwd", author: nil, format: .text)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(url.path != "/etc/passwd.txt")
    }

    @Test func aTitleWithNothingUsableStillProducesAFile() {
        let name = BookFilename.make(title: "///", author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "epub")
    }

    @Test func aLongCJKTitleIsTruncatedByBytesAndKeepsItsExtension() {
        let title = String(repeating: "書", count: 120)
        let name = BookFilename.make(title: title, author: "著者", format: .epub)
        let url = landing(name)

        #expect(name.utf8.count <= BookFilename.byteBudget)
        #expect(url.pathExtension == "epub")
        #expect(url.deletingLastPathComponent().path == destination.path)
    }

    @Test func authorNamesAreReorderedForDisplay() {
        #expect(BookFilename.displayAuthor("Shelley, Mary Wollstonecraft")
            == "Mary Wollstonecraft Shelley")
        #expect(BookFilename.displayAuthor("Homer") == "Homer")
        #expect(BookFilename.displayAuthor("King, Martin Luther, Jr.")
            == "Martin Luther, Jr. King")
    }

    @Test func aLeadingDotIsStripped() {
        let name = BookFilename.make(title: ".hidden book", author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "epub")
    }

    @Test func aTitleOfAllDotsStillProducesAVisibleFile() {
        let name = BookFilename.make(title: "...", author: nil, format: .text)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "txt")
    }

    @Test func anOversizedGraphemeClusterFallsBackToUntitled() {
        let zalgo = "A" + String(repeating: "\u{0301}", count: 300)
        let name = BookFilename.make(title: zalgo, author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "epub")
    }

    @Test func aTrailingDotDoesNotCreateADoubleExtension() {
        let name = BookFilename.make(title: "Vol. 1.", author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(url.pathExtension == "epub")
        #expect(!url.lastPathComponent.contains(".."))
    }

    @Test func leadingWhitespaceAndDotsAreNotExposedLater() {
        let name = BookFilename.make(title: " . .foo", author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "epub")
    }

    @Test func complexInterleavedDotsAndWhitespaceAreHandledCorrectly() {
        let name = BookFilename.make(title: " .. . x", author: nil, format: .text)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "txt")
    }
}
