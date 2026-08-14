import Testing
import Foundation
@testable import FetchKit

/// Stage 7c §3. Gutendex describes a book's downloads as MIME → URL, so
/// deciding what is a *book* and what is a cover happens here, once.
@Suite struct BookFormatTests {
    /// Book 84 (Frankenstein) verbatim, as returned on 2026-08-02.
    private let frankenstein: [String: String] = [
        "text/html": "https://www.gutenberg.org/ebooks/84.html.images",
        "application/epub+zip": "https://www.gutenberg.org/ebooks/84.epub3.images",
        "application/x-mobipocket-ebook": "https://www.gutenberg.org/ebooks/84.kf8.images",
        "application/rdf+xml": "https://www.gutenberg.org/ebooks/84.rdf",
        "image/jpeg": "https://www.gutenberg.org/cache/epub/84/pg84.cover.medium.jpg",
        "application/octet-stream": "https://www.gutenberg.org/cache/epub/84/pg84-h.zip",
        "text/plain; charset=utf-8": "https://www.gutenberg.org/ebooks/84.txt.utf-8",
    ]

    /// Seven entries in, five books out: the cover and the RDF are not the
    /// book. The count is what proves the filter — asserting only that EPUB
    /// is present would pass with the cover silently included.
    @Test func supplementaryFilesAreExcludedByDefault() {
        let choices = BookFormat.choices(
            from: frankenstein,
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.count == 5)
        #expect(!choices.contains { $0.format.isSupplementary })
    }

    /// It is a downloader; a cover is a legitimate thing to want. But it is
    /// never the book, so it can never be first.
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

    /// `candidates[0]` is what a download with no UI takes. If priority did
    /// not reach it, the setting would be decorative.
    @Test func orderFollowsTheConfiguredPriority() {
        let choices = BookFormat.choices(
            from: frankenstein,
            servedBy: GutenbergProvider.fileHost,
            priority: [.text, .html, .epub, .kindle, .htmlZip],
            includingSupplementary: false)

        #expect(choices.map(\.format) == [.text, .html, .epub, .kindle, .htmlZip])
    }

    /// Two charsets of one file are one choice, not two. Showing both would
    /// offer the user a decision that is not one.
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

    /// Two keys of equal rank for one format — neither is UTF-8, so neither
    /// is preferred — must not resolve by whichever `Dictionary` happened to
    /// yield first. Swift's per-process hash seed makes that order genuinely
    /// nondeterministic, so first-seen-wins would hand the same book a
    /// different URL on a different launch. The MIME key breaks the tie.
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
        // "…charset=us-ascii" sorts before "…charset=utf-16".
        #expect(text.url.absoluteString == "https://www.gutenberg.org/files/41445/41445-0.txt")
    }

    /// A format the table does not model is dropped rather than guessed at:
    /// an unnamed extension would produce a file macOS cannot open.
    @Test func unknownMIMETypesAreDropped() {
        let choices = BookFormat.choices(
            from: ["application/vnd.made-up": "https://www.gutenberg.org/ebooks/1.made-up"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: true)

        #expect(choices.isEmpty)
    }


    /// Origins are attacker-controlled strings (amendment §8). A `file:` URL
    /// here would name a path on the user's own disk.
    @Test func nonHTTPURLsAreRejected() {
        let choices = BookFormat.choices(
            from: ["application/epub+zip": "file:///etc/passwd"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.isEmpty)
    }

    /// `GutenbergProvider.fileHost` was declared for host-pinning that never
    /// happened: the `HTTPClient` carrying the allowlist only ever talks to
    /// the API, and the download goes through `DownloadEngine`, which has no
    /// allowlist at all. A gutendex response naming another origin produced a
    /// candidate the sheet labelled `Frankenstein — Mary Shelley.epub` and
    /// fetched from `attacker.example`. This is where that is stopped.
    @Test func aURLServedByAnotherHostProducesNoCandidate() {
        let choices = BookFormat.choices(
            from: ["application/epub+zip": "https://attacker.example/x"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.isEmpty)
    }

    /// Exact match, the same rule `HTTPClient` applies: a declared host must
    /// not authorise a subdomain of itself, which is the standard way an
    /// allowlist stops meaning anything.
    @Test func aSubdomainOfTheFileHostIsNotImplied() {
        let choices = BookFormat.choices(
            from: ["application/epub+zip": "https://evil.www.gutenberg.org/ebooks/84.epub3.images"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.isEmpty)
    }

    /// One off-host entry must not take the rest of the book with it: the
    /// real formats are still downloadable.
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

    /// Host comparison is case-insensitive — DNS is, and a mixed-case host in
    /// a JSON payload is not an attack, just a spelling.
    @Test func hostMatchingIsCaseInsensitive() {
        let choices = BookFormat.choices(
            from: ["application/epub+zip": "https://WWW.Gutenberg.ORG/ebooks/84.epub3.images"],
            servedBy: GutenbergProvider.fileHost,
            priority: BookFormat.defaultPriority,
            includingSupplementary: false)

        #expect(choices.count == 1)
    }
}
