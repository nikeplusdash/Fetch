import Testing
import Foundation
@testable import FetchPluginAPI
@testable import FetchKit

@Suite struct DocumentFormatTests {
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

    @Test func decodingIsCaseInsensitive() throws {
        let decoded = try JSONDecoder().decode(
            DocumentFormat.self, from: Data("\"EPUB\"".utf8))

        #expect(decoded == .epub)
    }


    @Test func gutenbergsFormatsMapOntoTheNeutralOnes() {
        #expect(BookFormat.epub.documentFormat == .epub)
        #expect(BookFormat.kindle.documentFormat == .azw3)
        #expect(BookFormat.text.documentFormat == .text)
        #expect(BookFormat.html.documentFormat == .html)
        #expect(BookFormat.htmlZip.documentFormat == .html)
    }

    @Test func supplementaryFilesHaveNoDocumentFormat() {
        #expect(BookFormat.cover.documentFormat == nil)
        #expect(BookFormat.metadata.documentFormat == nil)
    }
}
