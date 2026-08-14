import Foundation

/// File-level parsing drops non-media companions from naming consideration
/// even when the user selected them (§8) — an `.nfo` or a sample clip
/// inside a season-pack torrent must not become the thing a folder gets
/// named after.
public enum CompanionFileFilter {
    private static let nonMediaExtensions: Set<String> = ["nfo", "txt", "jpg", "jpeg", "png"]

    public static func isNonMediaCompanion(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if nonMediaExtensions.contains(ext) { return true }
        if fileName.lowercased().contains("sample") { return true }
        return false
    }
}
