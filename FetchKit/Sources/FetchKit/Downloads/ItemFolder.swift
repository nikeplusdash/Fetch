import Foundation

/// Puts a source item's files inside a folder named after the item.
///
/// **Why this exists.** A torrent's per-file relative path already carries its
/// folder — `Tame Impala - 2025 - Deadbeat/folder.jpg` — so its files land
/// together on disk *and* `DownloadGrouping.displayName` recovers the torrent's
/// name from the root they share. An Internet Archive item's paths are relative
/// to the item, so the item's own name was never in them.
///
/// Found by running the app: eight files from one IA item landed loose in
/// `Movies/`, and the Downloads row read "8 files" instead of naming the item.
/// Two symptoms, one cause — the item's identity was dropped at enqueue.
public enum ItemFolder {
    /// `folder/file`, or just `file` when the item has no usable name.
    ///
    /// The folder name is remote text: an IA item title is whatever the
    /// uploader typed. `PathSanitizer.sanitize(component:)` is what stops a
    /// separator in it from becoming a directory level the source chose, and a
    /// `..` from walking out of the download directory.
    ///
    /// The file's own path is left alone. An IA item is a folder *tree* —
    /// `Show/Season 01/Ep.mkv` — and that nesting is real structure the picker
    /// showed the user, so flattening it here would throw away the thing the
    /// tree was for. It is sanitised downstream by `DestinationResolver`, which
    /// is where every other relative path in the app is made safe.
    public static func relativePath(folder: String, file: String) -> String {
        let safe = PathSanitizer.sanitize(component: folder)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // No usable name means no folder. One file at the root beats one file
        // inside a directory called "Untitled", which is somewhere a user would
        // never think to look for it.
        guard !safe.isEmpty else { return file }
        return "\(safe)/\(file)"
    }
}
