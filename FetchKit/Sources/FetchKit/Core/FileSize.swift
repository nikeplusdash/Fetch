import Foundation

/// How big is this file, if it is there at all.
///
/// **Why this is not `FileManager.attributesOfItem`.** That call returns the
/// whole `FileAttributeKey` dictionary, and building it reads the file's
/// **extended attributes** — a `getxattr` per file. `getxattr` can block in
/// the kernel indefinitely: a file whose provider does not answer, a
/// synced-but-not-materialised file, a stalled volume. Asking for a *size*
/// should never be able to do that.
///
/// It was doing exactly that on Fetch's launch path — `AppModel.init` →
/// `restoreDownloads` → `size(of:)` → `attributesOfItem` → `getxattr`, wedged
/// before the scene body was ever evaluated, so the app started and drew no
/// window at all. Sampled and confirmed, twice.
///
/// `stat` is the syscall the question actually needs, so this calls it.
///
/// **Not `URL.resourceValues(forKeys:)` either**, which is the obvious
/// Foundation answer and is wrong here for its own reason: a `URL` **caches**
/// resource values it has already fetched. `RangeTransfer` reads the same
/// partial URL's size once per pass around its loop, expecting it to change as
/// bytes land — against a cached read it sees the first answer forever, so a
/// resume computes its offset from a stale length and either refetches from
/// zero or verifies against a size that never moved. Three `RangeTransfer`
/// tests caught exactly that when this was written the obvious way.
public enum FileSize {
    /// The file's size in bytes, or nil when it is not there or is not a
    /// regular file. Never distinguishes the two, on purpose: every caller
    /// here treats "no answer" as "nothing on disk", and inventing a
    /// difference would mean inventing a third state for them to handle.
    public static func of(_ url: URL) -> Int64? {
        guard url.isFileURL else { return nil }
        // Unqualified on purpose: `Darwin.stat` names the *struct*, and
        // qualifying it makes the two-argument call read as an initialiser.
        // Bare `stat` resolves by arity — the struct's no-argument init on the
        // first line, the syscall on the second.
        var info = stat()
        guard stat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG
        else { return nil }
        return Int64(info.st_size)
    }

    /// Convenience for the optional-URL call sites, of which there are
    /// several — a restored record may not know where its file went.
    public static func of(_ url: URL?) -> Int64? {
        url.flatMap { of($0) }
    }
}
