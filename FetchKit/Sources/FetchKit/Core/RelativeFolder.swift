import Foundation

/// Where a file landed, said the way the user filed it.
///
/// A finished row's sub-line is its destination folder — `Movies/Nosferatu
/// (1922)` — and the full `/Users/someone/Downloads/Movies/…` is both too long
/// for the column and mostly a fact about their home directory.
///
/// **Compared by path component, never by substring.** Three bugs in this repo
/// have come from asking what a path string contains rather than where it
/// lands: `/Users/me/Downloads2/Movies/x.mkv` has `/Users/me/Downloads` as a
/// prefix and is not inside it.
public enum RelativeFolder {
    /// Nil when the file sits directly in the root, because "it is in your
    /// downloads folder" is not news on the Downloads screen.
    ///
    /// A file outside the root answers with its own folder's name rather than
    /// nothing: it went somewhere deliberate, and the row is the only place
    /// that would ever say so.
    public static func text(of fileURL: URL, under root: URL) -> String? {
        let file = fileURL.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents

        guard file.count > base.count, Array(file.prefix(base.count)) == base else {
            let folder = fileURL.standardizedFileURL.deletingLastPathComponent()
                .lastPathComponent
            return folder.isEmpty || folder == "/" ? nil : folder
        }

        let between = file.dropFirst(base.count).dropLast()
        return between.isEmpty ? nil : between.joined(separator: "/")
    }
}
