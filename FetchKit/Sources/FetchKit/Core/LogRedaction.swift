import Foundation

/// Turns a line of log text into one that is safe to send to a stranger.
///
/// **A log people are asked to share has to be shareable.** The interesting
/// half of any download bug is a filename, a URL and an account — and all
/// three of those are the user. A log that names *The Complete Whatever* and
/// carries a signed CDN link is not a diagnostic, it is a disclosure, and it
/// only takes one person pasting it into an issue tracker.
///
/// So the shape survives and the content does not. Which service, which
/// operation, which status, how many files, which *kind* of error: all of that
/// is what a bug report needs. What was downloaded is not.
public enum LogRedaction {
    /// A short, stable stand-in for a piece of content.
    ///
    /// Stable so two lines about the same file are visibly about the same
    /// file — which is most of what reading a log is — and one-way, so the
    /// name cannot be recovered from it.
    public static func token(_ value: String) -> String {
        guard !value.isEmpty else { return "«empty»" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "«\(String(hash, radix: 36).prefix(7))»"
    }

    /// A URL reduced to what a diagnosis needs: the host, and nothing else.
    ///
    /// A debrid's download link carries the account's own token in its path or
    /// query — §6's "never logged or persisted" rule exists for exactly that —
    /// and the path of a search URL carries the query. The host answers "which
    /// service", which is the only thing worth asking here.
    public static func host(_ url: URL?) -> String {
        url?.host().map { $0 } ?? "«no host»"
    }

    /// A file path reduced to its extension and depth.
    ///
    /// The folder names are the user's library and the filename is the
    /// content. What a bug needs is "how deep, what type" — a path resolving
    /// one level too shallow, an extension nobody expected.
    public static func path(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        let ext = (path as NSString).pathExtension
        let depth = max(parts.count - 1, 0)
        return "«\(depth) deep\(ext.isEmpty ? "" : ", .\(ext)")»"
    }

    /// Anything that looks like a credential, scrubbed out of free text.
    ///
    /// Keyword-anchored, and deliberately the same shape as
    /// `NetworkError.scrub`: a bare secret with no adjacent key name is not
    /// redactable by construction. This defends against the shapes Fetch's own
    /// messages actually take rather than pretending to be a secret scanner.
    public static func scrub(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)(api[_-]?key|apikey|token|authorization|password|secret)"#
                + #"["'\s:=]*[^"'\s,&}]+"#,
            with: "$1=«redacted»",
            options: .regularExpression)
    }
}
