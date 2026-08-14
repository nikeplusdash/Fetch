import Foundation
import FetchPluginAPI

/// What the user is searching *for*, as chosen on the category bar.
///
/// This scopes the query rather than filtering the answer. A pill maps onto
/// three different source shapes — Torznab category IDs, an Internet Archive
/// `mediatype`, and a yes/no for Gutenberg — because that is the vocabulary
/// each source actually speaks.
///
/// Figma's bar reads `Papers` where this reads `Games`. Deliberate: Fetch has
/// `MediaKind.game` and no notion of a paper, and inventing a kind to match a
/// pill would add a routing rule, a facet value and a library section for
/// something no configured source can answer.
public enum SearchCategory: String, CaseIterable, Sendable, Codable, Identifiable {
    /// The pills to show. `allCases` minus the one that depends on a setting.
    public static func offered(safeSearch: Bool) -> [SearchCategory] {
        safeSearch ? allCases.filter { $0 != .adult } : allCases
    }

    case all, movies, tv, anime, music, books, software, games
    /// **Only offered when safe search is off.** It is a category like any
    /// other and the pill row is not the place to argue about it; what decides
    /// whether it exists is the switch in Settings that already decides whether
    /// these results are filtered out of everything else. Offering it while
    /// that switch is on would be a pill whose every result is discarded.
    case adult

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .tv: "TV"
        case .anime: "Anime"
        case .music: "Music"
        case .books: "Books"
        case .software: "Software"
        case .games: "Games"
        case .adult: "Adult"
        }
    }

    /// SF Symbol for the pill. Named here rather than in the view because the
    /// app target has no test bundle, and a symbol that does not exist renders
    /// as an empty box with no error.
    public var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .movies: "film"
        case .tv: "tv"
        case .anime: "sparkles"
        case .music: "music.note"
        case .books: "book"
        case .software: "shippingbox"
        case .games: "gamecontroller"
        case .adult: "eye.trianglebadge.exclamationmark"
        }
    }

    /// What goes in `cat=`, before the per-indexer intersection.
    ///
    /// **A parent is not a synonym for its children.** `CategoryIntersection`
    /// treats a requested top-level ID as covering everything beneath it, so
    /// asking for 3000 asks for the whole Audio tree — which is exactly what
    /// Jackett's own manual search does, and exactly what Fetch was missing.
    /// A query for `3010,3020,3040,3050` returned one result for "3 Body
    /// Problem" where `3000` returned ten: the audiobooks sat on 3030 and
    /// three trackers had filed their releases on the bare parent, so every
    /// one of them fell outside a request made only of siblings.
    ///
    /// The cost of a parent is that it drags the rest of its tree back in, so
    /// it is listed only where a pill is willing to own the whole tree. One
    /// pair is not: **Software and Games** split the 4000s, and 4000 leaked
    /// Console into Software the same way 5000 leaks Movies into TV.
    ///
    /// The overlaps that remain are deliberate, not leaks. Music takes 3000 and
    /// Books takes 3030, so an audiobook answers to either — it genuinely is
    /// both, and the measured alternative was Music finding nothing at all.
    /// TV takes the whole 5000 tree including 5070, so an anime series answers
    /// to TV as well as to Anime; a pill that returns a superset is a pill that
    /// found the thing, which is the failure mode worth avoiding here.
    public var torznabCategories: [TorznabCategory] {
        switch self {
        case .all: []
        case .movies: [
            TorznabCategory(id: 2000, name: "Movies"),
            TorznabCategory(id: 2010, name: "Movies/Foreign"),
            TorznabCategory(id: 2020, name: "Movies/Other"),
            TorznabCategory(id: 2030, name: "Movies/SD"),
            TorznabCategory(id: 2040, name: "Movies/HD"),
            TorznabCategory(id: 2045, name: "Movies/UHD"),
            TorznabCategory(id: 2050, name: "Movies/3D"),
            TorznabCategory(id: 2060, name: "Movies/BluRay"),
            TorznabCategory(id: 2070, name: "Movies/DVD"),
        ]
        // The whole tree, 5070 included. A parent that reaches into another
        // pill is the trade being made everywhere else here: an anime series
        // is television, and the pill that fails to return it is worse than
        // the pill that returns it twice.
        case .tv: [
            TorznabCategory(id: 5000, name: "TV"),
            TorznabCategory(id: 5010, name: "TV/WEB-DL"),
            TorznabCategory(id: 5020, name: "TV/Foreign"),
            TorznabCategory(id: 5030, name: "TV/SD"),
            TorznabCategory(id: 5040, name: "TV/HD"),
            TorznabCategory(id: 5045, name: "TV/UHD"),
            TorznabCategory(id: 5050, name: "TV/Other"),
            TorznabCategory(id: 5060, name: "TV/Sport"),
            TorznabCategory(id: 5070, name: "TV/Anime"),
            TorznabCategory(id: 5080, name: "TV/Documentary"),
        ]
        // **Not just 5070.** An anime tracker carries more than episodes, and
        // Jackett maps the rest of Nyaa's tree onto standard IDs rather than
        // onto anything anime-specific: live action lands on 2020, OSTs on
        // 3000, applications on 4020, games on 4050, manga and light novels on
        // 7000. 5070 alone asks such an indexer for one of its six shelves.
        //
        // The trade is that on a *general* indexer those same IDs are just
        // Audio, Books and PC — so this pill is wide by construction. It is
        // the only shape that reaches an anime tracker's whole catalogue,
        // which is what the pill is for.
        case .anime: [
            TorznabCategory(id: 5070, name: "TV/Anime"),
            TorznabCategory(id: 2020, name: "Movies/Other"),
            TorznabCategory(id: 3000, name: "Audio"),
            TorznabCategory(id: 4020, name: "PC/ISO"),
            TorznabCategory(id: 4050, name: "PC/Games"),
            TorznabCategory(id: 7000, name: "Books"),
        ]
        // 3000 included, and it is the whole fix: three of the four sources
        // that answered "3 Body Problem" for Audio had filed their releases on
        // the bare parent, and a sibling-only request saw none of them.
        case .music: [
            TorznabCategory(id: 3000, name: "Audio"),
            TorznabCategory(id: 3010, name: "Audio/MP3"),
            TorznabCategory(id: 3020, name: "Audio/Video"),
            TorznabCategory(id: 3040, name: "Audio/Lossless"),
            TorznabCategory(id: 3050, name: "Audio/Other"),
        ]
        // **The one that crosses trees.** An audiobook is a book, and Torznab
        // files it under Audio — so asking for 7000 alone missed every one.
        // Measured: 7000 gave 423 results, 7000 with 3030 gave 455.
        case .books: [
            TorznabCategory(id: 7000, name: "Books"),
            TorznabCategory(id: 7010, name: "Books/Mags"),
            TorznabCategory(id: 7020, name: "Books/EBook"),
            TorznabCategory(id: 7030, name: "Books/Comics"),
            TorznabCategory(id: 7040, name: "Books/Technical"),
            TorznabCategory(id: 7050, name: "Books/Other"),
            TorznabCategory(id: 3030, name: "Audio/Audiobook"),
        ]
        // PC minus the four IDs Games claims, plus the whole Console tree.
        // No 4000 — it would return 4040/4050/4060/4070 and undo the split.
        //
        // 1000 already covers its children through the intersection; they are
        // spelled out for the indexer that advertises no caps at all, where
        // the request is sent verbatim and only exact IDs match. The gaps at
        // 1100, 1150, 1160 and 1170 are gaps in Torznab — nothing is assigned
        // there, so nothing would ever answer.
        case .software: [
            TorznabCategory(id: 4010, name: "PC/0day"),
            TorznabCategory(id: 4020, name: "PC/ISO"),
            TorznabCategory(id: 4030, name: "PC/Mac"),
            TorznabCategory(id: 1000, name: "Console"),
            TorznabCategory(id: 1010, name: "Console/NDS"),
            TorznabCategory(id: 1020, name: "Console/PSP"),
            TorznabCategory(id: 1030, name: "Console/Wii"),
            TorznabCategory(id: 1040, name: "Console/Xbox"),
            TorznabCategory(id: 1050, name: "Console/Xbox 360"),
            TorznabCategory(id: 1060, name: "Console/Wiiware"),
            TorznabCategory(id: 1070, name: "Console/Xbox 360 DLC"),
            TorznabCategory(id: 1080, name: "Console/PS3"),
            TorznabCategory(id: 1090, name: "Console/Other"),
            TorznabCategory(id: 1110, name: "Console/3DS"),
            TorznabCategory(id: 1120, name: "Console/PS Vita"),
            TorznabCategory(id: 1130, name: "Console/WiiU"),
            TorznabCategory(id: 1140, name: "Console/Xbox One"),
            TorznabCategory(id: 1180, name: "Console/PS4"),
        ]
        case .games: [
            TorznabCategory(id: 4040, name: "PC/Mobile-Other"),
            TorznabCategory(id: 4050, name: "PC/Games"),
            TorznabCategory(id: 4060, name: "PC/Mobile-iOS"),
            TorznabCategory(id: 4070, name: "PC/Mobile-Android"),
        ]
        case .adult: [
            TorznabCategory(id: 6000, name: "XXX"),
            TorznabCategory(id: 6010, name: "XXX/DVD"),
            TorznabCategory(id: 6040, name: "XXX/x264"),
            TorznabCategory(id: 6045, name: "XXX/UHD"),
            TorznabCategory(id: 6060, name: "XXX/ImageSet"),
            TorznabCategory(id: 6070, name: "XXX/Other"),
        ]
        }
    }
}
