import Foundation
import FetchPluginAPI

/**
 What an Internet Archive item's file picker should preselect, and in what
 order it prefers formats.

 **Why this is here and not in the sheet.** It was in the sheet, with its own
 hardcoded `["epub", "azw3", "mobi", "pdf", "txt", "djvu"]` ranking — so the
 user's Quality › Books preference applied to Project Gutenberg results and
 silently did not apply to Archive.org ones. `BookItemSheet` had always
 delegated correctly; only this path disagreed. Being in FetchKit is also
 what makes it testable at all: the app target has no test bundle.
 */
public enum ArchiveFileSelection {
    public static let preselectionLimit = 20

    public static let defaultFormatOrder: [DocumentFormat] = [
        .epub, .azw3, .mobi, .pdf, .text, .djvu, .cbz, .cbr, .html,
    ]

    /**
     The document format a filename implies, by extension.

     `txt` maps to `.text` — `DocumentFormat`'s own decoder spells that case
     "text", so matching on the raw extension alone would miss it and rank
     every plain-text file last.
     */
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

    /**
     Lower sorts better. A file whose extension names no known document
     format, or a format the order does not mention, sorts after every one
     it does — never interleaved with them.
     */
    public static func rank(
        _ name: String, using order: [DocumentFormat]
    ) -> Int {
        let ranked = order.isEmpty ? defaultFormatOrder : order
        guard let format = format(ofFile: name),
              let index = ranked.firstIndex(of: format)
        else { return ranked.count }
        return index
    }

    /**
     The files to check when the picker opens.

     `names` is every file in the item, in the order the item lists them.
     Returns the subset to preselect, preserving that order.
     */
    public static func preselected(
        names: [String], formatOrder: [DocumentFormat] = []
    ) -> [String] {
        guard !names.isEmpty, names.count <= preselectionLimit else { return [] }

        let stems = Set(names.map { ($0 as NSString).deletingPathExtension })
        guard stems.count == 1 else { return names }

        if !names.contains(where: { format(ofFile: $0) != nil }) {
            guard let best = names.min(by: { mediaTier($0) < mediaTier($1) })
            else { return names }
            return [best]
        }

        guard let best = names.min(by: {
            rank($0, using: formatOrder) < rank($1, using: formatOrder)
        }) else { return names }
        return [best]
    }

    static func mediaTier(_ name: String) -> Int {
        let ext = (name as NSString).pathExtension.lowercased()
        if SmartFileSelection.videoExtensions.contains(ext) { return 0 }
        if SmartFileSelection.audioExtensions.contains(ext) { return 1 }
        return 2
    }
}
