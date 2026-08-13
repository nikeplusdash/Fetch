import Foundation

/// How closely a result's title answers what the user typed (7d §4.4).
///
/// **Bucketed, not continuous, and that is load-bearing.** Ordering is name
/// match first, per-kind quality second. A continuous relevance float never
/// ties, so it would silently become the *only* sort key and every per-kind
/// ranking below it would do nothing observable. Coarse buckets leave quality
/// something to decide.
enum NameMatch {
    /// Highest is best.
    ///
    /// **Why "all the tokens are in there somewhere" was not enough.** A
    /// search for "dua lipa" put *Saturday.Night.Live.S49E18.Dua.Lipa.720p.WEB*
    /// above her albums. Both titles contain both tokens, so both landed in
    /// one bucket, and the tie went to per-kind quality and popularity — where
    /// a 720p WEB-DL of a talk show beats a FLAC release comfortably. The
    /// ranking was working; it had simply been handed no reason to prefer the
    /// record over the episode she appeared on.
    ///
    /// The reason it needed is *where* the query sits in the title. A release
    /// **named after** what you searched for opens with it; one that merely
    /// mentions it has it somewhere in the middle, after the thing it is
    /// actually a release of. That is a discrete fact, not a relevance score,
    /// so it buys the separation without the continuous float this type exists
    /// to avoid.
    static func bucket(title: String, query: String) -> Int {
        let queryTokens = tokens(query)
        // An empty query is a browse, not a search: every result lands in the
        // same bucket and the composite score becomes the effective key —
        // which is the behaviour that exists today.
        guard !queryTokens.isEmpty else { return 0 }

        let titleTokens = tokens(title)
        if titleTokens == queryTokens { return 5 }

        switch firstRun(of: queryTokens, in: titleTokens) {
        case 0: return 4        // the title opens with it: named after this
        case .some: return 3    // contiguous, but something came first
        case nil: break
        }

        let titleSet = Set(titleTokens)
        let present = queryTokens.filter(titleSet.contains).count
        if present == queryTokens.count { return 2 }
        return present > 0 ? 1 : 0
    }

    /// Where `needle` appears in `haystack` as an unbroken run, or nil.
    ///
    /// Unbroken matters: "dua lipa" run together is a name, while a "dua"
    /// early and a "lipa" late are two coincidences. Release names are full of
    /// coincidences — years, codecs, group tags and the word "the".
    private static func firstRun(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    /// Case-folded, diacritic-insensitive, punctuation dropped.
    ///
    /// Splitting on non-alphanumerics rather than whitespace is what makes
    /// "Dune.2021.1080p" and "Dune (2021)" tokenize alike — release names are
    /// dot-separated far more often than they are spaced.
    private static func tokens(_ string: String) -> [String] {
        string
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
