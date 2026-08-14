import Foundation

/// Names for files that have none (spec §4).
///
/// Gutenberg's download URLs are `…/ebooks/84.epub3.images` — there is no
/// filename anywhere in the API, so Fetch invents one from the title and
/// author. Both are remote strings, which makes this a trust boundary as much
/// as a formatting problem.
public enum BookFilename {
    /// The whole name, in UTF-8 bytes.
    ///
    /// APFS caps a filename at 255 bytes, not characters — a 120-character
    /// CJK title is 360 bytes and would be rejected outright. 200 leaves room
    /// for the numeric suffix the download layer adds on a collision.
    public static let byteBudget = 200

    /// Gutendex returns authors surname-first: `"Shelley, Mary Wollstonecraft"`.
    ///
    /// Only the **first** comma is the surname split — `"King, Martin Luther,
    /// Jr."` has a second one that belongs to the given names.
    public static func displayAuthor(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ",") else { return trimmed }
        let surname = trimmed[..<comma].trimmingCharacters(in: .whitespaces)
        let given = trimmed[trimmed.index(after: comma)...]
            .trimmingCharacters(in: .whitespaces)
        guard !given.isEmpty, !surname.isEmpty else { return trimmed }
        return "\(given) \(surname)"
    }

    public static func make(title: String, author: String?, format: BookFormat) -> String {
        let cleanTitle = clean(title)
        let cleanAuthor = author.map(clean).flatMap { $0.isEmpty ? nil : $0 }

        // Not an error and not an empty component: a book whose title is
        // nothing but separators is still a book the user asked for.
        let base = cleanTitle.isEmpty ? "Untitled" : cleanTitle
        let suffix = ".\(format.fileExtension)"
        let tail = cleanAuthor.map { " — \($0)" } ?? ""

        if (base + tail + suffix).utf8.count <= byteBudget { return base + tail + suffix }

        // Drop the author before mutilating the title: the title is what the
        // user searched for.
        if (base + suffix).utf8.count <= byteBudget { return base + suffix }

        let room = byteBudget - suffix.utf8.count
        return truncated(base, toUTF8Bytes: max(room, 1)) + suffix
    }

    /// Removes everything that would make the name mean something other than
    /// a filename.
    ///
    /// `/` is the path separator and `:` is one historically on macOS, so
    /// both become a hyphen rather than being deleted — deleting would join
    /// two words. Leading dots go because `.` and `..` are directories and a
    /// leading dot also hides the file.
    ///
    /// Whitespace and dots are cleaned iteratively to handle interleaved patterns
    /// like `" . .foo"`, where a final trim after dot-stripping could re-expose
    /// a leading dot.
    private static func clean(_ raw: String) -> String {
        var result = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()

        // Alternate between trimming whitespace and stripping dots until neither
        // applies. This ensures invariant holds regardless of how whitespace and
        // dots interleave.
        repeat {
            let before = result
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            while result.hasPrefix(".") { result.removeFirst() }
            while result.hasSuffix(".") { result.removeLast() }
            if result == before { break }
        } while true

        return result
    }

    /// Truncates on grapheme boundaries, measuring in UTF-8 bytes.
    ///
    /// Cutting a `String` at a byte offset can split a multi-byte scalar or a
    /// combining sequence, producing a name that renders as a replacement
    /// character.
    ///
    /// If a single oversized grapheme cluster exceeds the limit, returns
    /// "Untitled" rather than an empty string, which would produce a hidden
    /// dotfile when combined with the file extension.
    private static func truncated(_ text: String, toUTF8Bytes limit: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
