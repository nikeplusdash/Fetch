import Foundation
import FetchPluginAPI

/**
 Which sheet a search result opens (spec §7).

 This exists because the view used to decide with `result.infoHashHex ==
 nil`, which is not a question about what the result *is*. Every Gutenberg
 result satisfies it, and so will every hoster result in 7e — both would
 have opened the Internet Archive picker and failed on a missing
 identifier. Testing the wrong property is a documented failure mode in
 this repo, and it has shipped with a passing test before.
 */
public enum ResultPresentation: Sendable, Equatable {
    case torrentPicker
    case archiveItem
    case bookFormats
    case directDownload

    public static func of(_ result: SearchResult) -> ResultPresentation {
        if result.candidates.contains(where: { if case .torrent = $0 { true } else { false } }) {
            return .torrentPicker
        }
        if result.sources.contains(InternetArchiveProvider.providerID) { return .archiveItem }
        if result.sources.contains(GutenbergProvider.providerID) { return .bookFormats }

        return .directDownload
    }
}
