import Foundation
import FetchPluginAPI

/**
 Computes the file picker sheet's default checkbox state on open (§12.2).

 Was video-only. A torrent of an album opened with nothing checked, and so
 did a book — which is the complaint. Each kind gets its own size floor
 because a floor that suits a 4K remux excludes every EPUB ever made.

 Pure and synchronous: the sheet calls this once per opened result.
 */
public enum SmartFileSelection {
    public static let minimumVideoBytes: Int64 = 50 * 1024 * 1024
    public static let minimumAudioBytes: Int64 = 1024 * 1024

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
        "mpg", "mpeg", "m2ts", "ts", "vob", "3gp", "ogv", "m2v", "divx",
    ]

    static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "opus", "ogg", "wav", "m4b", "wma",
    ]

    static let documentExtensions: Set<String> = [
        "epub", "pdf", "mobi", "azw3", "cbz", "cbr", "djvu",
    ]

    static let excludedKeywords = ["sample", "trailer", "extras", "featurette"]

    public static func isVideoFile(_ file: DebridFile) -> Bool {
        videoExtensions.contains(extensionOf(file))
    }

    public static func isAudioFile(_ file: DebridFile) -> Bool {
        audioExtensions.contains(extensionOf(file))
    }

    public static func isDocumentFile(_ file: DebridFile) -> Bool {
        documentExtensions.contains(extensionOf(file))
    }

    private static func extensionOf(_ file: DebridFile) -> String {
        (file.name as NSString).pathExtension.lowercased()
    }

    static func isExcluded(_ file: DebridFile) -> Bool {
        let lowered = file.name.lowercased()
        return excludedKeywords.contains { lowered.contains($0) }
    }

    static func floor(for file: DebridFile) -> Int64? {
        if isVideoFile(file) { return minimumVideoBytes }
        if isAudioFile(file) { return minimumAudioBytes }
        if isDocumentFile(file) { return 0 }
        return nil
    }

    /**
     The set of `DebridFile.name` (full in-torrent relative paths) to
     pre-check when the picker opens.
     */
    public static func defaultSelection(for files: [DebridFile]) -> Set<String> {
        Set(
            files
                .filter { file in
                    guard let floor = floor(for: file), !isExcluded(file) else { return false }
                    return file.size > floor
                }
                .map(\.name)
        )
    }
}
