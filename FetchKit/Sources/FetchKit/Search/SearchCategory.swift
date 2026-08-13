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
    case all, movies, tv, anime, music, books, software, games

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
        }
    }

    /// What goes in `cat=`, before the per-indexer intersection.
    ///
    /// `.anime` is 5070 alone. It is a Newznab convention rather than part of
    /// `TorznabCategory.standard`, and falling back to 5000 for indexers that
    /// do not advertise it would return every TV release they have.
    public var torznabCategories: [TorznabCategory] {
        switch self {
        case .all: []
        case .movies: [TorznabCategory(id: 2000, name: "Movies")]
        case .tv: [TorznabCategory(id: 5000, name: "TV")]
        case .anime: [TorznabCategory(id: 5070, name: "TV/Anime")]
        case .music: [TorznabCategory(id: 3000, name: "Audio")]
        case .books: [TorznabCategory(id: 7000, name: "Books")]
        case .software: [TorznabCategory(id: 4000, name: "PC")]
        case .games: [
            TorznabCategory(id: 1000, name: "Console"),
            TorznabCategory(id: 4050, name: "PC/Games"),
        ]
        }
    }
}
