import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct ReleaseMetadataMergerTests {
    // MARK: - Attribute merge

    @Test func attributeOverridesTitleParse() {
        let parsed = ReleaseNameParser.parse("Movie.Name.2020.720p.WEB-DL.x264-GROUP")
        #expect(parsed.resolution == .r720p)

        let merged = ReleaseMetadataMerger.mergingAttributes(["resolution": "1080p"], into: parsed)
        #expect(merged.resolution == .r1080p)
        #expect(merged.provenance[.resolution] == .attribute)
    }

    @Test func provenanceRecordsAttributeSource() {
        let parsed = ReleaseNameParser.parse("Movie.Name.2020.1080p.BluRay.x264-GROUP")
        let merged = ReleaseMetadataMerger.mergingAttributes(
            ["imdb": "1234567", "tvdbid": "80379"], into: parsed
        )
        #expect(merged.imdbID == "tt1234567")
        #expect(merged.provenance[.imdbID] == .attribute)
        #expect(merged.tvdbID == 80379)
        #expect(merged.provenance[.tvdbID] == .attribute)
        // Untouched fields keep their title-parse provenance.
        #expect(merged.provenance[.title] == .titleParse)
        #expect(merged.provenance[.year] == .titleParse)
    }

    @Test func unrecognizedAttributeTokenRoundTripsAsUnknownRatherThanDropping() {
        let parsed = ReleaseNameParser.parse("Movie.Name.2020.1080p.BluRay.x264-GROUP")
        let merged = ReleaseMetadataMerger.mergingAttributes(["resolution": "8K"], into: parsed)
        #expect(merged.resolution == .unknown("8K"))
        #expect(merged.provenance[.resolution] == .attribute)

        // The round trip itself: encode/decode must reproduce the same
        // unrecognized value, not trap and not become nil.
        let data = try! JSONEncoder().encode(merged)
        let decoded = try! JSONDecoder().decode(ReleaseMetadata.self, from: data)
        #expect(decoded.resolution == .unknown("8K"))
    }

    @Test func imdbAttributeWithoutTTPrefixIsNormalized() {
        let parsed = ReleaseNameParser.parse("Movie.Name.2020.1080p.BluRay.x264-GROUP")
        let merged = ReleaseMetadataMerger.mergingAttributes(["imdb": "tt7286456"], into: parsed)
        #expect(merged.imdbID == "tt7286456")
    }

    @Test func emptyAttributesLeaveMetadataUnchanged() {
        let parsed = ReleaseNameParser.parse("Movie.Name.2020.1080p.BluRay.x264-GROUP")
        let merged = ReleaseMetadataMerger.mergingAttributes([:], into: parsed)
        #expect(merged == parsed)
    }

    // MARK: - Two-level merge

    @Test func fileEpisodeWinsOverTorrentSeasonPack() {
        let torrent = ReleaseNameParser.parse("The.Expanse.S03.1080p.BluRay.x265-GROUP")
        #expect(torrent.isSeasonPack)
        #expect(torrent.episodes.isEmpty)

        let file = ReleaseNameParser.parse("The.Expanse.S03E05.mkv")
        let merged = ReleaseMetadataMerger.mergingFile(file, inheritingFrom: torrent)

        #expect(merged.season == 3)
        #expect(merged.episodes == [5])
        #expect(merged.provenance[.episodes] == .titleParse)   // file's own value, not inherited
    }

    @Test func torrentQualityIsInheritedWhenFileNameDoesNotCarryIt() {
        let torrent = ReleaseNameParser.parse("The.Expanse.S03.1080p.BluRay.x265-GROUP")
        let file = ReleaseNameParser.parse("The.Expanse.S03E05.mkv")
        let merged = ReleaseMetadataMerger.mergingFile(file, inheritingFrom: torrent)

        #expect(merged.resolution == .r1080p)
        #expect(merged.provenance[.resolution] == .inherited)
        #expect(merged.source == .bluray)
        #expect(merged.provenance[.source] == .inherited)
        #expect(merged.releaseGroup == "GROUP")
        #expect(merged.provenance[.releaseGroup] == .inherited)
    }

    @Test func fileYearOverridesNothingWhenAbsentAtFileLevel() {
        let torrent = ReleaseNameParser.parse("The.Matrix.1999.1080p.BluRay.x264-SPARKS")
        let file = ReleaseNameParser.parse("A.mkv")   // minimally named file inside the torrent
        let merged = ReleaseMetadataMerger.mergingFile(file, inheritingFrom: torrent)
        #expect(merged.year == 1999)
        #expect(merged.provenance[.year] == .inherited)
    }

    @Test func companionFilesAreExcludedFromNaming() {
        #expect(CompanionFileFilter.isNonMediaCompanion(fileName: "The.Expanse.S03.nfo"))
        #expect(!CompanionFileFilter.isNonMediaCompanion(fileName: "The.Expanse.S03E05.mkv"))
    }

    @Test func fileAudioChannelsWinsOverTorrentAudioChannels() {
        let torrent = ReleaseNameParser.parse("Show.S01.1080p.WEB-DL.DD5.1.x264-GROUP")
        let file = ReleaseNameParser.parse("Show.S01E01.1080p.WEB-DL.DDP5.1.x264-GROUP.mkv")
        let merged = ReleaseMetadataMerger.mergingFile(file, inheritingFrom: torrent)
        #expect(merged.audioChannels == "5.1")
        #expect(merged.audioCodec == .eac3)   // the file's own DDP, not the torrent's plain DD
        #expect(merged.provenance[.audioCodec] == .titleParse)
    }
}
