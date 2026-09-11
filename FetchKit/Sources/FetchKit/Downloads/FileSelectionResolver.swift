import Foundation
import FetchPluginAPI

/**
 Re-resolves a file-picker selection made against a **preview** file list
 onto the **authoritative** one, by relative path (§6, "Two kinds of file
 list"). `checkCached(listFiles: true)` file IDs are not authoritative —
 only `files(in:)` (post-submission) IDs are what `requestdl` accepts —
 but `DebridFile.name` (the full in-torrent path) is stable across both
 responses, so it is the only safe join key between them.
 */
public enum FileSelectionResolver {
    public struct Resolution: Sendable, Equatable {
        public let matched: [DebridFile]
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

    private static func normalise(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
