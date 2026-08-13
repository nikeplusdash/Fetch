import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct SmartFileSelectionTests {
    private func file(_ name: String, size: Int64) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: name), name: name,
            shortName: (name as NSString).lastPathComponent, size: size, mimeType: nil
        )
    }

    private let bigVideo: Int64 = 60 * 1024 * 1024      // over the 50 MB floor
    private let smallVideo: Int64 = 10 * 1024 * 1024    // under it

    @Test func selectsVideoFilesOverFiftyMegabytes() {
        let files = [file("Movie.mkv", size: bigVideo)]
        #expect(SmartFileSelection.defaultSelection(for: files) == ["Movie.mkv"])
    }

    @Test func excludesVideoFilesUnderFiftyMegabytes() {
        let files = [file("Clip.mkv", size: smallVideo)]
        #expect(SmartFileSelection.defaultSelection(for: files).isEmpty)
    }

    @Test func excludesNonVideoFilesRegardlessOfSize() {
        let files = [file("Subtitle.srt", size: bigVideo), file("Readme.nfo", size: bigVideo)]
        #expect(SmartFileSelection.defaultSelection(for: files).isEmpty)
    }

    @Test func excludesSampleTrailerExtrasFeaturetteByPath() {
        let files = [
            file("Movie.Sample.mkv", size: bigVideo),
            file("Extras/Trailer.mkv", size: bigVideo),
            file("Bonus/Featurette.mkv", size: bigVideo),
            file("Extras/Behind.The.Scenes.mkv", size: bigVideo),
        ]
        #expect(SmartFileSelection.defaultSelection(for: files).isEmpty)
    }

    @Test func exclusionMatchIsCaseInsensitive() {
        let files = [file("Movie.SAMPLE.mkv", size: bigVideo)]
        #expect(SmartFileSelection.defaultSelection(for: files).isEmpty)
    }

    @Test func seasonPackSelectsAllQualifyingEpisodesAndSkipsExtras() {
        let files = [
            file("Show/Season 01/S01E01.mkv", size: bigVideo),
            file("Show/Season 01/S01E02.mkv", size: bigVideo),
            file("Show/Season 01/Extras/Trailer.mkv", size: bigVideo),
            file("Show/Season 01/S01E01.srt", size: bigVideo),
        ]
        #expect(SmartFileSelection.defaultSelection(for: files) == [
            "Show/Season 01/S01E01.mkv", "Show/Season 01/S01E02.mkv",
        ])
    }

    @Test func recognizesCommonVideoExtensions() {
        for ext in ["mp4", "mkv", "avi", "mov", "webm", "m4v", "wmv", "ts", "m2ts"] {
            let files = [file("video.\(ext)", size: bigVideo)]
            #expect(
                SmartFileSelection.defaultSelection(for: files) == ["video.\(ext)"],
                "expected .\(ext) to be treated as video"
            )
        }
    }

    @Test func extensionMatchIsCaseInsensitive() {
        let files = [file("Movie.MKV", size: bigVideo)]
        #expect(SmartFileSelection.defaultSelection(for: files) == ["Movie.MKV"])
    }

    @Test func emptyInputProducesEmptySelection() {
        #expect(SmartFileSelection.defaultSelection(for: []).isEmpty)
    }
}
