import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// This logic used to live in `ArchiveItemSheet` with a hardcoded format
/// order, which meant the user's Quality › Books preference applied to
/// Gutenberg results and silently did not apply to Archive.org ones. These
/// tests exist because that could not be caught before: the app target has no
/// test bundle.
@Suite struct ArchiveFileSelectionTests {

    // MARK: - The bug that prompted the move

    /// The whole point. A user who ranks PDF first must get the PDF.
    @Test func theProfilesFormatOrderDecidesTheWinner() {
        let names = ["book.epub", "book.pdf", "book.mobi"]

        #expect(ArchiveFileSelection.preselected(
            names: names, formatOrder: [.pdf, .epub, .mobi]) == ["book.pdf"])
        #expect(ArchiveFileSelection.preselected(
            names: names, formatOrder: [.mobi, .pdf, .epub]) == ["book.mobi"])
    }

    /// With no stated preference it falls back to EPUB-over-PDF, which is what
    /// the sheet hardcoded and what §7 specifies.
    @Test func anEmptyOrderFallsBackToTheDefault() {
        #expect(ArchiveFileSelection.preselected(
            names: ["book.pdf", "book.epub"], formatOrder: []) == ["book.epub"])
    }

    // MARK: - Format detection

    @Test(arguments: [
        ("book.epub", DocumentFormat.epub), ("book.EPUB", .epub),
        ("book.azw3", .azw3), ("book.mobi", .mobi), ("book.pdf", .pdf),
        ("book.cbz", .cbz), ("book.cbr", .cbr), ("book.djvu", .djvu),
        ("book.html", .html), ("book.htm", .html),
    ]) func extensionsMapToFormats(_ name: String, _ expected: DocumentFormat) {
        #expect(ArchiveFileSelection.format(ofFile: name) == expected)
    }

    /// `.txt` is the trap: `DocumentFormat` spells this case "text", so
    /// matching the raw extension would miss it and rank every plain-text
    /// file last instead of where the user put it.
    @Test func txtIsTheTextFormat() {
        #expect(ArchiveFileSelection.format(ofFile: "book.txt") == .text)
        #expect(ArchiveFileSelection.rank("book.txt", using: [.text, .epub]) == 0)
    }

    @Test func anUnknownOrAbsentExtensionHasNoFormat() {
        #expect(ArchiveFileSelection.format(ofFile: "book.xyz") == nil)
        #expect(ArchiveFileSelection.format(ofFile: "README") == nil)
    }

    /// An unrankable file must sort *after* every ranked one, never among
    /// them — otherwise a stray `.nfo` can win the preselection.
    @Test func unrankedFilesSortLast() {
        let order: [DocumentFormat] = [.epub, .pdf]
        #expect(ArchiveFileSelection.rank("book.epub", using: order) == 0)
        #expect(ArchiveFileSelection.rank("book.xyz", using: order) == order.count)
        #expect(ArchiveFileSelection.rank("book.mobi", using: order) == order.count)

        #expect(ArchiveFileSelection.preselected(
            names: ["book.nfo", "book.epub"], formatOrder: order) == ["book.epub"])
    }

    // MARK: - The size guard

    /// A collection item must open with nothing checked. Preselecting 2,398
    /// files costs the user their evening and their disk.
    @Test func alargeItemPreselectsNothing() {
        let many = (1...ArchiveFileSelection.preselectionLimit + 1).map { "file\($0).epub" }
        #expect(ArchiveFileSelection.preselected(names: many).isEmpty)
    }

    @Test func theLimitItselfStillPreselects() {
        // All distinct stems, so this is a set and everything is selected.
        let atLimit = (1...ArchiveFileSelection.preselectionLimit).map { "file\($0).epub" }
        #expect(ArchiveFileSelection.preselected(names: atLimit).count == atLimit.count)
    }

    // MARK: - Set versus formats-of-one-work

    /// Different stems means a set the user meant in full, not competing
    /// formats — so nothing is filtered out.
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

    /// Equal ranks fall back to the item's own order rather than something
    /// arbitrary, so the picker is stable across opens.
    @Test func tiesKeepTheItemsOwnOrder() {
        let names = ["work.xyz", "work.abc"]
        #expect(ArchiveFileSelection.preselected(names: names) == ["work.xyz"])
    }

    /// `QualityProfile.documentFormatOrder` is what the app passes in, so it
    /// has to be a usable input here.
    @Test func theDefaultProfileProducesAWorkingOrder() {
        var profile = QualityProfile.default
        profile.documentFormatOrder = [.pdf, .epub]

        #expect(ArchiveFileSelection.preselected(
            names: ["book.epub", "book.pdf"],
            formatOrder: profile.documentFormatOrder) == ["book.pdf"])
    }

    // MARK: - Media items are not books

    /// The observed bug: an Archive item holding `2ypfm7.jpg` (79 KB) and
    /// `2ypfm7.mp4` (7.7 MB) preselected the **jpg**. One stem, so the rule
    /// called them "formats of one work" and ranked them by document format;
    /// neither is a document, so both ranked last-equal and `min(by:)` kept
    /// whichever the item listed first. The user got a thumbnail instead of
    /// the video, filed under Movies.
    @Test func aVideoBeatsItsOwnThumbnail() {
        #expect(ArchiveFileSelection.preselected(names: ["2ypfm7.jpg", "2ypfm7.mp4"])
                == ["2ypfm7.mp4"])
    }

    /// Order must not decide it either way round.
    @Test func theVideoWinsWhicheverOrderTheItemListsThemIn() {
        #expect(ArchiveFileSelection.preselected(names: ["clip.mp4", "clip.png"])
                == ["clip.mp4"])
    }

    @Test func audioBeatsCoverArt() {
        #expect(ArchiveFileSelection.preselected(names: ["track.jpg", "track.flac"])
                == ["track.flac"])
    }

    /// A real document set must keep behaving exactly as it did: this rule is
    /// only allowed to speak where the format ranking has nothing to say.
    @Test func aBookStillPicksItsBestFormat() {
        #expect(ArchiveFileSelection.preselected(names: ["book.pdf", "book.epub"])
                == ["book.epub"])
    }

    /// A cover beside a book is still the book, not the cover.
    @Test func aBookBeatsItsCover() {
        #expect(ArchiveFileSelection.preselected(names: ["book.jpg", "book.epub"])
                == ["book.epub"])
    }
}
