import SwiftUI
import FetchKit

/// What kind of thing a result is (7d §7.2).
///
/// Multi-source search made this worth saying out loud: a query for "dune"
/// now returns film torrents, an Internet Archive item and Gutenberg books in
/// one list, and nothing on the row distinguished them. 7c is what makes the
/// label trustworthy — before it, a provider's stated `mediaKind` was
/// discarded and rebuilt from a guess at the title, so every Gutenberg book
/// read as `.other`.
struct KindPillView: View {
    let kind: MediaKind
    /// True on a selected, focused row — the pill's text and its 12%-opacity
    /// tint background both sit on `Palette.bgSelected` blue, and every
    /// `tint(kind)` value fails contrast there just as `Palette.cached` does
    /// on `CacheBadgeView`, which is where this parameter's name comes from.
    var isOnFill: Bool = false

    var body: some View {
        Text(Self.label(kind))
            .font(FetchFont.caption2)
            .foregroundStyle(isOnFill ? Palette.statusOnFill : Self.tint(kind))
            .padding(.horizontal, Spacing.s6)
            .padding(.vertical, Spacing.s2)
            .background(Self.tint(kind).opacity(0.12), in: Capsule())
            .fixedSize()
    }

    /// `.unknown` prints what the source actually said rather than "Other":
    /// a kind Fetch does not model is a different fact from one it modelled
    /// as unremarkable, and hiding the difference hides the gap.
    static func label(_ kind: MediaKind) -> String {
        switch kind {
        case .movie: "Movie"
        case .tv: "TV"
        case .anime: "Anime"
        case .music: "Audio"
        case .book: "Book"
        case .software: "Software"
        case .game: "Game"
        case .other: "Other"
        case .unknown(let raw): raw.capitalized
        }
    }

    private static func tint(_ kind: MediaKind) -> Color {
        switch kind {
        case .movie, .tv, .anime: Palette.accent
        case .music: Palette.attention
        case .book: Palette.textSecondary
        default: Palette.textTertiary
        }
    }
}
