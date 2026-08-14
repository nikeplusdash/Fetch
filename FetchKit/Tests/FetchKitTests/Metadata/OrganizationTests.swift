import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Routing and naming (§9, Destination resolution).
///
/// Downloads currently land as their original filenames in one flat folder.
/// This is what files them — and the reason `ReleaseMetadata` tracks
/// provenance at all: a template must not fire on a guess, or a season pack
/// becomes twelve copies of `Unknown (0000).mkv`.
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

    // MARK: - Routing

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

    /// Ordered, first match wins — so a specific rule placed above a general
    /// one actually takes precedence.
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

    /// Every stated condition must hold, not merely one of them.
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

    /// A subfolder is used as a path component, so it is sanitized before it
    /// can reach disk — a rule is user-editable text.
    @Test func aSubfolderCannotEscapeTheDownloadDirectory() {
        let rules = [RoutingRule(match: .init(mediaKind: .movie), subfolder: "../../etc")]
        let folder = Routing.subfolder(for: meta(kind: .movie), rules: rules)
        #expect(!folder.contains(".."))
    }

    // MARK: - Template rendering

    private let strongMovie: [MetadataField: MetadataSource] = [
        .title: .titleParse, .year: .titleParse,
    ]

    @Test func aMovieTemplateRenders() {
        let name = NameTemplate.render(
            "{Title} ({Year}) [{Resolution} {Source}]",
            metadata: meta(title: "Dune", year: 2021, resolution: .r2160p, source: .remux))
        #expect(name == "Dune (2021) [2160p remux]")
    }

    /// The rule that keeps output readable: an unresolved token takes its
    /// surrounding segment with it rather than emitting a literal `{Year}`.
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

    /// Separators left stranded by a dropped token must collapse, or names
    /// come out as "Dune  - .mkv".
    @Test func separatorsLeftByADroppedTokenCollapse() {
        let name = NameTemplate.render(
            "{Title} - {ReleaseGroup} - {Resolution}",
            metadata: meta(title: "Dune", resolution: .r1080p))
        #expect(name == "Dune - 1080p")
    }

    /// Rendering is total: it degrades, it never fails.
    @Test func aTemplateWithNothingResolvableYieldsNothingRatherThanGarbage() {
        #expect(NameTemplate.render("{Title} ({Year})", metadata: .unparsed) == nil)
    }

    // MARK: - Confidence gating

    /// The whole reason provenance exists.
    @Test func aStrongParseRenamesAMovie() {
        let strategy = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .movie))
        let name = strategy.filename(
            for: meta(title: "Dune", year: 2021, resolution: .r2160p, provenance: strongMovie),
            originalFilename: "Dune.2021.2160p.WEB-DL.mkv")
        #expect(name == "Dune (2021) [2160p].mkv")
    }

    /// A movie missing its year is a weak parse, so the original name stands
    /// rather than becoming "Dune (0000).mkv".
    @Test func aWeakParseKeepsTheOriginalName() {
        let strategy = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .movie))
        let name = strategy.filename(
            for: meta(title: "Dune", provenance: [.title: .titleParse]),
            originalFilename: "some.weird.release.mkv")
        #expect(name == "some.weird.release.mkv")
    }

    /// TV needs title, season and episode — two of three is not enough.
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

    /// An inherited field is not evidence about *this* file — a season pack's
    /// torrent-level title says nothing about which episode a file holds.
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

    /// The extension comes from the actual file, never from the template — a
    /// renamed `.mkv` that becomes `.mp4` is unplayable.
    @Test func theOriginalExtensionIsAlwaysKept() {
        let strategy = NamingStrategy.template(NamingStrategy.defaultTemplate(for: .movie))
        let name = strategy.filename(
            for: meta(title: "Dune", year: 2021, provenance: strongMovie),
            originalFilename: "Dune.2021.avi")
        #expect(name?.hasSuffix(".avi") == true)
    }

    /// A rendered name is attacker-influenced text, so it is sanitized before
    /// it becomes a path component.
    ///
    /// The invariant is not "contains no dots" — `..` inside a filename is
    /// harmless. It is that no separator survives and the component is not
    /// itself a traversal token, since those are the only two ways a name can
    /// reach outside its folder.
    @Test func aRenderedNameCannotEscapeItsFolder() throws {
        let strategy = NamingStrategy.template("{Title}")
        let name = try #require(strategy.filename(
            for: meta(title: "../../etc/passwd", year: 2021, provenance: strongMovie),
            originalFilename: "x.mkv"))

        #expect(!name.contains("/"))
        #expect(!name.contains("\\"))
        #expect((name as NSString).deletingPathExtension != "..")
        // And it is still one component, not a path.
        #expect((name as NSString).pathComponents.count == 1)
    }
}

/// Templates that produce directories, not just a filename.
///
/// M4's acceptance criterion is that a season pack files each episode under
/// `TV Shows/{Series}/Season NN/`, so a template has to be able to express
/// folders. A single-component name cannot.
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

    /// Every component is sanitized independently, so a title containing a
    /// separator cannot invent an extra directory level or climb out of one.
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

    /// A weak parse keeps the original name **and** stays flat — inventing a
    /// folder for a file you could not identify is worse than not renaming.
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

/// Naming a whole torrent's files, using two-level parsing.
///
/// The failure this prevents: a season pack where every file renders the same
/// name from the torrent-level parse, so twelve episodes collapse onto one
/// path and eleven of them are lost.
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

    /// Each episode is named from its **own** filename, inheriting series and
    /// season from the torrent.
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

    /// A file whose own name identifies nothing inherits everything, and
    /// inherited fields do not count toward confidence — so it is not renamed.
    ///
    /// nil rather than the bare filename: nil leaves the engine using the
    /// debrid's own path, which keeps the torrent's folder structure for the
    /// files that could not be identified. Returning "readme.mkv" would flatten
    /// it into the routed folder alongside renamed episodes, mixing two
    /// organisational schemes in one directory.
    @Test func aFileThatIdentifiesNothingIsNotRenamed() {
        let plan = FileRenamer.plan(
            torrentMetadata: pack(),
            strategy: .template(NamingStrategy.defaultTemplate(for: .tv)))

        #expect(plan(file("Pack/readme.mkv")) == nil)
    }

    /// Companions must not be renamed as though they were the release (§8).
    @Test func companionsAreLeftAlone() {
        let plan = FileRenamer.plan(
            torrentMetadata: pack(),
            strategy: .template(NamingStrategy.defaultTemplate(for: .tv)))

        #expect(plan(file("Pack/info.nfo")) == nil)
        #expect(plan(file("Pack/sample.mkv")) == nil)
    }

    /// Preserving originals means no rename at all — nil, so the engine writes
    /// to the debrid's own path.
    @Test func preserveOriginalPlansNoRenames() {
        let plan = FileRenamer.plan(torrentMetadata: pack(), strategy: .preserveOriginal)
        #expect(plan(file("Pack/The.Expanse.S03E05.mkv")) == nil)
    }
}
