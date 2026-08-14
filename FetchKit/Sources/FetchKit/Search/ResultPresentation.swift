import Foundation
import FetchPluginAPI

/// Which sheet a search result opens (spec §7).
///
/// This exists because the view used to decide with `result.infoHashHex ==
/// nil`, which is not a question about what the result *is*. Every Gutenberg
/// result satisfies it, and so will every hoster result in 7e — both would
/// have opened the Internet Archive picker and failed on a missing
/// identifier. Testing the wrong property is a documented failure mode in
/// this repo, and it has shipped with a passing test before.
public enum ResultPresentation: Sendable, Equatable {
    /// A torrent: files live inside a container the user picks from.
    case torrentPicker
    /// An Internet Archive item: a folder tree fetched on open.
    case archiveItem
    /// A Gutenberg book: one work in several formats.
    case bookFormats
    /// Everything not claimed by the three cases above — no sheet at all.
    ///
    /// This is a presentation decision, not a usability check: it does not
    /// look at `candidates.isEmpty` or `ResultOrigin.isUsable`, so a result
    /// with no usable candidate still lands here. The caller is responsible
    /// for checking `result.isUsable` before queueing `candidates[0]`.
    case directDownload

    public static func of(_ result: SearchResult) -> ResultPresentation {
        // A torrent candidate decides it even when a direct candidate sorts
        // ahead: the picker is the only sheet that can choose a file inside a
        // torrent, and an IA item with both is exactly that case.
        if result.candidates.contains(where: { if case .torrent = $0 { true } else { false } }) {
            return .torrentPicker
        }
        if result.sources.contains(InternetArchiveProvider.providerID) { return .archiveItem }
        if result.sources.contains(GutenbergProvider.providerID) { return .bookFormats }

        // Not an error and not a fallback to someone else's sheet. A source
        // Fetch has no sheet for is still downloadable, and 7e's hosters land
        // here before 7e builds anything.
        return .directDownload
    }
}
