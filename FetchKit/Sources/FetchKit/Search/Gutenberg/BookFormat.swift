import Foundation

/// One downloadable form of a Gutenberg book (spec §3).
///
/// Gutendex describes a book's downloads as a MIME-to-URL dictionary rather
/// than as files, so this table is where "what can I actually download" is
/// decided. It is deliberately closed: an unrecognised MIME type is dropped,
/// because a file saved with a guessed extension is a file macOS cannot open.
///
/// **There is no PDF case.** Project Gutenberg stopped generating them; the
/// amendment's §6.3 ranking named two formats that do not exist. Verified
/// against the live API on 2026-08-02.
public enum BookFormat: String, Sendable, Codable, CaseIterable, Hashable {
    case epub, kindle, text, html, htmlZip, cover, metadata

    /// The MIME type, without parameters, that identifies this format.
    ///
    /// `text/plain` arrives twice — `charset=utf-8` and `charset=us-ascii` —
    /// which is one file in two encodings, not two formats. Parameters are
    /// stripped before matching and the duplicate is resolved in `choices`.
    var mimeType: String {
        switch self {
        case .epub:     "application/epub+zip"
        case .kindle:   "application/x-mobipocket-ebook"
        case .text:     "text/plain"
        case .html:     "text/html"
        // The HTML-with-images bundle. Gutendex types it as a generic binary
        // rather than as a zip, so the MIME alone does not say what it is.
        case .htmlZip:  "application/octet-stream"
        case .cover:    "image/jpeg"
        case .metadata: "application/rdf+xml"
        }
    }

    public var displayName: String {
        switch self {
        case .epub:     "EPUB"
        case .kindle:   "Kindle (KF8)"
        case .text:     "Plain text"
        case .html:     "HTML"
        case .htmlZip:  "HTML with images (zip)"
        case .cover:    "Cover image (JPEG)"
        case .metadata: "Metadata (RDF/XML)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .epub:     "epub"
        case .kindle:   "azw3"
        case .text:     "txt"
        case .html:     "html"
        case .htmlZip:  "zip"
        case .cover:    "jpg"
        case .metadata: "rdf"
        }
    }

    /// The neutral format 7d's ranking speaks, or nil for a file that is not
    /// an edition of the book.
    ///
    /// `.kindle` is Gutendex's name for KF8, which is AZW3. `.htmlZip` is
    /// still HTML — the zip is packaging, not a format — so both HTML entries
    /// rank together rather than one of them landing in `.unknown` and sorting
    /// below every known format.
    ///
    /// Supplementary files map to nil rather than to a format of their own:
    /// giving a cover JPEG a `DocumentFormat` would make it rankable, and
    /// therefore choosable.
    public var documentFormat: DocumentFormat? {
        switch self {
        case .epub:     .epub
        case .kindle:   .azw3
        case .text:     .text
        case .html:     .html
        case .htmlZip:  .html
        case .cover, .metadata: nil
        }
    }

    /// Cover art and catalogue metadata: downloadable when the user asks for
    /// them, never the book.
    ///
    /// They are not dropped — this is a downloader, and there is no harm in
    /// fetching a cover. But they are pinned last in every ordering, because
    /// the first candidate is what a download with no UI takes and what 7d
    /// will rank on. A cover JPEG winning that race would be a bug.
    public var isSupplementary: Bool { self == .cover || self == .metadata }

    /// A **stable** order for the candidates the provider emits — no longer a
    /// user setting (7d §4.7). Preference lives in
    /// `QualityProfile.documentFormatOrder` and is applied by the ranking, so
    /// that changing it reorders results already on screen.
    ///
    /// It still matters: the ranking's sort is stable, so this decides ties
    /// among formats the profile does not rank. EPUB first because it is the
    /// format macOS Books opens; the zip bundle last because it is a
    /// directory of HTML wearing a file's clothes.
    public static let defaultPriority: [BookFormat] = [.epub, .kindle, .text, .html, .htmlZip]

    /// The MIME type with any `; charset=…` parameter removed, lowercased.
    static func baseMIME(_ key: String) -> String {
        (key.split(separator: ";").first.map(String.init) ?? key)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    static func matching(mime key: String) -> BookFormat? {
        let base = baseMIME(key)
        return allCases.first { $0.mimeType == base }
    }
}

/// One format of one book, with the URL that serves it.
public struct BookFormatChoice: Sendable, Equatable, Hashable, Identifiable {
    public let format: BookFormat
    public let url: URL

    public var id: BookFormat { format }

    public init(format: BookFormat, url: URL) {
        self.format = format
        self.url = url
    }
}

extension BookFormat {
    /// Gutendex's `formats` dictionary, reduced to an ordered list of real
    /// choices.
    ///
    /// `priority` is a stable ordering, not the user's preference: since 7d
    /// the profile decides which format wins, and it decides *after* this,
    /// against candidates this has already labelled. Supplementary files
    /// ignore the ordering entirely and always sort last, because a cover
    /// JPEG must never be `candidates[0]`.
    ///
    /// `servedBy` is the one host these URLs are allowed to name, and it has
    /// no default: the caller states it, so this table stays a table and does
    /// not have to know which provider it is serving. It is the **only** place
    /// a Gutenberg download's origin is checked — the `HTTPClient` allowlist
    /// covers the API call that produced this dictionary, and the download
    /// itself goes through `DownloadEngine`, which has no allowlist. Without
    /// this, a response naming `https://attacker.example/x` yielded a
    /// candidate the sheet labelled `Frankenstein — Mary Shelley.epub`.
    /// Exact match, case-insensitive, the same rule `HTTPClient` applies: a
    /// subdomain is not implied.
    public static func choices(
        from formats: [String: String],
        servedBy host: String,
        priority: [BookFormat] = BookFormat.defaultPriority,
        includingSupplementary: Bool = false
    ) -> [BookFormatChoice] {
        let permittedHost = host.lowercased()
        // Best entry per format, so the two `text/plain` charsets become one.
        var best: [BookFormat: (rank: Int, key: String, url: URL)] = [:]

        for (key, value) in formats {
            guard let format = matching(mime: key) else { continue }
            guard !format.isSupplementary || includingSupplementary else { continue }
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host()?.lowercased() == permittedHost
            else { continue }

            // UTF-8 beats us-ascii, and a key with no charset sits between —
            // it is usually the canonical one. Ties resolve on the MIME key,
            // because two keys of equal rank do happen (`charset=utf-16` and
            // `charset=us-ascii` are both merely "some other charset") and
            // Swift's per-process hash seed makes dictionary iteration order
            // genuinely nondeterministic — first-seen-wins would hand the
            // same book a different URL on a different launch.
            let rank: Int
            let lowered = key.lowercased()
            if lowered.contains("charset=utf-8") { rank = 0 }
            else if lowered.contains("charset=") { rank = 2 }
            else { rank = 1 }

            if let existing = best[format],
               (existing.rank, existing.key) <= (rank, lowered) { continue }
            best[format] = (rank, lowered, url)
        }

        func order(_ format: BookFormat) -> (Int, Int) {
            let group = format.isSupplementary ? 1 : 0
            let within = priority.firstIndex(of: format)
                // A format the user's saved order does not mention still has
                // to sort somewhere stable — after everything it does.
                ?? (priority.count + (allCases.firstIndex(of: format) ?? 0))
            return (group, within)
        }

        return best
            .map { BookFormatChoice(format: $0.key, url: $0.value.url) }
            .sorted { order($0.format) < order($1.format) }
    }
}
