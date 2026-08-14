import Foundation
import FetchPluginAPI

/// Completed downloads, grouped as a library rather than a lifecycle.
///
/// Generic over the row so the rule lives here rather than in the app target,
/// which has no test bundle — the same reason `DownloadGrouping.rows` is
/// generic.
public enum DownloadLibrary {
    /// Fixed. Ordering by count would make the library reshuffle itself every
    /// time something landed, so its shape could never be learned.
    public static let sectionOrder: [MediaKind] = [
        .movie, .tv, .anime, .music, .book, .software, .game, .other,
    ]

    public static func title(for kind: MediaKind) -> String {
        switch kind {
        case .movie: "Movies"
        case .tv: "TV Shows"
        case .anime: "Anime"
        case .music: "Music"
        case .book: "Books"
        case .software: "Software"
        case .game: "Games"
        case .other, .unknown: "Other"
        }
    }

    /// Non-empty sections in `sectionOrder`, each sorted by name.
    ///
    /// An unmodelled kind collects under Other rather than earning a section
    /// of its own: the section would be named after whatever string an indexer
    /// happened to send, and there would be one per spelling.
    /// The shelf as one list, newest first.
    ///
    /// What "All" shows. Grouping by kind is the right shape when you are
    /// looking *for* a kind — which is what the kind bar is for — and the
    /// wrong one when you are looking at everything, where the useful question
    /// is "what did I get recently" and the answer was buried under eight
    /// alphabetised headings.
    ///
    /// A row with no date sorts last. Treating it as the epoch would put the
    /// oldest downloads Fetch has ever seen at the top of a newest-first list.
    public static func newestFirst<Row>(
        _ rows: [Row], date: (Row) -> Date?, name: (Row) -> String
    ) -> [Row] {
        rows.sorted { a, b in
            switch (date(a), date(b)) {
            case (let x?, let y?):
                x == y ? name(a).localizedStandardCompare(name(b)) == .orderedAscending : x > y
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil):
                name(a).localizedStandardCompare(name(b)) == .orderedAscending
            }
        }
    }

    public static func sections<Row>(
        _ rows: [Row],
        kind: (Row) -> MediaKind,
        name: (Row) -> String
    ) -> [(kind: MediaKind, rows: [Row])] {
        var buckets: [MediaKind: [Row]] = [:]
        for row in rows {
            let bucket = sectionOrder.contains(kind(row)) ? kind(row) : .other
            buckets[bucket, default: []].append(row)
        }
        return sectionOrder.compactMap { kind in
            guard let rows = buckets[kind], !rows.isEmpty else { return nil }
            return (
                kind: kind,
                rows: rows.sorted {
                    name($0).localizedStandardCompare(name($1)) == .orderedAscending
                }
            )
        }
    }
}
