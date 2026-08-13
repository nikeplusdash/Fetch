import Foundation

/// Which row in the Downloads list a file belongs under — the content it came
/// from **and the attempt that queued it**.
///
/// **Why the attempt is part of the identity.** The key was the content alone
/// (an infohash, or an item URL for a direct source), so every file ever queued
/// from that content landed in one row for the life of the app. Cancel a
/// download and start it again and the new file joined its own corpses: a row
/// summing six copies of a 1.15 GB file reported 6.9 GB, divided its progress
/// by that same inflated total, and — once the live file finished — moved the
/// whole row to Failed, because one cancelled sibling outvoted a download that
/// had actually worked.
///
/// Content identity is still needed (a torrent's file list, its cache badge),
/// so it is kept rather than replaced: `content` is the old key, `attempt`
/// separates one queueing action from the next.
///
/// **One attempt per batch, not per file.** Picking three files from a torrent
/// is one attempt at one torrent — the three share a key and render as one row.
/// So an attempt is minted where a batch is queued (`enqueueSelected`,
/// `enqueueDirect`), never inside the per-file request.
public struct DownloadGroupKey: Hashable, Sendable {
    /// What was downloaded: an infohash for a torrent, an item or result id for
    /// a direct source. Stable across attempts.
    public let content: String

    /// Which queueing action this file came from. Empty for a row queued
    /// before attempts existed, which keeps such rows grouped exactly as they
    /// were rather than scattering them one per file on first launch.
    public let attempt: String

    /// Unit separator, not `#` or `:`. A direct download's content key is a
    /// URL, and both of those characters occur in URLs — a delimiter that can
    /// appear in the data is not a delimiter (the same reasoning as
    /// `DownloadRecord.torrentFileList`).
    private static let separator: Character = "\u{1F}"

    /// A fresh attempt at `content`. Every file queued in one action must be
    /// given the *same* key, so callers make one of these per batch.
    public init(content: String) {
        self.content = content
        self.attempt = UUID().uuidString
    }

    public init(content: String, attempt: String) {
        self.content = content
        self.attempt = attempt
    }

    /// The content with no attempt — every file under it groups together,
    /// which is what rows persisted before this type existed must keep doing.
    public static func unattempted(_ content: String) -> DownloadGroupKey {
        DownloadGroupKey(content: content, attempt: "")
    }

    /// The single string a row is bucketed and persisted by.
    public var rawValue: String {
        attempt.isEmpty ? content : "\(content)\(Self.separator)\(attempt)"
    }

    /// Parses `rawValue`, including one written by a build that had no
    /// attempts — a string with no separator is that content, unattempted.
    public init(rawValue: String) {
        guard let index = rawValue.lastIndex(of: Self.separator) else {
            self.init(content: rawValue, attempt: "")
            return
        }
        self.init(
            content: String(rawValue[rawValue.startIndex..<index]),
            attempt: String(rawValue[rawValue.index(after: index)...]))
    }
}
