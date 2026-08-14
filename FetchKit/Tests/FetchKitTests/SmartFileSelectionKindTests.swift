import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

/// What the file picker checks when it opens.
@Suite struct SmartFileSelectionKindTests {
    private func file(_ name: String, _ size: Int64) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: name), name: name, shortName: name,
            size: size, mimeType: nil)
    }

    private let mb: Int64 = 1024 * 1024

    /// Unchanged: video over 50 MB.
    @Test func videoOverFiftyMegabytesIsStillSelected() {
        let files = [file("Movie/movie.mkv", 900 * mb), file("Movie/tiny.mkv", 10 * mb)]
        #expect(SmartFileSelection.defaultSelection(for: files) == ["Movie/movie.mkv"])
    }

    @Test func audioOverOneMegabyteIsSelected() {
        let files = [
            file("Album/01.flac", 40 * mb),
            file("Album/02.mp3", 8 * mb),
            file("Album/folder.jpg", 300 * 1024),
        ]
        #expect(SmartFileSelection.defaultSelection(for: files)
            == ["Album/01.flac", "Album/02.mp3"])
    }

    /// No size floor for documents. A plain-text book is under a megabyte and
    /// the EPUB in the design mock is 1.84 MB — a floor would defeat the point.
    @Test func everyDocumentFormatIsSelectedWithNoSizeFloor() {
        let files = [
            file("Book/three-body.epub", 1_840_000),
            file("Book/three-body.pdf", 4 * mb),
            file("Book/three-body.txt", 700_000),
        ]
        #expect(SmartFileSelection.defaultSelection(for: files).count == 2)
        #expect(SmartFileSelection.defaultSelection(for: files)
            .contains("Book/three-body.epub"))
        #expect(SmartFileSelection.defaultSelection(for: files)
            .contains("Book/three-body.pdf"))
    }

    /// `.txt` is not a document format Fetch auto-selects: a torrent's README
    /// and NFO would be checked in every release.
    @Test func plainTextIsNotAutoSelected() {
        #expect(!SmartFileSelection.defaultSelection(for: [file("x/readme.txt", 2000)])
            .contains("x/readme.txt"))
    }

    /// Covers and thumbnails are about the thing, not the thing.
    @Test func imagesAreNeverAutoSelected() {
        let files = [file("Book/cover.jpg", 120 * 1024), file("Book/b.epub", 2 * mb)]
        #expect(SmartFileSelection.defaultSelection(for: files) == ["Book/b.epub"])
    }

    /// The exclusions apply to every kind, and match on the whole path so a
    /// containing folder excludes what is under it.
    @Test func excludedKeywordsApplyToAudioAndDocumentsToo() {
        let files = [
            file("Album/Extras/bonus.mp3", 9 * mb),
            file("Book/sample-chapter.epub", 2 * mb),
            file("Movie/Extras/featurette.mkv", 600 * 1024 * 1024),
        ]
        #expect(SmartFileSelection.defaultSelection(for: files).isEmpty)
    }

    /// A sub-megabyte MP3 is a clip or a sound effect, not a track.
    @Test func tinyAudioIsNotSelected() {
        #expect(SmartFileSelection.defaultSelection(for: [file("a/beep.mp3", 200 * 1024)])
            .isEmpty)
    }
}
