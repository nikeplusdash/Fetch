import Foundation
import FetchPluginAPI

/// The one line along the bottom of a screen, and the only place the app
/// summarises itself.
///
/// It says what *this* screen is doing, which is why it is not one sentence
/// for the whole app: Downloads knows how many transfers are running and
/// Settings knows how many services answered, and neither can say the other's.
///
/// Here rather than in the view because it is counting and pluralising, both of
/// which have an off-by-one and neither of which the app target can test.
public enum DownloadRail {
    /// Under Failed, with nothing in it. `activity([])` would say "No downloads
    /// queued", which is a different and possibly false claim: there may be a
    /// hundred downloads, none of which went wrong.
    public static let nothingFailed = "Nothing has failed"

    /// What is happening, under All and under Failed.
    ///
    /// Named states in a fixed order rather than a total, because "7 downloads"
    /// is a number you already get from the pill. The interesting part is the
    /// mix, and the mix is what a glance down the list would otherwise have to
    /// reconstruct.
    public static func activity(_ states: [DownloadState]) -> String {
        var parts: [String] = []
        if let count = tally(states, .downloading) { parts.append("\(count) downloading") }
        if let count = tally(states, .preparing) { parts.append("\(count) preparing") }
        if let count = tally(states, .queued) { parts.append("\(count) queued") }
        if let count = tally(states, .paused) { parts.append("\(count) paused") }

        let stopped = states.filter(\.needsAttention).count
        // One phrase for the three unhappy endings, matching the pill that
        // collects them. Three separate counts here would be three numbers the
        // Failed pill already adds up.
        if stopped > 0 { parts.append("\(stopped) need attention") }

        guard !parts.isEmpty else {
            // "Nothing downloaded yet" was also wrong on its own terms: the
            // rail says what is *happening*, and an empty list after a hundred
            // finished downloads is not a claim that nothing was ever
            // downloaded. It matches the empty state the pane itself shows.
            return states.isEmpty ? "No downloads queued" : "Nothing running"
        }
        return parts.joined(separator: ", ")
    }

    /// What is on the shelf, under Library.
    ///
    /// Names the kind when one is chosen, because the count then means
    /// something different from the count beside the All pill and would
    /// otherwise look like a disagreement.
    public static func library(count: Int, bytes: Int64, kind: MediaKind?) -> String {
        guard count > 0 else { return "Nothing here yet" }
        let word = kind.map { Self.noun(for: $0, count: count) }
            ?? (count == 1 ? "download" : "downloads")
        return "\(count) \(word), \(ByteCount.format(bytes))"
    }

    /// Singular and plural spelled out per kind. Deriving one from the other by
    /// adding or dropping an `s` gets "Anime" wrong in both directions, and
    /// "Software" and "Other" have no plural at all.
    static func noun(for kind: MediaKind, count: Int) -> String {
        switch kind {
        case .movie: count == 1 ? "movie" : "movies"
        case .tv: count == 1 ? "TV show" : "TV shows"
        case .anime: "anime"
        case .music: count == 1 ? "album" : "albums"
        case .book: count == 1 ? "book" : "books"
        case .software: "software"
        case .game: count == 1 ? "game" : "games"
        case .other, .unknown: count == 1 ? "download" : "downloads"
        }
    }

    private static func tally(_ states: [DownloadState], _ state: DownloadState) -> Int? {
        let count = states.filter { $0 == state }.count
        return count > 0 ? count : nil
    }
}

/// What Settings' rail says, which is the one thing that screen knows.
///
/// **It reports evidence, not configuration.** "3 services" is a fact about a
/// settings file; "2 of 3 answering" is a fact about the network, and it is
/// only sayable once something has actually asked. Before the first answer
/// arrives it says so rather than guessing, because a rail that reads "0 of 3
/// answering" while the request is still in flight is a false alarm the user
/// cannot distinguish from a real one.
public enum ServiceRail {
    public static func text(configured: Int, answering: Int, hasAsked: Bool) -> String {
        guard configured > 0 else { return "No debrid service yet" }
        // **Clamped, because it printed "3 of 1 services answering".** The
        // coverage map keeps an entry per service it has ever asked, and
        // switching two off leaves their answers behind — so the count of
        // answers outran the count of services. The caller intersects the two
        // now; this is the second line of defence, because a rail that can
        // state an impossible number will find another way to do it.
        let answering = min(max(answering, 0), configured)
        guard hasAsked else { return "Checking your services" }
        if answering == configured {
            return configured == 1 ? "1 service answering" : "\(configured) services answering"
        }
        return "\(answering) of \(configured) services answering"
    }
}
