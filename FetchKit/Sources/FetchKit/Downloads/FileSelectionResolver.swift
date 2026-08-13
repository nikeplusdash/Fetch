import Foundation
import FetchPluginAPI

/// Re-resolves a file-picker selection made against a **preview** file list
/// onto the **authoritative** one, by relative path (§6, "Two kinds of file
/// list"). `checkCached(listFiles: true)` file IDs are not authoritative —
/// only `files(in:)` (post-submission) IDs are what `requestdl` accepts —
/// but `DebridFile.name` (the full in-torrent path) is stable across both
/// responses, so it is the only safe join key between them.
public enum FileSelectionResolver {
    public struct Resolution: Sendable, Equatable {
        /// Authoritative files whose path matched a selected one, carrying
        /// the authoritative (real) `DebridFileID`.
        public let matched: [DebridFile]
        /// Selected paths with no match in the authoritative list — skipped,
        /// never silently dropped, so the caller can report them.
        public let missing: [String]
    }

    public static func resolve(
        selectedPaths: Set<String>, authoritative: [DebridFile]
    ) -> Resolution {
        var byPath: [String: DebridFile] = [:]
        for file in authoritative { byPath[normalise(file.name)] = file }

        var matched: [DebridFile] = []
        var missing: [String] = []
        for path in selectedPaths.sorted() {
            if let file = byPath[normalise(path)] {
                matched.append(file)
            } else {
                missing.append(path)
            }
        }
        return Resolution(matched: matched, missing: missing)
    }

    /// The same path as written by two services that disagree about its shape.
    ///
    /// **Real-Debrid returns `/Folder/file.mkv`; TorBox and a `.torrent`'s own
    /// metadata return `Folder/file.mkv`.** Matched as raw strings, an RD
    /// selection therefore matched nothing at all — every path went to
    /// `missing`, `enqueueSelected` queued zero files, and the download simply
    /// did not happen. Every RD download, silently, for as long as RD has been
    /// supported.
    ///
    /// Only the shape is normalised, never the content: case is preserved,
    /// because two files in one torrent can differ only by case and treating
    /// them as one would download the wrong one.
    private static func normalise(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
