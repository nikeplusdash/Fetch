import Testing
import Foundation
@testable import FetchKit

@Suite struct BookFormatTests {
    private let frankenstein: [String: String] = [
        "text/html": "https://www.gutenberg.org/ebooks/84.html.images",
        "application/epub+zip": "https://www.gutenberg.org/ebooks/84.epub3.images",
        "application/x-mobipocket-ebook": "https://www.gutenberg.org/ebooks/84.kf8.images",
        "application/rdf+xml": "https://www.gutenberg.org/ebooks/84.rdf",
        "image/jpeg": "https://www.gutenberg.org/cache/epub/84/pg84.cover.medium.jpg",
        "application/octet-stream": "https://www.gutenberg.org/cache/epub/84/pg84-h.zip",
        "text/plain; charset=utf-8": "https://www.gutenberg.org/ebooks/84.txt.utf-8",
    ]

    @Test func supplementaryFilesAreExcludedByDefault() {
        let choices = BookFormat.choices(
            from: frankenstein,
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.count == 5)
        #expect(!choices.contains { $0.format.isSupplementary })
    }

    @Test func supplementaryFilesAreLastWhenIncluded() throws {
        let choices = BookFormat.choices(
            from: frankenstein,
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: true)

        #expect(choices.count == 7)
        #expect(choices.first?.format == .epub)
        #expect(choices.suffix(2).allSatisfy { $0.format.isSupplementary })
    }

    @Test func orderFollowsTheConfiguredPriority() {
        let choices = BookFormat.choices(
            from: frankenstein,
            servedBy: GutenbergProvider.fileHost,
            priority: [.text, .html, .epub, .kindle, .htmlZip],
            includingSupplementary: false)

        #expect(choices.map(\.format) == [.text, .html, .epub, .kindle, .htmlZip])
    }

    @Test func plainTextCharsetsCollapseToOneChoicePreferringUTF8() throws {
        let choices = BookFormat.choices(
            from: [
                "text/plain; charset=us-ascii": "https://www.gutenberg.org/files/41445/41445-0.txt",
                "text/plain; charset=utf-8": "https://www.gutenberg.org/ebooks/41445.txt.utf-8",
            ],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.count == 1)
        let text = try #require(choices.first)
        #expect(text.format == .text)
        #expect(text.url.absoluteString.hasSuffix(".txt.utf-8"))
    }

    @Test func equalRankedKeysResolveOnTheMIMEKeyNotOnIterationOrder() throws {
        let choices = BookFormat.choices(
            from: [
                "text/plain; charset=utf-16": "https://www.gutenberg.org/ebooks/41445.txt.utf-16",
                "text/plain; charset=us-ascii": "https://www.gutenberg.org/files/41445/41445-0.txt",
            ],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.count == 1)
        let text = try #require(choices.first)
        #expect(text.url.absoluteString == "https://www.gutenberg.org/files/41445/41445-0.txt")
    }

    @Test func unknownMIMETypesAreDropped() {
        let choices = BookFormat.choices(
            from: ["application/vnd.made-up": "https://www.gutenberg.org/ebooks/1.made-up"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: true)

        #expect(choices.isEmpty)
    }


    @Test func nonHTTPURLsAreRejected() {
        let choices = BookFormat.choices(
            from: ["application/epub+zip": "file:///etc/passwd"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.isEmpty)
    }

    @Test func aURLServedByAnotherHostProducesNoCandidate() {
        let choices = BookFormat.choices(
            from: ["application/epub+zip": "https://attacker.example/x"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.isEmpty)
    }

    @Test func aSubdomainOfTheFileHostIsNotImplied() {
        let choices = BookFormat.choices(
            from: ["application/epub+zip": "https://evil.www.gutenberg.org/ebooks/84.epub3.images"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.isEmpty)
    }

    @Test func anOffHostEntryIsDroppedWithoutDroppingTheBook() {
        var tampered = frankenstein
        tampered["application/epub+zip"] = "https://attacker.example/84.epub"

        let choices = BookFormat.choices(
            from: tampered,
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.count == 4)
        #expect(!choices.contains { $0.format == .epub })
        #expect(choices.allSatisfy { $0.url.host() == GutenbergProvider.fileHost })
    }

    @Test func hostMatchingIsCaseInsensitive() {
        let choices = BookFormat.choices(
            from: ["application/epub+zip": "https://WWW.Gutenberg.ORG/ebooks/84.epub3.images"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.count == 1)
    }
}
