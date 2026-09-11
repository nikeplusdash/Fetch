import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct OrganizationTests {
    private func meta(
        kind: MediaKind = .movie, title: String? = nil, year: Int? = nil,
        season: Int? = nil, episodes: [Int] = [], resolution: Resolution? = nil,
        source: ReleaseSource? = nil, codec: VideoCodec? = nil, group: String? = nil,
        provenance: [MetadataField: MetadataSource] = [:]
    ) -> ReleaseMetadata {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = kind
        m.title = title
        m.year = year
        m.season = season
        m.episodes = episodes
        m.resolution = resolution
        m.source = source
        m.videoCodec = codec
        m.releaseGroup = group
        m.provenance = provenance
        return m
    }


    @Test func theShippedRulesFileEachKindInItsOwnFolder() {
        let cases: [(MediaKind, String)] = [
            (.movie, "Movies"), (.tv, "TV Shows"), (.anime, "Anime"),
            (.music, "Music"), (.book, "Books"),
        ]
        for (kind, folder) in cases {
            #expect(Routing.subfolder(for: meta(kind: kind), rules: RoutingRule.defaults) == folder)
        }
    }

    @Test func anUnmatchedKindFallsBackToOther() {
        #expect(Routing.subfolder(
            for: meta(kind: .software), rules: RoutingRule.defaults) == "Other")
    }

    @Test func theFirstMatchingRuleWins() {
        let rules = [
            RoutingRule(match: .init(mediaKind: .movie, resolution: .r2160p), subfolder: "4K"),
            RoutingRule(match: .init(mediaKind: .movie), subfolder: "Movies"),
        ]
        #expect(Routing.subfolder(
            for: meta(kind: .movie, resolution: .r2160p), rules: rules) == "4K")
        #expect(Routing.subfolder(
            for: meta(kind: .movie, resolution: .r1080p), rules: rules) == "Movies")
    }

    @Test func allConditionsInARuleMustMatch() {
        let rules = [RoutingRule(
            match: .init(mediaKind: .tv, resolution: .r2160p), subfolder: "4K TV")]
        #expect(Routing.subfolder(for: meta(kind: .tv, resolution: .r1080p), rules: rules) == "Other")
    }

    @Test func aTitleSubstringRuleMatchesCaseInsensitively() {
        let rules = [RoutingRule(match: .init(titleContains: "expanse"), subfolder: "Favourites")]
        #expect(Routing.subfolder(
            for: meta(kind: .tv, title: "The Expanse"), rules: rules) == "Favourites")
    }

    @Test func aSubfolderCannotEscapeTheDownloadDirectory() {
        let rules = [RoutingRule(match: .init(mediaKind: .movie), subfolder: "../../etc")]
        let folder = Routing.subfolder(for: meta(kind: .movie), rules: rules)
        #expect(!folder.contains(".."))
    }


    private let strongMovie: [MetadataField: MetadataSource] = [
        .title: .titleParse, .year: .titleParse,
    ]

    @Test func aMovieTemplateRenders() {
        let name = NameTemplate.render(
            "{Title} ({Year}) [{Resolution} {Source}]",
            metadata: meta(title: "Dune", year: 2021, resolution: .r2160p, source: .remux))
        #expect(name == "Dune (2021) [2160p remux]")
    }

    @Test func anUnresolvedTokenDropsItsBracketedSegment() {
        let name = NameTemplate.render(
            "{Title} ({Year}) [{Resolution} {Source}]",
            metadata: meta(title: "Dune", year: 2021))
        #expect(name == "Dune (2021)")
    }

    @Test func zeroPaddingIsApplied() {
        let name = NameTemplate.render(
            "S{Season:00}E{Episode:00}",
            metadata: meta(kind: .tv, season: 3, episodes: [5]))
        #expect(name == "S03E05")
    }

    @Test func separatorsLeftByADroppedTokenCollapse() {
        let name = NameTemplate.render(
            "{Title} - {ReleaseGroup} - {Resolution}",
            metadata: meta(title: "Dune", resolution: .r1080p))
        #expect(name == "Dune - 1080p")
    }

    @Test func aTemplateWithNothingResolvableYieldsNothingRatherThanGarbage() {
        #expect(NameTemplate.render("{Title} ({Year})", metadata: .unparsed) == nil)
    }


    @Test func aStrongParseRenamesAMovie() {
        let strategy = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .movie))
        let name = strategy.filename(
            for: meta(title: "Dune", year: 2021, resolution: .r2160p, provenance: strongMovie),
            originalFilename: "Dune.2021.2160p.WEB-DL.mkv")
        #expect(name == "Dune (2021) [2160p].mkv")
    }

    @Test func aWeakParseKeepsTheOriginalName() {
        let strategy = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .movie))
        let name = strategy.filename(
            for: meta(title: "Dune", provenance: [.title: .titleParse]),
            originalFilename: "some.weird.release.mkv")
        #expect(name == "some.weird.release.mkv")
    }

    @Test func tvRequiresSeasonAndEpisodeBeforeRenaming() {
        let strategy = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .tv))
        let weak = strategy.filename(
            for: meta(kind: .tv, title: "The Expanse", season: 3,
                      provenance: [.title: .titleParse, .season: .titleParse]),
            originalFilename: "original.mkv")
        #expect(weak == "original.mkv")

        let strong = strategy.filename(
            for: meta(kind: .tv, title: "The Expanse", season: 3, episodes: [5],
                      provenance: [.title: .titleParse, .season: .titleParse,
                                   .episodes: .titleParse]),
            originalFilename: "original.mkv")
        #expect(strong == "The Expanse - S03E05.mkv")
    }

    @Test func inheritedFieldsDoNotCountTowardConfidence() {
        let strategy = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .tv))
        let name = strategy.filename(
            for: meta(kind: .tv, title: "The Expanse", season: 3, episodes: [5],
                      provenance: [.title: .inherited, .season: .inherited,
                                   .episodes: .inherited]),
            originalFilename: "original.mkv")
        #expect(name == "original.mkv")
    }

    @Test func preserveOriginalAlwaysKeepsTheName() {
        #expect(NamingStrategy.preserveOriginal.filename(
            for: meta(title: "Dune", year: 2021, provenance: strongMovie),
            originalFilename: "raw.name.mkv") == "raw.name.mkv")
    }

    @Test func theOriginalExtensionIsAlwaysKept() {
        let strategy = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .movie))
        let name = strategy.filename(
            for: meta(title: "Dune", year: 2021, provenance: strongMovie),
            originalFilename: "Dune.2021.avi")
        #expect(name?.hasSuffix(".avi") == true)
    }

    @Test func aRenderedNameCannotEscapeItsFolder() throws {
        let strategy = NamingStrategy.template("{Title}")
        let name = try #require(strategy.filename(
            for: meta(title: "../../etc/passwd", year: 2021, provenance: strongMovie),
            originalFilename: "x.mkv"))

        #expect(!name.contains("/"))
        #expect(!name.contains("\\"))
        #expect((name as NSString).deletingPathExtension != "..")
        #expect((name as NSString).pathComponents.count == 1)
    }
}

@Suite struct NestedNamingTests {
    private func tv(season: Int, episode: Int) -> ReleaseMetadata {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .tv
        m.title = "The Expanse"
        m.season = season
        m.episodes = [episode]
        m.provenance = [.title: .titleParse, .season: .titleParse, .episodes: .titleParse]
        return m
    }

    @Test func aSeasonPackEpisodeFilesUnderSeriesAndSeason() {
        let path = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .tv))
            .relativePath(for: tv(season: 3, episode: 5), originalFilename: "raw.mkv")
        #expect(path == "The Expanse/Season 03/The Expanse - S03E05.mkv")
    }

    @Test func aMovieGetsItsOwnFolder() {
        var m = ReleaseMetadata.unparsed
        m.title = "Dune"
        m.year = 2021
        m.resolution = .r2160p
        m.provenance = [.title: .titleParse, .year: .titleParse]

        let path = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .movie))
            .relativePath(for: m, originalFilename: "Dune.2021.mkv")
        #expect(path == "Dune (2021)/Dune (2021) [2160p].mkv")
    }

    @Test func eachComponentIsSanitizedSeparately() {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .tv
        m.title = "../evil"
        m.season = 1
        m.episodes = [1]
        m.provenance = [.title: .titleParse, .season: .titleParse, .episodes: .titleParse]

        let path = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .tv))
            .relativePath(for: m, originalFilename: "x.mkv")

        let components = (path ?? "").split(separator: "/").map(String.init)
        #expect(!components.contains(".."))
        #expect(components.count == 3, "series / season / file")
    }

    @Test func aWeakParseStaysFlatAndKeepsItsName() {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .tv
        m.title = "Something"
        m.provenance = [.title: .titleParse]

        let path = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .tv))
            .relativePath(for: m, originalFilename: "original.name.mkv")
        #expect(path == "original.name.mkv")
    }

    @Test func preserveOriginalNeverNests() {
        #expect(NamingStrategy.preserveOriginal
            .relativePath(for: tv(season: 3, episode: 5), originalFilename: "raw.mkv") == "raw.mkv")
    }
}

@Suite struct FileRenamerTests {
    private func pack() -> ReleaseMetadata {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .tv
        m.title = "The Expanse"
        m.season = 3
        m.provenance = [.title: .titleParse, .season: .titleParse]
        return m
    }

    private func file(_ name: String, _ size: Int64 = 1000) -> DebridFile {
        DebridFile(
            id: DebridFileID(rawValue: name), name: name,
            shortName: (name as NSString).lastPathComponent, size: size, mimeType: nil)
    }

    @Test func eachEpisodeInAPackGetsItsOwnName() {
        let plan = FileRenamer.plan(
            torrentMetadata: pack(),
            strategy: .template(NamingStrategy.defaultTemplate(for: .tv)))

        let first = plan(file("Pack/The.Expanse.S03E05.1080p.mkv"))
        let second = plan(file("Pack/The.Expanse.S03E06.1080p.mkv"))

        #expect(first == "The Expanse/Season 03/The Expanse - S03E05.mkv")
        #expect(second == "The Expanse/Season 03/The Expanse - S03E06.mkv")
        #expect(first != second, "a pack must not collapse onto one path")
    }

    @Test func aFileThatIdentifiesNothingIsNotRenamed() {
        let plan = FileRenamer.plan(
            torrentMetadata: pack(),
            strategy: .template(NamingStrategy.defaultTemplate(for: .tv)))

        #expect(plan(file("Pack/readme.mkv")) == nil)
    }

    @Test func companionsAreLeftAlone() {
        let plan = FileRenamer.plan(
            torrentMetadata: pack(),
            strategy: .template(NamingStrategy.defaultTemplate(for: .tv)))

        #expect(plan(file("Pack/info.nfo")) == nil)
        #expect(plan(file("Pack/sample.mkv")) == nil)
    }

    @Test func preserveOriginalPlansNoRenames() {
        let plan = FileRenamer.plan(torrentMetadata: pack(), strategy: .preserveOriginal)
        #expect(plan(file("Pack/The.Expanse.S03E05.mkv")) == nil)
    }
}
