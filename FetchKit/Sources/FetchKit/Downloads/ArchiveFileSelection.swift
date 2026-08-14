import Foundation
import FetchPluginAPI

/// What an Internet Archive item's file picker should preselect, and in what
/// order it prefers formats.
///
/// **Why this is here and not in the sheet.** It was in the sheet, with its own
/// hardcoded `["epub", "azw3", "mobi", "pdf", "txt", "djvu"]` ranking — so the
/// user's Quality › Books preference applied to Project Gutenberg results and
/// silently did not apply to Archive.org ones. `BookItemSheet` had always
/// delegated correctly; only this path disagreed. Being in FetchKit is also
/// what makes it testable at all: the app target has no test bundle.
public enum ArchiveFileSelection {
    /// A book item is a handful of formats of one work, where preselecting the
    /// best is helpful. A collection item can be thousands of files and
    /// hundreds of gigabytes, where preselecting everything means one careless
    /// Download costs the user their evening and their disk.
    ///
    /// So preselection is opt-in above a threshold: small items preselect,
    /// large ones start empty. Getting this backwards is only recoverable by
    /// noticing in time.
    public static let preselectionLimit = 20

    /// The order used when the profile expresses no preference. EPUB over PDF,
    /// matching §7's text ranking — a scanned PDF is the camrip of books.
    public static let defaultFormatOrder: [DocumentFormat] = [
        .epub, .azw3, .mobi, .pdf, .text, .djvu, .cbz, .cbr, .html,
    ]

    /// The document format a filename implies, by extension.
    ///
    /// `txt` maps to `.text` — `DocumentFormat`'s own decoder spells that case
    /// "text", so matching on the raw extension alone would miss it and rank
    /// every plain-text file last.
    public static func format(ofFile name: String) -> DocumentFormat? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        switch ext {
        case "epub": return .epub
        case "azw3": return .azw3
        case "mobi": return .mobi
        case "pdf": return .pdf
        case "cbz": return .cbz
        case "cbr": return .cbr
        case "djvu": return .djvu
        case "html", "htm": return .html
        case "txt", "text": return .text
        default: return nil
        }
    }

    /// Lower sorts better. A file whose extension names no known document
    /// format, or a format the order does not mention, sorts after every one
    /// it does — never interleaved with them.
    public static func rank(
        _ name: String, using order: [DocumentFormat]
    ) -> Int {
        let ranked = order.isEmpty ? defaultFormatOrder : order
        guard let format = format(ofFile: name),
              let index = ranked.firstIndex(of: format)
        else { return ranked.count }
        return index
    }

    /// The files to check when the picker opens.
    ///
    /// `names` is every file in the item, in the order the item lists them.
    /// Returns the subset to preselect, preserving that order.
    public static func preselected(
        names: [String], formatOrder: [DocumentFormat] = []
    ) -> [String] {
        guard !names.isEmpty, names.count <= preselectionLimit else { return [] }

        // If every file shares a stem they are formats of one work and the
        // best-ranked wins; otherwise this is a set and the user meant it all.
        let stems = Set(names.map { ($0 as NSString).deletingPathExtension })
        guard stems.count == 1 else { return names }

        // **One stem does not always mean one work in several formats.** On a
        // media item it means the file and its derivatives — `2ypfm7.mp4` beside
        // `2ypfm7.jpg`, which is the thumbnail Archive.org generated from it.
        // The document ranking has no opinion about either, so both ranked
        // last-equal and the item's own order decided: a 79 KB cover was
        // preselected instead of the 7.7 MB video, and filed under Movies.
        //
        // So the format ranking only speaks where it knows something. With no
        // document in the set the question is which file *is* the item, and a
        // still image beside a video or a track is never the answer.
        if !names.contains(where: { format(ofFile: $0) != nil }) {
            guard let best = names.min(by: { mediaTier($0) < mediaTier($1) })
            else { return names }
            return [best]
        }

        // `min(by:)` keeps the first of equal ranks, so a tie falls to the
        // item's own order rather than something arbitrary.
        guard let best = names.min(by: {
            rank($0, using: formatOrder) < rank($1, using: formatOrder)
        }) else { return names }
        return [best]
    }

    /// Lower is more likely to be the thing the item is *of*.
    ///
    /// Deliberately coarse — video, then audio, then everything else. It only
    /// has to separate a playable file from the picture of it; anything finer
    /// would be a second ranking to keep in step with `SmartFileSelection`'s.
    /// The extension sets are that type's, rather than a second copy here.
    static func mediaTier(_ name: String) -> Int {
        let ext = (name as NSString).pathExtension.lowercased()
        if SmartFileSelection.videoExtensions.contains(ext) { return 0 }
        if SmartFileSelection.audioExtensions.contains(ext) { return 1 }
        return 2
    }
}
