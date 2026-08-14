import Foundation

public enum DestinationResolver {
    /// Build the final on-disk URL, then assert it is still inside `root`.
    /// The containment check is the backstop: if sanitization is ever wrong,
    /// this fails the download rather than writing outside the directory.
    ///
    /// The containment check is **lexical only** — `standardizedFileURL`
    /// resolves `.`/`..` textually and never touches the filesystem, so a
    /// pre-existing symlink under `root` pointing elsewhere would not be
    /// detected. That is outside this threat model, but Task 13 must not
    /// treat this check as proof the final write stays inside `root`.
    public static func resolve(
        root: URL, subfolder: String?, relativePath: String
    ) throws -> URL {
        // The file path must contribute at least one component ON ITS OWN,
        // checked before combining with subfolder. Otherwise a fully-collapsed
        // relativePath (e.g. "../..") combined with a valid subfolder would
        // silently resolve to the subfolder directory itself, and a caller
        // would write a file there instead of throwing — the same failure
        // this guards against for the root when there is no subfolder.
        let fileComponents = PathSanitizer.sanitize(relativePath: relativePath)
        guard !fileComponents.isEmpty else {
            throw DownloadError.unsafePath(relativePath)
        }

        var components: [String] = []
        if let subfolder, !subfolder.isEmpty {
            components.append(contentsOf: PathSanitizer.sanitize(relativePath: subfolder))
        }
        components.append(contentsOf: fileComponents)

        let resolvedRoot = root.standardizedFileURL
        var url = resolvedRoot
        for component in components { url.appendPathComponent(component) }
        url = url.standardizedFileURL

        let rootPath = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path : resolvedRoot.path + "/"
        guard url.path.hasPrefix(rootPath) else {
            throw DownloadError.unsafePath(relativePath)
        }
        return url
    }
}
