import Foundation

/**
 Names for files that have none (spec §4).

 Gutenberg's download URLs are `…/ebooks/84.epub3.images` — there is no
 filename anywhere in the API, so Fetch invents one from the title and
 author. Both are remote strings, which makes this a trust boundary as much
 as a formatting problem.
 */
public enum BookFilename {
    public static let byteBudget = 200

    /**
     Gutendex returns authors surname-first: `"Shelley, Mary Wollstonecraft"`.

     Only the **first** comma is the surname split — `"King, Martin Luther,
     Jr."` has a second one that belongs to the given names.
     */
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

        let base = cleanTitle.isEmpty ? "Untitled" : cleanTitle
        let suffix = ".\(format.fileExtension)"
        let tail = cleanAuthor.map { " — \($0)" } ?? ""

        if (base + tail + suffix).utf8.count <= byteBudget { return base + tail + suffix }

        if (base + suffix).utf8.count <= byteBudget { return base + suffix }

        let room = byteBudget - suffix.utf8.count
        return truncated(base, toUTF8Bytes: max(room, 1)) + suffix
    }

    private static func clean(_ raw: String) -> String {
        var result = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()

        repeat {
            let before = result
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            while result.hasPrefix(".") { result.removeFirst() }
            while result.hasSuffix(".") { result.removeLast() }
            if result == before { break }
        } while true

        return result
    }

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
