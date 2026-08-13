import FetchPluginAPI

/// One pinned expectation for `ReleaseNameParser` (§14's "checked-in
/// corpus of ~200 real release names"). Only `name` and `mediaKind` are
/// required; every other field defaults to the parser's "absent" value, so
/// each entry only spells out what it actually asserts.
///
/// Fixing a reported misparse means adding the failing name here *first*,
/// with the field values it *should* produce, then making the parser
/// produce them — never loosening an assertion to make a name pass.
struct ReleaseCorpusCase: Sendable {
    let name: String
    let title: String?
    let year: Int?
    let mediaKind: MediaKind
    let season: Int?
    let episodes: [Int]
    let absoluteEpisode: Int?
    let isSeasonPack: Bool
    let resolution: Resolution?
    let source: ReleaseSource?
    let videoCodec: VideoCodec?
    let audioCodec: AudioCodec?
    let audioChannels: String?
    let hdr: HDRFormat?
    let editions: [Edition]
    let languages: [String]
    let isProper: Bool
    let isRepack: Bool
    let releaseGroup: String?
    let artist: String?
    let album: String?
    let author: String?
    let documentFormat: DocumentFormat?

    init(
        name: String,
        title: String? = nil,
        year: Int? = nil,
        mediaKind: MediaKind,
        season: Int? = nil,
        episodes: [Int] = [],
        absoluteEpisode: Int? = nil,
        isSeasonPack: Bool = false,
        resolution: Resolution? = nil,
        source: ReleaseSource? = nil,
        videoCodec: VideoCodec? = nil,
        audioCodec: AudioCodec? = nil,
        audioChannels: String? = nil,
        hdr: HDRFormat? = nil,
        editions: [Edition] = [],
        languages: [String] = [],
        isProper: Bool = false,
        isRepack: Bool = false,
        releaseGroup: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        author: String? = nil,
        documentFormat: DocumentFormat? = nil
    ) {
        self.name = name
        self.title = title
        self.year = year
        self.mediaKind = mediaKind
        self.season = season
        self.episodes = episodes
        self.absoluteEpisode = absoluteEpisode
        self.isSeasonPack = isSeasonPack
        self.resolution = resolution
        self.source = source
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.hdr = hdr
        self.editions = editions
        self.languages = languages
        self.isProper = isProper
        self.isRepack = isRepack
        self.releaseGroup = releaseGroup
        self.artist = artist
        self.album = album
        self.author = author
        self.documentFormat = documentFormat
    }
}

/// ~215 real release names spanning movies, TV, anime, music, and books.
/// Every ambiguity named in §8/§14 has at least one entry:
///
/// - `2160p` next to a real year: `Dune.Part.Two.2024...2160p...` (line 36
///   in the movies block) and `Tenet.2020.2160p...` — resolution and year
///   both come out right despite sitting next to each other.
/// - `Blade Runner 2049`, with and without an explicit release year, and
///   `2012.2009...` (the movie titled "2012") — the last-4-digit-token /
///   "only if a quality token follows" rule (§8).
/// - Digit-bearing groups (`-DON`, `-NTb`, `-FraMeSToR`) never misread as
///   years — see the `digitBearingGroupsAreNeverMisreadAsYears` block
///   mirrored here via `The.Wire...GROUP`-style names throughout, plus the
///   dedicated `Movie.Name.2020...-DON`/`-FraMeSToR` entries.
/// - `S01E01-E03` (range) vs `S01E01E02E03(E04)` (list) vs plain `S01E01`:
///   `The.Wire.S01E01-E03...` / `The.Wire.S01E01E02E03E04...` /
///   `The.Expanse.S03E01...`.
/// - `[SubsPlease] Show - 12 (1080p)` anime absolute numbering, including
///   a 4-digit case (`One Piece - 1085`, `Detective Conan - 1122`) since
///   long-running shows exceed 999 episodes.
let releaseCorpus: [ReleaseCorpusCase] = [
    // MARK: - Named ambiguities (§8), pinned explicitly up front

    ReleaseCorpusCase(
        name: "Movie.Name.2020.1080p.BluRay.x264-DON",
        title: "Movie Name", year: 2020, mediaKind: .movie,
        resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "DON"
    ),
    ReleaseCorpusCase(
        name: "Movie.Name.2020.1080p.WEB-DL.DD5.1.H264-NTb",
        title: "Movie Name", year: 2020, mediaKind: .movie,
        resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .ac3, audioChannels: "5.1",
        releaseGroup: "NTb"
    ),
    ReleaseCorpusCase(
        name: "Movie.Name.2020.2160p.UHD.BluRay.x265-FraMeSToR",
        title: "Movie Name", year: 2020, mediaKind: .movie,
        resolution: .r2160p, source: .bluray, videoCodec: .hevc, releaseGroup: "FraMeSToR"
    ),
    ReleaseCorpusCase(
        name: "The.Show.S01E01.1080p.WEB-DL-GROUP",
        title: "The Show", mediaKind: .tv, season: 1, episodes: [1],
        resolution: .r1080p, source: .webdl, releaseGroup: "GROUP"
    ),

    // MARK: - Movies

    ReleaseCorpusCase(name: "Dead.Poets.Society.1989.1080p.BluRay.x264-GROUP", title: "Dead Poets Society", year: 1989, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Good.Will.Hunting.1997.1080p.BluRay.x264-GROUP", title: "Good Will Hunting", year: 1997, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "American.History.X.1998.1080p.BluRay.x264-GROUP", title: "American History X", year: 1998, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Green.Mile.1999.1080p.BluRay.x264-GROUP", title: "The Green Mile", year: 1999, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Forrest.Gump.1994.1080p.BluRay.x264-GROUP", title: "Forrest Gump", year: 1994, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Saving.Private.Ryan.1998.1080p.BluRay.DTS.x264-GROUP", title: "Saving Private Ryan", year: 1998, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, audioCodec: .dts, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Schindlers.List.1993.1080p.BluRay.x264-GROUP", title: "Schindlers List", year: 1993, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Departed.2006.1080p.BluRay.x264-GROUP", title: "The Departed", year: 2006, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "No.Time.to.Die.2021.2160p.UHD.BluRay.HDR.DTS-HD.MA.5.1.x265-TERMiNAL", title: "No Time to Die", year: 2021, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, audioCodec: .dtsHDMA, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "Skyfall.2012.1080p.BluRay.x264-GROUP", title: "Skyfall", year: 2012, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Mad.Max.Fury.Road.2015.2160p.UHD.BluRay.HDR.x265-TERMiNAL", title: "Mad Max Fury Road", year: 2015, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, hdr: .hdr10, releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "The.Revenant.2015.1080p.BluRay.x264-GROUP", title: "The Revenant", year: 2015, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Room.2015.1080p.BluRay.x264-GROUP", title: "Room", year: 2015, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Moonlight.2016.1080p.BluRay.x264-GROUP", title: "Moonlight", year: 2016, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Manchester.by.the.Sea.2016.1080p.BluRay.x264-GROUP", title: "Manchester by the Sea", year: 2016, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Three.Billboards.Outside.Ebbing.Missouri.2017.1080p.BluRay.x264-GROUP", title: "Three Billboards Outside Ebbing Missouri", year: 2017, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Nomadland.2020.1080p.WEB-DL.DDP5.1.H.264-GROUP", title: "Nomadland", year: 2020, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "CODA.2021.1080p.WEB-DL.DDP5.1.H.264-GROUP", title: "CODA", year: 2021, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Everything.Everywhere.All.at.Once.2022.2160p.UHD.BluRay.HDR.DDP5.1.x265-GROUP", title: "Everything Everywhere All at Once", year: 2022, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "American.Fiction.2023.1080p.WEB-DL.DDP5.1.H.264-GROUP", title: "American Fiction", year: 2023, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Matrix.1999.1080p.BluRay.x264-SPARKS", title: "The Matrix", year: 1999, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "SPARKS"),
    ReleaseCorpusCase(name: "The.Matrix.Reloaded.2003.2160p.UHD.BluRay.x265-TERMiNAL", title: "The Matrix Reloaded", year: 2003, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "The.Matrix.Revolutions.2003.720p.BluRay.x264-GROUP", title: "The Matrix Revolutions", year: 2003, mediaKind: .movie, resolution: .r720p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Inception.2010.1080p.BluRay.DTS.x264-ESiR", title: "Inception", year: 2010, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, audioCodec: .dts, releaseGroup: "ESiR"),
    ReleaseCorpusCase(name: "Interstellar.2014.2160p.UHD.BluRay.HDR.DTS-HD.MA.5.1.x265-TERMiNAL", title: "Interstellar", year: 2014, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, audioCodec: .dtsHDMA, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-TERMiNAL", title: "Blade Runner 2049", year: 2017, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "Blade Runner 2049", title: "Blade Runner 2049", mediaKind: .other),
    ReleaseCorpusCase(name: "2012.2009.1080p.BluRay.x264-GROUP", title: "2012", year: 2009, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Se7en.1995.1080p.BluRay.x264-AMIABLE", title: "Se7en", year: 1995, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "AMIABLE"),
    ReleaseCorpusCase(name: "Se7en.1995.REMASTERED.1080p.BluRay.x264-AMIABLE", title: "Se7en", year: 1995, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, editions: [.remastered], releaseGroup: "AMIABLE"),
    ReleaseCorpusCase(name: "The.Dark.Knight.2008.1080p.BluRay.x264-REFiNED", title: "The Dark Knight", year: 2008, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "REFiNED"),
    ReleaseCorpusCase(name: "The.Dark.Knight.2008.IMAX.2160p.UHD.BluRay.x265-TERMiNAL", title: "The Dark Knight", year: 2008, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, editions: [.imax], releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "Parasite.2019.KOREAN.1080p.BluRay.x264-GROUP", title: "Parasite", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, languages: ["Korean"], releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Parasite.2019.1080p.WEBRip.x264-RARBG", title: "Parasite", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .webrip, videoCodec: .avc, releaseGroup: "RARBG"),
    ReleaseCorpusCase(name: "Everything.Everywhere.All.at.Once.2022.1080p.WEB-DL.DDP5.1.H.264-EVO", title: "Everything Everywhere All at Once", year: 2022, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "EVO"),
    ReleaseCorpusCase(name: "Dune.Part.Two.2024.2160p.UHD.BluRay.HDR10Plus.DDP5.1.x265-GROUP", title: "Dune Part Two", year: 2024, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10Plus, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Poor.Things.2023.1080p.WEB-DL.DDP5.1.H.264-FLUX", title: "Poor Things", year: 2023, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "FLUX"),
    ReleaseCorpusCase(name: "The.Batman.2022.1080p.WEB-DL.DDP5.1.H.264-GROUP", title: "The Batman", year: 2022, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Top.Gun.Maverick.2022.2160p.UHD.BluRay.DTS.HD.MA.5.1.x265-TERMiNAL", title: "Top Gun Maverick", year: 2022, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, audioCodec: .dtsHDMA, audioChannels: "5.1", releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "Oppenheimer.2023.2160p.UHD.BluRay.DV.DDP5.1.x265-FLUX", title: "Oppenheimer", year: 2023, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .dolbyVision, releaseGroup: "FLUX"),
    ReleaseCorpusCase(name: "Barbie.2023.1080p.WEB-DL.DDP5.1.H.264-GROUP", title: "Barbie", year: 2023, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "John.Wick.Chapter.4.2023.1080p.BluRay.x264-GROUP", title: "John Wick Chapter 4", year: 2023, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Spider-Man.Into.The.Spider-Verse.2018.1080p.WEB-DL.DDP5.1.H.264-NTb", title: "Spider Man Into The Spider Verse", year: 2018, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Spider-Man.No.Way.Home.2021.2160p.UHD.BluRay.x265-TERMiNAL", title: "Spider Man No Way Home", year: 2021, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "Avengers.Endgame.2019.2160p.UHD.BluRay.DTS-HD.MA.7.1.x265-TERMiNAL", title: "Avengers Endgame", year: 2019, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, audioCodec: .dtsHDMA, audioChannels: "7.1", releaseGroup: "TERMiNAL"),
    ReleaseCorpusCase(name: "Joker.2019.1080p.BluRay.x264-SPARKS", title: "Joker", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "SPARKS"),
    ReleaseCorpusCase(name: "Whiplash.2014.1080p.BluRay.x264-GROUP", title: "Whiplash", year: 2014, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "La.La.Land.2016.1080p.BluRay.x264-GROUP", title: "La La Land", year: 2016, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Get.Out.2017.1080p.BluRay.x264-GROUP", title: "Get Out", year: 2017, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Us.2019.1080p.WEBRip.x264-RARBG", title: "Us", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .webrip, videoCodec: .avc, releaseGroup: "RARBG"),
    ReleaseCorpusCase(name: "Knives.Out.2019.1080p.BluRay.x264-GROUP", title: "Knives Out", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Glass.Onion.A.Knives.Out.Mystery.2022.1080p.NF.WEB-DL.DDP5.1.H.264-GROUP", title: "Glass Onion A Knives Out Mystery", year: 2022, mediaKind: .movie, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Grand.Budapest.Hotel.2014.1080p.BluRay.x264-GROUP", title: "The Grand Budapest Hotel", year: 2014, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "No.Country.for.Old.Men.2007.1080p.BluRay.x264-GROUP", title: "No Country for Old Men", year: 2007, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "There.Will.Be.Blood.2007.1080p.BluRay.x264-GROUP", title: "There Will Be Blood", year: 2007, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Pulp.Fiction.1994.1080p.BluRay.x264-GROUP", title: "Pulp Fiction", year: 1994, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Fight.Club.1999.1080p.BluRay.x264-GROUP", title: "Fight Club", year: 1999, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Shawshank.Redemption.1994.1080p.BluRay.x264-GROUP", title: "The Shawshank Redemption", year: 1994, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Goodfellas.1990.1080p.BluRay.x264-GROUP", title: "Goodfellas", year: 1990, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Godfather.1972.1080p.BluRay.x264-GROUP", title: "The Godfather", year: 1972, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Godfather.Part.II.1974.1080p.BluRay.x264-GROUP", title: "The Godfather Part II", year: 1974, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Casino.1995.1080p.BluRay.x264-GROUP", title: "Casino", year: 1995, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Heat.1995.1080p.BluRay.x264-GROUP", title: "Heat", year: 1995, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Alien.1979.1080p.BluRay.x264-GROUP", title: "Alien", year: 1979, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Aliens.1986.EXTENDED.1080p.BluRay.x264-GROUP", title: "Aliens", year: 1986, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, editions: [.extended], releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Terminator.2.Judgment.Day.1991.REMASTERED.1080p.BluRay.x264-GROUP", title: "Terminator 2 Judgment Day", year: 1991, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, editions: [.remastered], releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Predator.1987.1080p.BluRay.x264-GROUP", title: "Predator", year: 1987, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Die.Hard.1988.1080p.BluRay.x264-GROUP", title: "Die Hard", year: 1988, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Jurassic.Park.1993.1080p.BluRay.x264-GROUP", title: "Jurassic Park", year: 1993, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Back.to.the.Future.1985.1080p.BluRay.x264-GROUP", title: "Back to the Future", year: 1985, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Raiders.of.the.Lost.Ark.1981.1080p.BluRay.x264-GROUP", title: "Raiders of the Lost Ark", year: 1981, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Star.Wars.Episode.IV.A.New.Hope.1977.1080p.BluRay.x264-GROUP", title: "Star Wars Episode IV A New Hope", year: 1977, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Empire.Strikes.Back.1980.1080p.BluRay.x264-GROUP", title: "The Empire Strikes Back", year: 1980, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Gladiator.2000.EXTENDED.1080p.BluRay.x264-GROUP", title: "Gladiator", year: 2000, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, editions: [.extended], releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Gladiator.II.2024.2160p.UHD.WEB-DL.DDP5.1.H.265-GROUP", title: "Gladiator II", year: 2024, mediaKind: .movie, resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Wolf.of.Wall.Street.2013.1080p.BluRay.x264-GROUP", title: "The Wolf of Wall Street", year: 2013, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Django.Unchained.2012.1080p.BluRay.x264-GROUP", title: "Django Unchained", year: 2012, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Inglourious.Basterds.2009.1080p.BluRay.x264-GROUP", title: "Inglourious Basterds", year: 2009, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Once.Upon.a.Time.in.Hollywood.2019.1080p.BluRay.x264-GROUP", title: "Once Upon a Time in Hollywood", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "1917.2019.1080p.BluRay.x264-GROUP", title: "1917", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Dunkirk.2017.1080p.BluRay.DTS.x264-GROUP", title: "Dunkirk", year: 2017, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, audioCodec: .dts, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Tenet.2020.2160p.UHD.BluRay.HDR.x265-GROUP", title: "Tenet", year: 2020, mediaKind: .movie, resolution: .r2160p, source: .bluray, videoCodec: .hevc, hdr: .hdr10, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "A.Quiet.Place.2018.1080p.BluRay.x264-GROUP", title: "A Quiet Place", year: 2018, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Hereditary.2018.1080p.BluRay.x264-GROUP", title: "Hereditary", year: 2018, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Midsommar.2019.DIRECTORS.CUT.1080p.BluRay.x264-GROUP", title: "Midsommar", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, editions: [.directorsCut], releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "It.2017.1080p.BluRay.x264-GROUP", title: "It", year: 2017, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Conjuring.2013.1080p.BluRay.x264-GROUP", title: "The Conjuring", year: 2013, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Prisoners.2013.1080p.BluRay.x264-GROUP", title: "Prisoners", year: 2013, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Sicario.2015.1080p.BluRay.DTS.x264-GROUP", title: "Sicario", year: 2015, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, audioCodec: .dts, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Arrival.2016.1080p.BluRay.x264-GROUP", title: "Arrival", year: 2016, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Ex.Machina.2014.1080p.BluRay.x264-GROUP", title: "Ex Machina", year: 2014, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Her.2013.1080p.BluRay.x264-GROUP", title: "Her", year: 2013, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Social.Network.2010.1080p.BluRay.x264-GROUP", title: "The Social Network", year: 2010, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Moneyball.2011.1080p.BluRay.x264-GROUP", title: "Moneyball", year: 2011, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Ford.v.Ferrari.2019.1080p.BluRay.x264-GROUP", title: "Ford v Ferrari", year: 2019, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Rocky.1976.1080p.BluRay.x264-GROUP", title: "Rocky", year: 1976, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Truman.Show.1998.1080p.BluRay.x264-GROUP", title: "The Truman Show", year: 1998, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Coco.2017.1080p.BluRay.x264-GROUP", title: "Coco", year: 2017, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Spirited.Away.2001.1080p.BluRay.x264-GROUP", title: "Spirited Away", year: 2001, mediaKind: .movie, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Deadpool.and.Wolverine.2024.HDCAM.XviD-GROUP", title: "Deadpool and Wolverine", year: 2024, mediaKind: .movie, source: .cam, videoCodec: .xvid, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Furiosa.A.Mad.Max.Saga.2024.DVDSCR.XviD-GROUP", title: "Furiosa A Mad Max Saga", year: 2024, mediaKind: .movie, source: .screener, videoCodec: .xvid, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Old.Format.Movie.2005.DVDRip.XviD-GROUP", title: "Old Format Movie", year: 2005, mediaKind: .movie, source: .dvd, videoCodec: .xvid, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "TV.Movie.Sample.2010.HDTV.x264-GROUP", title: "TV Movie Sample", year: 2010, mediaKind: .movie, source: .hdtv, videoCodec: .avc, releaseGroup: "GROUP"),

    // MARK: - TV

    ReleaseCorpusCase(name: "The.Expanse.S03E05.1080p.BluRay.x265-GROUP", title: "The Expanse", mediaKind: .tv, season: 3, episodes: [5], resolution: .r1080p, source: .bluray, videoCodec: .hevc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Expanse.S03.1080p.BluRay.x265-GROUP", title: "The Expanse", mediaKind: .tv, season: 3, isSeasonPack: true, resolution: .r1080p, source: .bluray, videoCodec: .hevc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Expanse.S03E01E02E03.1080p.BluRay.x265-GROUP", title: "The Expanse", mediaKind: .tv, season: 3, episodes: [1, 2, 3], resolution: .r1080p, source: .bluray, videoCodec: .hevc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Expanse.S03E01-E03.1080p.BluRay.x265-GROUP", title: "The Expanse", mediaKind: .tv, season: 3, episodes: [1, 2, 3], resolution: .r1080p, source: .bluray, videoCodec: .hevc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Expanse.S03E01.1080p.BluRay.x265-GROUP", title: "The Expanse", mediaKind: .tv, season: 3, episodes: [1], resolution: .r1080p, source: .bluray, videoCodec: .hevc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Breaking.Bad.S05E14.1080p.BluRay.x264-DEMAND", title: "Breaking Bad", mediaKind: .tv, season: 5, episodes: [14], resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "DEMAND"),
    ReleaseCorpusCase(name: "Breaking.Bad.S05.1080p.BluRay.x264-DEMAND", title: "Breaking Bad", mediaKind: .tv, season: 5, isSeasonPack: true, resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "DEMAND"),
    ReleaseCorpusCase(name: "Breaking.Bad.S05E14.Ozymandias.1080p.BluRay.x264-DEMAND", title: "Breaking Bad", mediaKind: .tv, season: 5, episodes: [14], resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "DEMAND"),
    ReleaseCorpusCase(name: "Game.of.Thrones.S08E06.1080p.WEB-DL.DDP5.1.H.264-GoT", title: "Game of Thrones", mediaKind: .tv, season: 8, episodes: [6], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GoT"),
    ReleaseCorpusCase(name: "Game.of.Thrones.Season.8.1080p.WEB-DL.DDP5.1.H.264-GoT", title: "Game of Thrones", mediaKind: .tv, season: 8, isSeasonPack: true, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GoT"),
    ReleaseCorpusCase(name: "Better.Call.Saul.S06E13.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb", title: "Better Call Saul", mediaKind: .tv, season: 6, episodes: [13], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "The.Wire.S01E01.720p.BluRay.x264-GROUP", title: "The Wire", mediaKind: .tv, season: 1, episodes: [1], resolution: .r720p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Sopranos.S01E01.720p.BluRay.x264-GROUP", title: "The Sopranos", mediaKind: .tv, season: 1, episodes: [1], resolution: .r720p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Chernobyl.S01E01.1080p.WEB-DL.DDP5.1.H.264-GROUP", title: "Chernobyl", mediaKind: .tv, season: 1, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Mandalorian.S01E01.1080p.WEB-DL.DDP5.1.H.264-NTb", title: "The Mandalorian", mediaKind: .tv, season: 1, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "The.Mandalorian.3x05.1080p.WEB-DL.DDP5.1.H.264-NTb", title: "The Mandalorian", mediaKind: .tv, season: 3, episodes: [5], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Loki.S02E06.2160p.DSNP.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "Loki", mediaKind: .tv, season: 2, episodes: [6], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "House.of.the.Dragon.S01E01.2160p.HMAX.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "House of the Dragon", mediaKind: .tv, season: 1, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Stranger.Things.S04E09.2160p.NF.WEB-DL.DDP5.1.Atmos.H.265-NTb", title: "Stranger Things", mediaKind: .tv, season: 4, episodes: [9], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Succession.S04E10.1080p.HMAX.WEB-DL.DDP5.1.H.264-NTb", title: "Succession", mediaKind: .tv, season: 4, episodes: [10], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "The.Last.of.Us.S01E03.2160p.HMAX.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "The Last of Us", mediaKind: .tv, season: 1, episodes: [3], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "True.Detective.S01E08.1080p.BluRay.x264-GROUP", title: "True Detective", mediaKind: .tv, season: 1, episodes: [8], resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Fargo.S01E01.1080p.WEB-DL.DD5.1.H.264-GROUP", title: "Fargo", mediaKind: .tv, season: 1, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .ac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Sherlock.S04E03.1080p.BluRay.x264-GROUP", title: "Sherlock", mediaKind: .tv, season: 4, episodes: [3], resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Doctor.Who.2005.S13E01.1080p.WEB-DL.AAC2.0.H.264-GROUP", title: "Doctor Who", year: 2005, mediaKind: .tv, season: 13, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .aac, audioChannels: "2.0", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Friends.S01E01.720p.BluRay.x264-GROUP", title: "Friends", mediaKind: .tv, season: 1, episodes: [1], resolution: .r720p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Seinfeld.S03E14.The.Library.480p.DVDRip.XviD-GROUP", title: "Seinfeld", mediaKind: .tv, season: 3, episodes: [14], resolution: .r480p, source: .dvd, videoCodec: .xvid, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Office.US.S02E01.720p.WEB-DL.AAC2.0.H.264-GROUP", title: "The Office US", mediaKind: .tv, season: 2, episodes: [1], resolution: .r720p, source: .webdl, videoCodec: .avc, audioCodec: .aac, audioChannels: "2.0", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Parks.and.Recreation.S04E01.720p.WEB-DL.AAC2.0.H.264-GROUP", title: "Parks and Recreation", mediaKind: .tv, season: 4, episodes: [1], resolution: .r720p, source: .webdl, videoCodec: .avc, audioCodec: .aac, audioChannels: "2.0", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Community.S02E01.720p.WEB-DL.AAC2.0.H.264-GROUP", title: "Community", mediaKind: .tv, season: 2, episodes: [1], resolution: .r720p, source: .webdl, videoCodec: .avc, audioCodec: .aac, audioChannels: "2.0", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Rick.and.Morty.S06E01.1080p.WEB-DL.DDP5.1.H.264-NTb", title: "Rick and Morty", mediaKind: .tv, season: 6, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "South.Park.S26E01.1080p.WEB-DL.AAC2.0.H.264-GROUP", title: "South Park", mediaKind: .tv, season: 26, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .aac, audioChannels: "2.0", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Simpsons.S34E01.1080p.WEB-DL.AAC2.0.H.264-GROUP", title: "The Simpsons", mediaKind: .tv, season: 34, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .aac, audioChannels: "2.0", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Peaky.Blinders.S06E01.1080p.WEB-DL.DDP5.1.H.264-GROUP", title: "Peaky Blinders", mediaKind: .tv, season: 6, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Money.Heist.S05E01.MULTI.1080p.NF.WEB-DL.DDP5.1.H.264-GROUP", title: "Money Heist", mediaKind: .tv, season: 5, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", languages: ["Multi"], releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Dark.S03E01.GERMAN.1080p.NF.WEB-DL.DDP5.1.H.264-GROUP", title: "Dark", mediaKind: .tv, season: 3, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", languages: ["German"], releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Squid.Game.S01E01.KOREAN.2160p.NF.WEB-DL.DDP5.1.HDR.H.265-GROUP", title: "Squid Game", mediaKind: .tv, season: 1, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, languages: ["Korean"], releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Narcos.S03E01.1080p.NF.WEB-DL.DDP5.1.H.264-GROUP", title: "Narcos", mediaKind: .tv, season: 3, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Crown.S06E01.2160p.NF.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "The Crown", mediaKind: .tv, season: 6, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Ted.Lasso.S03E01.1080p.ATVP.WEB-DL.DDP5.1.H.264-NTb", title: "Ted Lasso", mediaKind: .tv, season: 3, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Severance.S01E01.1080p.ATVP.WEB-DL.DDP5.1.H.264-NTb", title: "Severance", mediaKind: .tv, season: 1, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Andor.S01E01.2160p.DSNP.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "Andor", mediaKind: .tv, season: 1, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "For.All.Mankind.S04E01.2160p.ATVP.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "For All Mankind", mediaKind: .tv, season: 4, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Slow.Horses.S03E01.1080p.ATVP.WEB-DL.DDP5.1.H.264-NTb", title: "Slow Horses", mediaKind: .tv, season: 3, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "The.Bear.S02E01.1080p.HULU.WEB-DL.DDP5.1.H.264-NTb", title: "The Bear", mediaKind: .tv, season: 2, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Fleabag.S02E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb", title: "Fleabag", mediaKind: .tv, season: 2, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Killing.Eve.S04E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb", title: "Killing Eve", mediaKind: .tv, season: 4, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Vikings.S06E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb", title: "Vikings", mediaKind: .tv, season: 6, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "The.Boys.S04E01.2160p.AMZN.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "The Boys", mediaKind: .tv, season: 4, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Invincible.S02E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb", title: "Invincible", mediaKind: .tv, season: 2, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Reacher.S02E01.2160p.AMZN.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "Reacher", mediaKind: .tv, season: 2, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Jack.Ryan.S04E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb", title: "Jack Ryan", mediaKind: .tv, season: 4, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Slow.Horses.S01.1080p.ATVP.WEB-DL.DDP5.1.H.264-NTb", title: "Slow Horses", mediaKind: .tv, season: 1, isSeasonPack: true, resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Downton.Abbey.S01E01.PROPER.720p.BluRay.x264-GROUP", title: "Downton Abbey", mediaKind: .tv, season: 1, episodes: [1], resolution: .r720p, source: .bluray, videoCodec: .avc, isProper: true, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.X-Files.S01E01.REPACK.720p.BluRay.x264-GROUP", title: "The X Files", mediaKind: .tv, season: 1, episodes: [1], resolution: .r720p, source: .bluray, videoCodec: .avc, isRepack: true, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Twin.Peaks.S01E01.720p.BluRay.x264-GROUP", title: "Twin Peaks", mediaKind: .tv, season: 1, episodes: [1], resolution: .r720p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Band.of.Brothers.S01E01.720p.BluRay.x264-GROUP", title: "Band of Brothers", mediaKind: .tv, season: 1, episodes: [1], resolution: .r720p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Planet.Earth.II.S01E01.2160p.UHD.BluRay.HDR.x265-GROUP", title: "Planet Earth II", mediaKind: .tv, season: 1, episodes: [1], resolution: .r2160p, source: .bluray, videoCodec: .hevc, hdr: .hdr10, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Cosmos.A.Spacetime.Odyssey.S01E01.1080p.BluRay.x264-GROUP", title: "Cosmos A Spacetime Odyssey", mediaKind: .tv, season: 1, episodes: [1], resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Sample.Show.S02.720p.WEB-DL-GROUP", title: "Sample Show", mediaKind: .tv, season: 2, isSeasonPack: true, resolution: .r720p, source: .webdl, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Wire.S01E01-E03.720p.BluRay.x264-GROUP", title: "The Wire", mediaKind: .tv, season: 1, episodes: [1, 2, 3], resolution: .r720p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "The.Wire.S01E01E02E03E04.720p.BluRay.x264-GROUP", title: "The Wire", mediaKind: .tv, season: 1, episodes: [1, 2, 3, 4], resolution: .r720p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Fargo.S01E01.1080p.WEB-DL.DD5.1.H264-GROUP", title: "Fargo", mediaKind: .tv, season: 1, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .ac3, audioChannels: "5.1", releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "Breaking.Bad.5x14.1080p.BluRay.x264-DEMAND", title: "Breaking Bad", mediaKind: .tv, season: 5, episodes: [14], resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "DEMAND"),
    ReleaseCorpusCase(name: "Yellowstone.S05E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb", title: "Yellowstone", mediaKind: .tv, season: 5, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Shogun.2024.S01E01.2160p.HULU.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "Shogun", year: 2024, mediaKind: .tv, season: 1, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "3.Body.Problem.S01E01.2160p.NF.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "3 Body Problem", mediaKind: .tv, season: 1, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "The.Diplomat.S02E01.1080p.NF.WEB-DL.DDP5.1.H.264-NTb", title: "The Diplomat", mediaKind: .tv, season: 2, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Fallout.S01E01.2160p.AMZN.WEB-DL.DDP5.1.HDR.H.265-NTb", title: "Fallout", mediaKind: .tv, season: 1, episodes: [1], resolution: .r2160p, source: .webdl, videoCodec: .hevc, audioCodec: .eac3, audioChannels: "5.1", hdr: .hdr10, releaseGroup: "NTb"),
    ReleaseCorpusCase(name: "Slow.Horses.S04E01.1080p.ATVP.WEB-DL.DDP5.1.H.264-NTb", title: "Slow Horses", mediaKind: .tv, season: 4, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, audioCodec: .eac3, audioChannels: "5.1", releaseGroup: "NTb"),

    // MARK: - Anime

    ReleaseCorpusCase(name: "[SubsPlease] Frieren - Beyond Journeys End - 12 (1080p) [ABCD1234].mkv", title: "Frieren Beyond Journeys End", mediaKind: .anime, absoluteEpisode: 12, resolution: .r1080p, releaseGroup: "SubsPlease"),
    ReleaseCorpusCase(name: "[Erai-raws] Jujutsu Kaisen - 24 [1080p][Multiple Subtitle].mkv", title: "Jujutsu Kaisen", mediaKind: .anime, absoluteEpisode: 24, resolution: .r1080p, releaseGroup: "Erai-raws"),
    ReleaseCorpusCase(name: "[SubsPlease] One Piece - 1085 (1080p) [ABCD1234].mkv", title: "One Piece", mediaKind: .anime, absoluteEpisode: 1085, resolution: .r1080p, releaseGroup: "SubsPlease"),
    ReleaseCorpusCase(name: "[Judas] Attack on Titan - 87 [1080p][HEVC].mkv", title: "Attack on Titan", mediaKind: .anime, absoluteEpisode: 87, resolution: .r1080p, videoCodec: .hevc, releaseGroup: "Judas"),
    ReleaseCorpusCase(name: "[EMBER] Chainsaw Man - 01 [1080p].mkv", title: "Chainsaw Man", mediaKind: .anime, absoluteEpisode: 1, resolution: .r1080p, releaseGroup: "EMBER"),
    ReleaseCorpusCase(name: "[Anime.Time] Demon.Slayer.Kimetsu.no.Yaiba.S03E01.1080p.WEB-DL.x264-GROUP", title: "Demon Slayer Kimetsu no Yaiba", mediaKind: .anime, season: 3, episodes: [1], resolution: .r1080p, source: .webdl, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "[HorribleSubs] Naruto Shippuden - 500 [720p].mkv", title: "Naruto Shippuden", mediaKind: .anime, absoluteEpisode: 500, resolution: .r720p, releaseGroup: "HorribleSubs"),
    ReleaseCorpusCase(name: "[ASW] Spy x Family - 13 [1080p HEVC].mkv", title: "Spy x Family", mediaKind: .anime, absoluteEpisode: 13, resolution: .r1080p, videoCodec: .hevc, releaseGroup: "ASW"),
    ReleaseCorpusCase(name: "[Group] Another Anime [24] [720p].mkv", title: "Another Anime", mediaKind: .anime, absoluteEpisode: 24, resolution: .r720p, releaseGroup: "Group"),
    ReleaseCorpusCase(name: "[SubsPlease] My Hero Academia - 138 (720p) [ABCD1234].mkv", title: "My Hero Academia", mediaKind: .anime, absoluteEpisode: 138, resolution: .r720p, releaseGroup: "SubsPlease"),
    ReleaseCorpusCase(name: "[Erai-raws] Vinland Saga S02 - 05 [1080p].mkv", title: "Vinland Saga", mediaKind: .anime, season: 2, isSeasonPack: true, resolution: .r1080p, releaseGroup: "Erai-raws"),
    ReleaseCorpusCase(name: "Cowboy.Bebop.S01E01.1080p.BluRay.x264-GROUP", title: "Cowboy Bebop", mediaKind: .tv, season: 1, episodes: [1], resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),
    ReleaseCorpusCase(name: "[Judas] Fullmetal Alchemist Brotherhood - 01 [1080p].mkv", title: "Fullmetal Alchemist Brotherhood", mediaKind: .anime, absoluteEpisode: 1, resolution: .r1080p, releaseGroup: "Judas"),
    ReleaseCorpusCase(name: "[SubsPlease] Detective Conan - 1122 (1080p) [ABCD1234].mkv", title: "Detective Conan", mediaKind: .anime, absoluteEpisode: 1122, resolution: .r1080p, releaseGroup: "SubsPlease"),
    ReleaseCorpusCase(name: "[Erai-raws] One Punch Man - 01 [1080p][Multiple Subtitle].mkv", title: "One Punch Man", mediaKind: .anime, absoluteEpisode: 1, resolution: .r1080p, releaseGroup: "Erai-raws"),
    ReleaseCorpusCase(name: "[Judas] Dandadan - 05 [1080p][HEVC].mkv", title: "Dandadan", mediaKind: .anime, absoluteEpisode: 5, resolution: .r1080p, videoCodec: .hevc, releaseGroup: "Judas"),
    ReleaseCorpusCase(name: "Death.Note.S01E01.1080p.BluRay.x264-GROUP", title: "Death Note", mediaKind: .tv, season: 1, episodes: [1], resolution: .r1080p, source: .bluray, videoCodec: .avc, releaseGroup: "GROUP"),

    // MARK: - Music

    ReleaseCorpusCase(name: "Daft Punk - Discovery (2001) [FLAC]", title: "Discovery", year: 2001, mediaKind: .music, audioCodec: .flac, artist: "Daft Punk", album: "Discovery"),
    ReleaseCorpusCase(name: "Pink Floyd - The Dark Side of the Moon (1973) [FLAC]", title: "The Dark Side of the Moon", year: 1973, mediaKind: .music, audioCodec: .flac, artist: "Pink Floyd", album: "The Dark Side of the Moon"),
    ReleaseCorpusCase(name: "Radiohead - OK Computer (1997) [FLAC]", title: "OK Computer", year: 1997, mediaKind: .music, audioCodec: .flac, artist: "Radiohead", album: "OK Computer"),
    ReleaseCorpusCase(name: "Kendrick Lamar - To Pimp a Butterfly (2015) [FLAC]", title: "To Pimp a Butterfly", year: 2015, mediaKind: .music, audioCodec: .flac, artist: "Kendrick Lamar", album: "To Pimp a Butterfly"),
    ReleaseCorpusCase(name: "Fleetwood Mac - Rumours (1977) [MP3]", title: "Rumours", year: 1977, mediaKind: .music, audioCodec: .mp3, artist: "Fleetwood Mac", album: "Rumours"),
    ReleaseCorpusCase(name: "Nirvana - Nevermind (1991) [FLAC]", title: "Nevermind", year: 1991, mediaKind: .music, audioCodec: .flac, artist: "Nirvana", album: "Nevermind"),
    // "21" is Adele's actual album title — pins the anime-dash-vs-numeric-
    // album-title collision (§8 doesn't name this one, but it's the same
    // family of bug as the ambiguities it does name): resolved by gating
    // absolute-episode numbering behind a leading `[Group]` tag.
    ReleaseCorpusCase(name: "Adele - 21 (2011) [MP3]", title: "21", year: 2011, mediaKind: .music, audioCodec: .mp3, artist: "Adele", album: "21"),
    ReleaseCorpusCase(name: "The Beatles - Abbey Road (1969) [FLAC]", title: "Abbey Road", year: 1969, mediaKind: .music, audioCodec: .flac, artist: "The Beatles", album: "Abbey Road"),
    ReleaseCorpusCase(name: "Billie Eilish - Happier Than Ever (2021) [FLAC]", title: "Happier Than Ever", year: 2021, mediaKind: .music, audioCodec: .flac, artist: "Billie Eilish", album: "Happier Than Ever"),
    ReleaseCorpusCase(name: "Tame Impala - Currents (2015) [FLAC]", title: "Currents", year: 2015, mediaKind: .music, audioCodec: .flac, artist: "Tame Impala", album: "Currents"),
    ReleaseCorpusCase(name: "Amy Winehouse - Back to Black (2006) [FLAC]", title: "Back to Black", year: 2006, mediaKind: .music, audioCodec: .flac, artist: "Amy Winehouse", album: "Back to Black"),
    ReleaseCorpusCase(name: "Miles Davis - Kind of Blue (1959) [FLAC]", title: "Kind of Blue", year: 1959, mediaKind: .music, audioCodec: .flac, artist: "Miles Davis", album: "Kind of Blue"),
    ReleaseCorpusCase(name: "Stevie Wonder - Songs in the Key of Life (1976) [FLAC]", title: "Songs in the Key of Life", year: 1976, mediaKind: .music, audioCodec: .flac, artist: "Stevie Wonder", album: "Songs in the Key of Life"),

    // MARK: - Books

    ReleaseCorpusCase(name: "Brandon Sanderson - The Way of Kings [EPUB]", title: "The Way of Kings", mediaKind: .book, author: "Brandon Sanderson", documentFormat: .epub),
    ReleaseCorpusCase(name: "Frank Herbert - Dune [EPUB]", title: "Dune", mediaKind: .book, author: "Frank Herbert", documentFormat: .epub),
    ReleaseCorpusCase(name: "George R R Martin - A Game of Thrones [MOBI]", title: "A Game of Thrones", mediaKind: .book, author: "George R R Martin", documentFormat: .mobi),
    ReleaseCorpusCase(name: "Andy Weir - Project Hail Mary [EPUB]", title: "Project Hail Mary", mediaKind: .book, author: "Andy Weir", documentFormat: .epub),
    ReleaseCorpusCase(name: "Neal Stephenson - Snow Crash [PDF]", title: "Snow Crash", mediaKind: .book, author: "Neal Stephenson", documentFormat: .pdf),
    ReleaseCorpusCase(name: "Isaac Asimov - Foundation [EPUB]", title: "Foundation", mediaKind: .book, author: "Isaac Asimov", documentFormat: .epub),
    ReleaseCorpusCase(name: "Terry Pratchett - Guards Guards [AZW3]", title: "Guards Guards", mediaKind: .book, author: "Terry Pratchett", documentFormat: .azw3),
    ReleaseCorpusCase(name: "Robert Kirkman - The Walking Dead Vol 1 [CBR]", title: "The Walking Dead Vol 1", mediaKind: .book, author: "Robert Kirkman", documentFormat: .cbr),
    ReleaseCorpusCase(name: "J R R Tolkien - The Fellowship of the Ring [EPUB]", title: "The Fellowship of the Ring", mediaKind: .book, author: "J R R Tolkien", documentFormat: .epub),
    ReleaseCorpusCase(name: "Agatha Christie - Murder on the Orient Express [MOBI]", title: "Murder on the Orient Express", mediaKind: .book, author: "Agatha Christie", documentFormat: .mobi),
    ReleaseCorpusCase(name: "Madeline Miller - Circe [EPUB]", title: "Circe", mediaKind: .book, author: "Madeline Miller", documentFormat: .epub),
]
