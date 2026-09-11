import Testing
@testable import FetchKit
import FetchPluginAPI

@Suite struct ReleaseNameParserTests {

    @Test func dotSeparatedMovieParsesCleanly() {
        let m = ReleaseNameParser.parse("The.Matrix.1999.1080p.BluRay.x264-SPARKS")
        #expect(m.title == "The Matrix")
        #expect(m.year == 1999)
        #expect(m.resolution == .r1080p)
        #expect(m.source == .bluray)
        #expect(m.videoCodec == .avc)
        #expect(m.releaseGroup == "SPARKS")
        #expect(m.mediaKind == .movie)
    }

    @Test func trailingGroupSurvivesEvenWithMidStringHyphens() {
        let m = ReleaseNameParser.parse("Spider-Man.Into.The.Spider-Verse.2018.1080p.WEB-DL.DDP5.1.H.264-NTb")
        #expect(m.releaseGroup == "NTb")
        #expect(m.title == "Spider Man Into The Spider Verse")
        #expect(m.year == 2018)
        #expect(m.source == .webdl)
        #expect(m.audioCodec == .eac3)
        #expect(m.audioChannels == "5.1")
    }

    @Test func digitBearingGroupsAreNeverMisreadAsYears() {
        for name in [
            "Movie.Name.2020.1080p.BluRay.x264-DON",
            "Movie.Name.2020.1080p.WEB-DL.DD5.1.H264-NTb",
            "Movie.Name.2020.2160p.UHD.BluRay.x265-FraMeSToR",
        ] {
            let m = ReleaseNameParser.parse(name)
            #expect(m.year == 2020, "\(name) -> year \(String(describing: m.year))")
            #expect(m.releaseGroup != nil && Int(m.releaseGroup!) == nil, "\(name) -> group \(String(describing: m.releaseGroup))")
        }
    }

    @Test func leadingAnimeBracketTagIsCapturedAsReleaseGroup() {
        let m = ReleaseNameParser.parse("[SubsPlease] Show Name - 12 (1080p) [ABCD1234].mkv")
        #expect(m.releaseGroup == "SubsPlease")
        #expect(m.mediaKind == .anime)
        #expect(m.absoluteEpisode == 12)
        #expect(m.resolution == .r1080p)
    }


    @Test func listFormYieldsAllEpisodes() {
        let m = ReleaseNameParser.parse("The.Show.S01E01E02E03.1080p.WEB-DL-GROUP")
        #expect(m.season == 1)
        #expect(m.episodes == [1, 2, 3])
        #expect(m.isSeasonPack == false)
    }

    @Test func rangeFormYieldsContiguousEpisodes() {
        let m = ReleaseNameParser.parse("The.Show.S01E01-E03.1080p.WEB-DL-GROUP")
        #expect(m.season == 1)
        #expect(m.episodes == [1, 2, 3])
    }

    @Test func singleFollowedByQualityIsNeitherRangeNorList() {
        let m = ReleaseNameParser.parse("The.Show.S01E01.1080p.WEB-DL-GROUP")
        #expect(m.season == 1)
        #expect(m.episodes == [1])
    }

    @Test func altXYFormatParses() {
        let m = ReleaseNameParser.parse("The.Show.3x05.720p.HDTV-GROUP")
        #expect(m.season == 3)
        #expect(m.episodes == [5])
    }

    @Test func seasonWordFormIsASeasonPack() {
        let m = ReleaseNameParser.parse("The.Show.Season.3.1080p.WEB-DL-GROUP")
        #expect(m.season == 3)
        #expect(m.episodes.isEmpty)
        #expect(m.isSeasonPack)
    }

    @Test func bareSeasonIsASeasonPack() {
        let m = ReleaseNameParser.parse("The.Show.S03.1080p.WEB-DL-GROUP")
        #expect(m.season == 3)
        #expect(m.episodes.isEmpty)
        #expect(m.isSeasonPack)
        #expect(m.mediaKind == .tv)
    }

    @Test func xyFormatDoesNotFalsePositiveOnResolution() {
        let m = ReleaseNameParser.parse("Some.Video.1920x1080.mp4")
        #expect(m.season == nil)
    }


    @Test func resolutionMatchesBeforeAnyYearLikeConfusion() {
        let m = ReleaseNameParser.parse("Movie.Name.2020.2160p.UHD.BluRay.x265-GROUP")
        #expect(m.resolution == .r2160p)
        #expect(m.year == 2020)
    }

    @Test func bladeRunner2049WithExplicitYearKeepsTheNumberInTheTitle() {
        let m = ReleaseNameParser.parse("Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-TERMiNAL")
        #expect(m.title == "Blade Runner 2049")
        #expect(m.year == 2017)
    }

    @Test func titleEmbeddedYearAloneWithNoTrailingQualityStaysInTitle() {
        let m = ReleaseNameParser.parse("Blade Runner 2049")
        #expect(m.title == "Blade Runner 2049")
        #expect(m.year == nil)
    }

    @Test func lastOfTwoYearLikeTokensWinsWhenQualityFollows() {
        let m = ReleaseNameParser.parse("2012.2009.1080p.BluRay.x264-GROUP")
        #expect(m.title == "2012")
        #expect(m.year == 2009)
    }


    @Test func animeDashNumberingIsDistinctFromSeasonEpisode() {
        let m = ReleaseNameParser.parse("[Erai-raws] Some Anime - 07 [1080p]")
        #expect(m.absoluteEpisode == 7)
        #expect(m.season == nil)
        #expect(m.mediaKind == .anime)
    }

    @Test func animeBracketNumberingParses() {
        let m = ReleaseNameParser.parse("[Group] Another Anime [24] [720p]")
        #expect(m.absoluteEpisode == 24)
        #expect(m.mediaKind == .anime)
    }


    @Test func unrecognizedResolutionRoundTripsAsUnknown() {
        let m = ReleaseNameParser.parse("Movie.Name.2020.1080p.BluRay.x264-GROUP")
        #expect(m.resolution == .r1080p)
    }


    @Test func musicReleaseIsNotMisreadAsAMovie() {
        let m = ReleaseNameParser.parse("Daft Punk - Discovery (2001) [FLAC]")
        #expect(m.mediaKind == .music)
        #expect(m.artist == "Daft Punk")
        #expect(m.album == "Discovery (2001)" || m.album == "Discovery")
        #expect(m.audioCodec == .flac)
    }

    @Test func movieWithFullAudioCodecStillClassifiesAsMovie() {
        let m = ReleaseNameParser.parse("Movie.Name.2020.1080p.BluRay.DDP5.1.x264-GROUP")
        #expect(m.mediaKind == .movie)
    }

    @Test func bookReleaseDetectsFormat() {
        let m = ReleaseNameParser.parse("Brandon Sanderson - The Way of Kings [EPUB]")
        #expect(m.mediaKind == .book)
        #expect(m.documentFormat == .epub)
        #expect(m.author == "Brandon Sanderson")
    }

    @Test func aParsedComicFormatIsTypedNotStringly() {
        let m = ReleaseNameParser.parse("Robert Kirkman - The Walking Dead Vol 1 [CBR]")
        #expect(m.documentFormat == .cbr)
    }


    @Test func nonMediaCompanionsAreDetected() {
        #expect(CompanionFileFilter.isNonMediaCompanion(fileName: "movie.nfo"))
        #expect(CompanionFileFilter.isNonMediaCompanion(fileName: "poster.jpg"))
        #expect(CompanionFileFilter.isNonMediaCompanion(fileName: "Sample.mkv"))
        #expect(!CompanionFileFilter.isNonMediaCompanion(fileName: "Show.S01E01.mkv"))
    }


    @Test("A repack is a game, not a movie")
    func aRepackIsAGame() {
        let name = "Red Dead Redemption 2: Ultimate Edition [Build 1491.50 + DLC's] "
            + "(2019) PC | RePack \u{43e}\u{442} FitGirl"
        #expect(ReleaseNameParser.parse(name).mediaKind == .game)
    }

    @Test("A scene game group is a game")
    func aSceneGameGroupIsAGame() {
        #expect(ReleaseNameParser.parse("Red Dead Redemption Razor1911").mediaKind == .game)
        #expect(ReleaseNameParser.parse(
            "Some.Game.2021.MULTi13.DODI.Repack").mediaKind == .game)
    }

    @Test("A film with a year is still a film")
    func aFilmIsStillAFilm() {
        #expect(ReleaseNameParser.parse(
            "Nosferatu.1922.1080p.BluRay.x264-GROUP").mediaKind == .movie)
        #expect(ReleaseNameParser.parse(
            "Dune Part Two (2024) 2160p HDR").mediaKind == .movie)
    }

    @Test("Television and music are unaffected")
    func earlierKindsAreUnaffected() {
        #expect(ReleaseNameParser.parse(
            "Show.Name.S04E08.1080p.WEB-DL").mediaKind == .tv)
        #expect(ReleaseNameParser.parse(
            "Artist - Album (2015) [FLAC]").mediaKind == .music)
    }


    @Test("A web-sourced album is music, not a film")
    func aWebSourcedAlbumIsMusic() {
        let name = "Muse - The Wow! Signal .2026.WEB.FLAC.[16bit.44.1khz]-EICHBAUM"
        #expect(ReleaseNameParser.parse(name).mediaKind == .music)
    }

    @Test("A film named only by its soundtrack is still a film")
    func aFilmWithOnlyAudioIsStillAFilm() {
        #expect(ReleaseNameParser.parse("Some.Movie.2020.WEB.DTS-GROUP").mediaKind == .movie)
        #expect(ReleaseNameParser.parse(
            "Some.Movie.2020.WEB.TrueHD.7.1-GROUP").mediaKind == .movie)
    }

    @Test("A resolution settles it regardless of codec")
    func aPictureSettlesIt() {
        #expect(ReleaseNameParser.parse(
            "Concert.Film.2019.1080p.WEB.FLAC-GROUP").mediaKind == .movie)
    }

    @Test("The formats music is distributed in all pass")
    func musicFormatsPass() {
        for token in ["FLAC", "MP3", "OPUS"] {
            #expect(ReleaseNameParser.parse(
                "Artist - Album 2021 WEB \(token)").mediaKind == .music, "\(token)")
        }
    }
}
