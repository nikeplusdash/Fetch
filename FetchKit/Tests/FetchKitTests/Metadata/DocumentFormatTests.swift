import Testing
import Foundation
@testable import FetchPluginAPI
@testable import FetchKit

/// Stage 7d §3.1. A source-neutral document format, so ranking can say
/// "prefer EPUB over a scanned PDF" without depending on Gutenberg's
/// Gutendex-shaped `BookFormat`.
@Suite struct DocumentFormatTests {
    /// The rule every DTO enum in this file follows: an unrecognized token
    /// round-trips unchanged rather than trapping or becoming nil. A format
    /// Fetch has never seen must survive a save/load cycle, or a user's
    /// profile quietly loses entries.
    @Test func anUnknownFormatRoundTripsUnchanged() throws {
        let encoded = try JSONEncoder().encode(DocumentFormat.unknown("fb2"))
        let decoded = try JSONDecoder().decode(DocumentFormat.self, from: encoded)

        #expect(decoded == .unknown("fb2"))
        #expect(String(data: encoded, encoding: .utf8) == "\"fb2\"")
    }

    @Test func knownFormatsCodeToTheirCanonicalSpelling() throws {
        for format: DocumentFormat in [.epub, .azw3, .mobi, .pdf, .cbz, .cbr, .djvu, .html, .text] {
            let encoded = try JSONEncoder().encode(format)
            let decoded = try JSONDecoder().decode(DocumentFormat.self, from: encoded)
            #expect(decoded == format)
        }
    }

    /// Decoding is case-insensitive like its neighbours: a profile written by
    /// hand, or a provider that spells it "EPUB", must not become `.unknown`
    /// and sort below every ranked format.
    @Test func decodingIsCaseInsensitive() throws {
        let decoded = try JSONDecoder().decode(
            DocumentFormat.self, from: Data("\"EPUB\"".utf8))

        #expect(decoded == .epub)
    }

    // MARK: - BookFormat bridges into it

    /// Gutenberg's Kindle format is KF8, which is AZW3. The mapping is the
    /// only thing that lets a Gutenberg result be ranked against an Internet
    /// Archive one at all.
    @Test func gutenbergsFormatsMapOntoTheNeutralOnes() {
        #expect(BookFormat.epub.documentFormat == .epub)
        #expect(BookFormat.kindle.documentFormat == .azw3)
        #expect(BookFormat.text.documentFormat == .text)
        #expect(BookFormat.html.documentFormat == .html)
        // The HTML-with-images bundle is still HTML; the zip is packaging.
        #expect(BookFormat.htmlZip.documentFormat == .html)
    }

    /// Supplementary files have no document format: a cover is not an edition
    /// of the book, and giving it one would let it be ranked and chosen.
    @Test func supplementaryFilesHaveNoDocumentFormat() {
        #expect(BookFormat.cover.documentFormat == nil)
        #expect(BookFormat.metadata.documentFormat == nil)
    }
}
