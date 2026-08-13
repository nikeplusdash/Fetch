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

        // `min(by:)` keeps the first of equal ranks, so a tie falls to the
        // item's own order rather than something arbitrary.
        guard let best = names.min(by: {
            rank($0, using: formatOrder) < rank($1, using: formatOrder)
        }) else { return names }
        return [best]
    }
}
