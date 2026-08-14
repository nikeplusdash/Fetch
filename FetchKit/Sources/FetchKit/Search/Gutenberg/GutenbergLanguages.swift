import Foundation

/// Turning macOS's preferred languages into codes Gutendex accepts (spec §6).
///
/// `Locale.preferredLanguages` returns BCP 47 tags — `en-US`, `zh-Hans-CN` —
/// and Gutenberg catalogues by ISO 639-1. A user with both `en-GB` and `en-US`
/// set must not send `en` twice.
public enum GutenbergLanguages {
    /// The system's current preference, resolved.
    public static func systemPreferred() -> [String] {
        codes(from: Locale.preferredLanguages)
    }

    /// Order is preserved because it is the user's own preference order, and
    /// Gutendex treats the list as an OR rather than a ranking — so the order
    /// matters only for what the Settings row shows back.
    public static func codes(from preferred: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for tag in preferred {
            let primary = tag
                .split(separator: "-").first
                .map { String($0).lowercased() }?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !primary.isEmpty, seen.insert(primary).inserted else { continue }
            result.append(primary)
        }
        return result
    }
}
