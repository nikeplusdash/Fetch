import Testing
@testable import FetchKit
import FetchPluginAPI

/// Runs `ReleaseNameParser` against every entry in `releaseCorpus` (§14).
/// One `@Test(arguments:)` case per name rather than one giant test — a
/// failure names exactly which release regressed, and `swift test
/// --filter` can re-run a single one while iterating.
@Suite struct ReleaseCorpusTests {
    @Test(arguments: releaseCorpus) func corpusEntryParsesAsExpected(_ testCase: ReleaseCorpusCase) {
        let m = ReleaseNameParser.parse(testCase.name)

        #expect(m.title == testCase.title, "title: \(testCase.name)")
        #expect(m.year == testCase.year, "year: \(testCase.name)")
        #expect(m.mediaKind == testCase.mediaKind, "mediaKind: \(testCase.name)")
        #expect(m.season == testCase.season, "season: \(testCase.name)")
        #expect(m.episodes == testCase.episodes, "episodes: \(testCase.name)")
        #expect(m.absoluteEpisode == testCase.absoluteEpisode, "absoluteEpisode: \(testCase.name)")
        #expect(m.isSeasonPack == testCase.isSeasonPack, "isSeasonPack: \(testCase.name)")
        #expect(m.resolution == testCase.resolution, "resolution: \(testCase.name)")
        #expect(m.source == testCase.source, "source: \(testCase.name)")
        #expect(m.videoCodec == testCase.videoCodec, "videoCodec: \(testCase.name)")
        #expect(m.audioCodec == testCase.audioCodec, "audioCodec: \(testCase.name)")
        #expect(m.audioChannels == testCase.audioChannels, "audioChannels: \(testCase.name)")
        #expect(m.hdr == testCase.hdr, "hdr: \(testCase.name)")
        #expect(m.editions == testCase.editions, "editions: \(testCase.name)")
        #expect(m.languages == testCase.languages, "languages: \(testCase.name)")
        #expect(m.isProper == testCase.isProper, "isProper: \(testCase.name)")
        #expect(m.isRepack == testCase.isRepack, "isRepack: \(testCase.name)")
        #expect(m.releaseGroup == testCase.releaseGroup, "releaseGroup: \(testCase.name)")
        #expect(m.artist == testCase.artist, "artist: \(testCase.name)")
        #expect(m.album == testCase.album, "album: \(testCase.name)")
        #expect(m.author == testCase.author, "author: \(testCase.name)")
        #expect(m.documentFormat == testCase.documentFormat, "documentFormat: \(testCase.name)")
    }

    @Test func corpusIsAtLeastTwoHundredEntries() {
        #expect(releaseCorpus.count >= 200)
    }

    @Test func corpusNamesAreUnique() {
        let names = releaseCorpus.map(\.name)
        #expect(Set(names).count == names.count)
    }
}
