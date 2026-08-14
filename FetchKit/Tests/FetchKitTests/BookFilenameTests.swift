import Testing
import Foundation
@testable import FetchKit

/// Stage 7c §4. Every assertion here is on the **resulting URL**, never on
/// what the string contains — the repo has three bugs and one passing-but-
/// wrong test from doing it the other way.
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

    /// A slash in a remote title must not become a directory. Asserted by
    /// where the file lands, because "the string has no slash" is the check
    /// that shipped broken three times.
    @Test func aTitleContainingASlashStaysInsideTheDestination() {
        let name = BookFilename.make(title: "Either/Or", author: "Kierkegaard", format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(url.pathComponents.count == destination.pathComponents.count + 1)
    }

    /// `..` must not walk up. Again asserted on the parent directory, not on
    /// the characters.
    @Test func aTitleOfDotDotCannotEscapeTheDestination() {
        let name = BookFilename.make(title: "../../etc/passwd", author: nil, format: .text)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(url.path != "/etc/passwd.txt")
    }

    /// A name that is all separators has nothing left after cleaning. It must
    /// still be a file, not an empty component or a hidden dotfile.
    @Test func aTitleWithNothingUsableStillProducesAFile() {
        let name = BookFilename.make(title: "///", author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "epub")
    }

    /// APFS caps a filename at 255 **bytes**. 120 CJK characters is 360
    /// bytes, so a character count would produce a name the filesystem
    /// rejects. The extension must survive the truncation.
    @Test func aLongCJKTitleIsTruncatedByBytesAndKeepsItsExtension() {
        let title = String(repeating: "書", count: 120)
        let name = BookFilename.make(title: title, author: "著者", format: .epub)
        let url = landing(name)

        #expect(name.utf8.count <= BookFilename.byteBudget)
        #expect(url.pathExtension == "epub")
        #expect(url.deletingLastPathComponent().path == destination.path)
    }

    /// Gutendex returns authors surname-first.
    @Test func authorNamesAreReorderedForDisplay() {
        #expect(BookFilename.displayAuthor("Shelley, Mary Wollstonecraft")
            == "Mary Wollstonecraft Shelley")
        #expect(BookFilename.displayAuthor("Homer") == "Homer")
        // Suffixes carry a second comma; only the first is the surname split.
        #expect(BookFilename.displayAuthor("King, Martin Luther, Jr.")
            == "Martin Luther, Jr. King")
    }

    /// A title starting with a literal dot must not produce a hidden file.
    /// This tests the dot-stripping loops in clean().
    @Test func aLeadingDotIsStripped() {
        let name = BookFilename.make(title: ".hidden book", author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "epub")
    }

    /// A title that is all dots must not produce a hidden file.
    /// This tests the dot-stripping loops and Untitled fallback in make().
    @Test func aTitleOfAllDotsStillProducesAVisibleFile() {
        let name = BookFilename.make(title: "...", author: nil, format: .text)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "txt")
    }

    /// A single oversized grapheme cluster (base character + many combining marks)
    /// exceeding the byte budget must not produce a hidden dotfile. The truncation
    /// must fall back to Untitled.
    @Test func anOversizedGraphemeClusterFallsBackToUntitled() {
        // "A" followed by 300 combining acute accents = 1 Swift Character, 601 UTF-8 bytes
        let zalgo = "A" + String(repeating: "\u{0301}", count: 300)
        let name = BookFilename.make(title: zalgo, author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "epub")
    }

    /// A title ending in a dot without starting with one must not create a
    /// double extension like "Mr..epub". This tests the trailing-dot-stripping
    /// loop in clean().
    @Test func aTrailingDotDoesNotCreateADoubleExtension() {
        let name = BookFilename.make(title: "Vol. 1.", author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(url.pathExtension == "epub")
        // Ensure no ".." before the extension (the property being protected)
        #expect(!url.lastPathComponent.contains(".."))
    }

    /// Whitespace and leading dots can interleave in ways that expose a hidden
    /// dotfile if cleaning happens in the wrong order. E.g., " . .foo" becomes
    /// ".foo" if final whitespace trim runs after dot-stripping. This tests the
    /// iterative clean() loop that handles interleaved patterns.
    @Test func leadingWhitespaceAndDotsAreNotExposedLater() {
        let name = BookFilename.make(title: " . .foo", author: nil, format: .epub)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "epub")
    }

    /// A more complex interleaved pattern: dots and spaces at the start with
    /// content after. The iterative cleaning must handle this without exposing
    /// a leading dot.
    @Test func complexInterleavedDotsAndWhitespaceAreHandledCorrectly() {
        let name = BookFilename.make(title: " .. . x", author: nil, format: .text)
        let url = landing(name)

        #expect(url.deletingLastPathComponent().path == destination.path)
        #expect(!url.lastPathComponent.hasPrefix("."))
        #expect(url.pathExtension == "txt")
    }
}
