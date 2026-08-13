import Foundation

/// Sanitizes attacker-controlled path fragments. Torrent file names arrive
/// from an untrusted indexer through a third-party API; a `../` component
/// would write outside the download directory.
public enum PathSanitizer {
    private static let maxComponentBytes = 255

    /// Sanitize one path component. Never returns a component containing a
    /// separator, a null byte, or a traversal token.
    public static func sanitize(component: String) -> String {
        var cleaned = component
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned == ".." || cleaned == "." { cleaned = "" }
        guard !cleaned.isEmpty else { return "" }

        guard cleaned.utf8.count > maxComponentBytes else { return cleaned }

        // Truncate the stem, keep the extension — a 300-char name is still
        // recognizable, a name with no extension is not openable.
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        var suffix = ext.isEmpty ? "" : ".\(ext)"

        // A crafted name can carry a 300-byte "extension". Without this, the
        // budget goes negative, the stem loop breaks immediately, and the
        // oversized suffix is returned whole. Truncate it the same
        // byte-safe, character-at-a-time way as the stem below — `.prefix`
        // counts Characters, not UTF-8 bytes, so it would still overrun the
        // cap for a multi-byte "extension" (e.g. emoji).
        if suffix.utf8.count > maxComponentBytes {
            let suffixBudget = maxComponentBytes / 2
            var truncatedSuffix = ""
            for character in suffix {
                if truncatedSuffix.utf8.count + String(character).utf8.count > suffixBudget {
                    break
                }
                truncatedSuffix.append(character)
            }
            suffix = truncatedSuffix
        }
        let budget = max(0, maxComponentBytes - suffix.utf8.count)

        var truncated = ""
        for character in stem {
            if truncated.utf8.count + String(character).utf8.count > budget { break }
            truncated.append(character)
        }
        return truncated + suffix
    }

    /// Split a provider-supplied relative path into safe components. Absolute
    /// paths are treated as relative; traversal and empty parts are dropped.
    public static func sanitize(relativePath: String) -> [String] {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitize(component: String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Append ` (1)`, ` (2)`, … before the extension until `exists` is false.
    public static func disambiguate(
        _ filename: String, exists: (String) -> Bool
    ) -> String {
        guard exists(filename) else { return filename }

        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"

        var counter = 1
        while true {
            let candidate = "\(stem) (\(counter))\(suffix)"
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }
}
