import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct ArchiveFileSelectionTests {


    @Test func theProfilesFormatOrderDecidesTheWinner() {
        let names = ["book.epub", "book.pdf", "book.mobi"]

        #expect(ArchiveFileSelection.preselected(
            names: names, formatOrder: [.pdf, .epub, .mobi]) == ["book.pdf"])
        #expect(ArchiveFileSelection.preselected(
            names: names, formatOrder: [.mobi, .pdf, .epub]) == ["book.mobi"])
    }

    @Test func anEmptyOrderFallsBackToTheDefault() {
        #expect(ArchiveFileSelection.preselected(
            names: ["book.pdf", "book.epub"], formatOrder: []) == ["book.epub"])
    }


    @Test(arguments: [
        ("book.epub", DocumentFormat.epub), ("book.EPUB", .epub),
        ("book.azw3", .azw3), ("book.mobi", .mobi), ("book.pdf", .pdf),
        ("book.cbz", .cbz), ("book.cbr", .cbr), ("book.djvu", .djvu),
        ("book.html", .html), ("book.htm", .html),
    ]) func extensionsMapToFormats(_ name: String, _ expected: DocumentFormat) {
        #expect(ArchiveFileSelection.format(ofFile: name) == expected)
    }

    @Test func txtIsTheTextFormat() {
        #expect(ArchiveFileSelection.format(ofFile: "book.txt") == .text)
        #expect(ArchiveFileSelection.rank("book.txt", using: [.text, .epub]) == 0)
    }

    @Test func anUnknownOrAbsentExtensionHasNoFormat() {
        #expect(ArchiveFileSelection.format(ofFile: "book.xyz") == nil)
        #expect(ArchiveFileSelection.format(ofFile: "README") == nil)
    }

    @Test func unrankedFilesSortLast() {
        let order: [DocumentFormat] = [.epub, .pdf]
        #expect(ArchiveFileSelection.rank("book.epub", using: order) == 0)
        #expect(ArchiveFileSelection.rank("book.xyz", using: order) == order.count)
        #expect(ArchiveFileSelection.rank("book.mobi", using: order) == order.count)

        #expect(ArchiveFileSelection.preselected(
            names: ["book.nfo", "book.epub"], formatOrder: order) == ["book.epub"])
    }


    @Test func alargeItemPreselectsNothing() {
        let many = (1...ArchiveFileSelection.preselectionLimit + 1).map { "file\($0).epub" }
        #expect(ArchiveFileSelection.preselected(names: many).isEmpty)
    }

    @Test func theLimitItselfStillPreselects() {
        let atLimit = (1...ArchiveFileSelection.preselectionLimit).map { "file\($0).epub" }
        #expect(ArchiveFileSelection.preselected(names: atLimit).count == atLimit.count)
    }


    @Test func distinctStemsAreASetAndAllSurvive() {
        let names = ["chapter1.mp3", "chapter2.mp3", "chapter3.mp3"]
        #expect(ArchiveFileSelection.preselected(names: names) == names)
    }

    @Test func oneSharedStemMeansCompetingFormats() {
        #expect(ArchiveFileSelection.preselected(
            names: ["the-work.epub", "the-work.pdf"]) == ["the-work.epub"])
    }

    @Test func anEmptyItemPreselectsNothing() {
        #expect(ArchiveFileSelection.preselected(names: []).isEmpty)
    }

    @Test func tiesKeepTheItemsOwnOrder() {
        let names = ["work.xyz", "work.abc"]
        #expect(ArchiveFileSelection.preselected(names: names) == ["work.xyz"])
    }

    @Test func theDefaultProfileProducesAWorkingOrder() {
        var profile = QualityProfile.default
        profile.documentFormatOrder = [.pdf, .epub]

        #expect(ArchiveFileSelection.preselected(
            names: ["book.epub", "book.pdf"],
            formatOrder: profile.documentFormatOrder) == ["book.pdf"])
    }


    @Test func aVideoBeatsItsOwnThumbnail() {
        #expect(ArchiveFileSelection.preselected(names: ["2ypfm7.jpg", "2ypfm7.mp4"])
                == ["2ypfm7.mp4"])
    }

    @Test func theVideoWinsWhicheverOrderTheItemListsThemIn() {
        #expect(ArchiveFileSelection.preselected(names: ["clip.mp4", "clip.png"])
                == ["clip.mp4"])
    }

    @Test func audioBeatsCoverArt() {
        #expect(ArchiveFileSelection.preselected(names: ["track.jpg", "track.flac"])
                == ["track.flac"])
    }

    @Test func aBookStillPicksItsBestFormat() {
        #expect(ArchiveFileSelection.preselected(names: ["book.pdf", "book.epub"])
                == ["book.epub"])
    }

    @Test func aBookBeatsItsCover() {
        #expect(ArchiveFileSelection.preselected(names: ["book.jpg", "book.epub"])
                == ["book.epub"])
    }
}
