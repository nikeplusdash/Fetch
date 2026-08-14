import Foundation
import FetchPluginAPI

/// Keeps adult releases out of search results (the "Safe search" setting).
///
/// **Category, not keywords.** Torznab reserves `6000–6999` for XXX, and every
/// indexer that carries adult content files it there. Matching on the category
/// an indexer *declares* has no false positives; a title blocklist would hide
/// legitimate releases whose names happen to collide, and the results it hid
/// would be invisible and unexplainable. The cost is honest and bounded: an
/// indexer that miscategorises adult content as `Other` gets through, and no
/// amount of title matching would fix that reliably either.
///
/// **Every declared category is checked, not just the first.** A Torznab item
/// may carry several `<torznab:attr name="category">` values, and
/// `TorznabFeedParser` keeps only the first in `SearchResult.category` while
/// joining all of them into `rawAttributes["category"]`. A release filed under
/// both `2000` and `6010` would sail through a check that read only the first
/// one — so this reads both places.
public enum AdultContentFilter {
    /// Torznab's reserved XXX block, including every subcategory (6010 XXX/DVD,
    /// 6020 XXX/WMV, and so on).
    public static let adultCategories = 6000..<7000

    public static func isAdult(_ result: SearchResult) -> Bool {
        if let id = result.category?.id, adultCategories.contains(id) { return true }
        return declaredCategoryIDs(result).contains { adultCategories.contains($0) }
    }

    /// Every category id the indexer declared for this result.
    ///
    /// `rawAttributes` joins duplicate attribute names with commas — see
    /// `TorznabFeedParser.makeResult`, which does that precisely so nothing is
    /// silently lost. Anything unparseable is ignored rather than assumed
    /// adult: a filter that hides results it does not understand is worse than
    /// one that misses a badly-formed feed.
    private static func declaredCategoryIDs(_ result: SearchResult) -> [Int] {
        guard let raw = result.rawAttributes["category"] else { return [] }
        return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Results with the adult ones removed.
    ///
    /// Dropped outright rather than routed to `Outcome.filtered`: that list
    /// backs §12.1's "show N filtered" affordance, which exists to make an
    /// over-strict quality profile discoverable — offering a button that
    /// reveals the adult results would defeat the setting that hid them.
    public static func excludingAdult(_ results: [SearchResult]) -> [SearchResult] {
        results.filter { !isAdult($0) }
    }
}
