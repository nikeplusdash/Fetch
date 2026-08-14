import Foundation
import FetchPluginAPI

/// What an indexer's own category says a release is.
///
/// **The indexer knows and Fetch was guessing.** Every kind was decided by
/// reading the release *name* — which works for film and television, where the
/// naming conventions are strict, and fails everywhere else. A survey of real
/// Jackett results found: eight of eight films right, eight of eight series
/// right, and then nothing else. No software was ever detected, so three Adobe
/// releases were filed as **Movies** on the strength of carrying a year. Books
/// were only found when the name happened to contain "epub" or "pdf", so
/// `Frank Herbert - Dune (Books 1-6)` came back as nothing in particular.
/// Audiobooks had no answer at all.
///
/// Meanwhile every one of those results arrived carrying `7020`, or `4050`, or
/// `3030` — the indexer had already said what it was. Torznab's tree is a
/// standard and indexers populate it well, so this reads it and the name parse
/// keeps the jobs it is actually good at: resolution, codec, season, edition,
/// group.
///
/// Applied with `.attribute` provenance, so it beats the parse for the same
/// reason Gutendex and Archive.org do — a source stating a fact outranks a
/// guess made from a filename.
public enum TorznabKind {
    /// The kind a category ID implies, or nil where the tree has nothing
    /// useful to say and the name parse should keep its answer.
    ///
    /// Subcategories are checked before their parent, because the interesting
    /// ones contradict it: `4050` is a game inside PC, `5070` is anime inside
    /// TV, and `3030` is a book inside Audio.
    public static func mediaKind(forCategory id: Int) -> MediaKind? {
        switch id {
        // Audiobooks are a book you listen to, and filing them under Music
        // puts a twelve-hour narration next to the albums. Checked before the
        // 3000s for that reason.
        case 3030: return .book
        // Games on a PC live in the software tree; everything on a console is
        // a game whatever its subcategory.
        case 4050: return .game
        case 5070: return .anime

        case 1000..<2000: return .game
        case 2000..<3000: return .movie
        case 3000..<4000: return .music
        case 4000..<5000: return .software
        case 5000..<6000: return .tv
        // 6000s are adult. `AdultContentFilter` decides whether they appear at
        // all; naming a kind for them here would be a second opinion on a
        // question already answered elsewhere.
        case 7000..<8000: return .book
        default: return nil
        }
    }

    /// The same, for a result's category.
    public static func mediaKind(for category: TorznabCategory?) -> MediaKind? {
        guard let category else { return nil }
        return mediaKind(forCategory: category.id)
    }
}
