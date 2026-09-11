import Foundation

/**
 What a small piece of the interface means, before anything decides what
 colour that is.

 **One classification for what were five.** A tag, a kind pill, a status dot,
 an indexer's verdict and a download's glyph each carried their own switch
 from a category to a `Palette` token, and the five disagreed: two greys for
 the same "nothing to say", a tint at four opacities for the same "this is
 fine". A tone names the role — the app maps a role to a colour once, so a
 theme moves every one of them together.

 The three quiet tones are a ladder rather than synonyms: `plain` is a thing
 speaking in the surrounding ink, `muted` is a thing worth reading second,
 `quiet` is a thing that only needs to be there. The four loud ones say
 something happened.
 */
public enum Tone: Sendable, Equatable, Hashable, CaseIterable {
    case plain
    case muted
    case quiet
    case accent
    case positive
    case caution
    case danger
}

public extension MediaKind {
    /**
     How loudly a result announces what it is. Film, television and anime are
     one thing wearing three labels, so they share a tone; a book is worth
     reading second; a kind no provider named is only worth being there.
     */
    var tone: Tone {
        switch self {
        case .movie, .tv, .anime: .accent
        case .music: .caution
        case .book: .muted
        case .software, .game, .other, .unknown: .quiet
        }
    }
}

public extension HealthReport.Verdict {
    /**
     How an indexer's measured health reads on screen. Failing and unreliable
     are the same news to the person reading it — the search did not answer —
     so they wear one tone; untested is not a warning, because nothing has
     gone wrong yet.
     */
    var tone: Tone {
        switch self {
        case .failing, .unreliable: .danger
        case .slow: .caution
        case .healthy: .positive
        case .untested: .muted
        }
    }
}
