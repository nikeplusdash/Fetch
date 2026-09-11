import SwiftUI
import FetchKit

/**
 What kind of thing a result is (7d §7.2).

 Multi-source search made this worth saying out loud: a query for "dune"
 now returns film torrents, an Internet Archive item and Gutenberg books in
 one list, and nothing on the row distinguished them. 7c is what makes the
 label trustworthy — before it, a provider's stated `mediaKind` was
 discarded and rebuilt from a guess at the title, so every Gutenberg book
 read as `.other`.
 */
struct KindPillView: View {
    let kind: MediaKind
    var isOnFill: Bool = false

    var body: some View {
        Pill(tone: kind.tone, size: .mini, isOnFill: isOnFill) {
            Text(Self.label(kind))
                .font(FetchFont.caption2)
        }
        .fixedSize()
    }

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
}
