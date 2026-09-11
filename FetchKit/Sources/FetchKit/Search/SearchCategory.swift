import Foundation
import FetchPluginAPI

/**
 What the user is searching *for*, as chosen on the category bar.

 This scopes the query rather than filtering the answer. A pill maps onto
 three different source shapes — Torznab category IDs, an Internet Archive
 `mediatype`, and a yes/no for Gutenberg — because that is the vocabulary
 each source actually speaks.

 Figma's bar reads `Papers` where this reads `Games`. Deliberate: Fetch has
 `MediaKind.game` and no notion of a paper, and inventing a kind to match a
 pill would add a routing rule, a facet value and a library section for
 something no configured source can answer.
 */
public enum SearchCategory: String, CaseIterable, Sendable, Codable, Identifiable {
    /**
     The pills to show. `allCases` minus the one that depends on a setting.
     */
    public static func offered(safeSearch: Bool) -> [SearchCategory] {
        safeSearch ? allCases.filter { $0 != .adult } : allCases
    }

    case all, movies, tv, anime, music, books, software, games
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
        case .anime: [
            TorznabCategory(id: 5070, name: "TV/Anime"),
            TorznabCategory(id: 2020, name: "Movies/Other"),
            TorznabCategory(id: 3000, name: "Audio"),
            TorznabCategory(id: 4020, name: "PC/ISO"),
            TorznabCategory(id: 4050, name: "PC/Games"),
            TorznabCategory(id: 7000, name: "Books"),
        ]
        case .music: [
            TorznabCategory(id: 3000, name: "Audio"),
            TorznabCategory(id: 3010, name: "Audio/MP3"),
            TorznabCategory(id: 3020, name: "Audio/Video"),
            TorznabCategory(id: 3040, name: "Audio/Lossless"),
            TorznabCategory(id: 3050, name: "Audio/Other"),
        ]
        case .books: [
            TorznabCategory(id: 7000, name: "Books"),
            TorznabCategory(id: 7010, name: "Books/Mags"),
            TorznabCategory(id: 7020, name: "Books/EBook"),
            TorznabCategory(id: 7030, name: "Books/Comics"),
            TorznabCategory(id: 7040, name: "Books/Technical"),
            TorznabCategory(id: 7050, name: "Books/Other"),
            TorznabCategory(id: 3030, name: "Audio/Audiobook"),
        ]
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
