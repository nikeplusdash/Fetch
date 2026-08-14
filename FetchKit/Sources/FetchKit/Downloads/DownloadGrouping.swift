import Foundation

/// Where a torrent sits in the Downloads screen (§12.3).
public enum DownloadSection: String, CaseIterable, Sendable {
    case active, queued, completed, failed

    public var title: String {
        switch self {
        case .active: "Active"
        case .queued: "Queued"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

/// Presenting a torrent's files as one row.
///
/// Choosing three files from a torrent queues three independent jobs, because
/// a debrid hands out per-file links — there is no "download the torrent"
/// call to make. The engine is right to work that way. The Downloads screen
/// was wrong to *show* it that way, listing three unrelated peers instead of
/// one torrent containing three files.
public enum DownloadGrouping {
    /// A row's name: what its caller said, or what its files' shared folder
    /// implies.
    ///
    /// A whitespace-only stated name is treated as absent. Persisting one and
    /// preferring it would give the row a blank title and no way to tell why.
    public static func displayName(stated: String?, forPaths paths: [String]) -> String? {
        if let stated, !stated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stated
        }
        return displayName(forPaths: paths)
    }

    /// A torrent's name, derived from its files' shared folder.
    ///
    /// The debrid never returns a torrent name with the per-file links, so it
    /// is reconstructed rather than stored. Returns nil when the files share
    /// no root, since naming the torrent after an arbitrary one of them would
    /// be worse than showing the file count.
    public static func displayName(forPaths paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }

        if paths.count == 1, let only = paths.first {
            // A lone file is its own name; "1 file" says nothing.
            return only.contains("/") ? String(only.split(separator: "/")[0]) : only
        }

        let roots = Set(paths.compactMap { path -> String? in
            guard let first = path.split(separator: "/").first, path.contains("/")
            else { return nil }
            return String(first)
        })
        // Every file must agree, and every file must actually be in a folder.
        guard roots.count == 1, let root = roots.first,
              paths.allSatisfy({ $0.contains("/") })
        else { return nil }
        return root
    }

    /// One row per `DownloadGroupKey`, in the order the keys first appear.
    ///
    /// Generic over the element so the rule lives here rather than in the app
    /// target, which has no test bundle. It is the whole fix in three lines:
    /// bucketing on the key — content *and* attempt — is what stops a second
    /// go at a torrent from landing in the first one's row and being summed
    /// with its corpses.
    public static func rows<Element>(
        _ elements: [Element], key: (Element) -> DownloadGroupKey
    ) -> [(key: DownloadGroupKey, members: [Element])] {
        var byKey: [DownloadGroupKey: [Element]] = [:]
        var order: [DownloadGroupKey] = []

        for element in elements {
            let k = key(element)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(element)
        }
        return order.map { (key: $0, members: byKey[$0] ?? []) }
    }

    /// Which section a torrent belongs in, given its files' states.
    ///
    /// Ordering matters more than it looks: a torrent still transferring stays
    /// Active even if one file has failed, because moving it to Failed
    /// mid-flight would make the row jump sections and jump back when the next
    /// file finishes.
    public static func section(for states: [DownloadState]) -> DownloadSection? {
        guard !states.isEmpty else { return nil }

        let isRunning = states.contains {
            $0 == .downloading || $0 == .preparing || $0 == .paused
        }
        if isRunning { return .active }

        if states.contains(.queued) { return .queued }
        // Cancelled, failed and missing all land here: the section answers
        // "did this end with the file in place?", and the row's own label says
        // which of the three it was.
        if states.contains(where: \.needsAttention) { return .failed }
        return .completed
    }

    /// Files present in the torrent that were not queued.
    ///
    /// An empty `allFiles` yields nothing rather than "everything was
    /// skipped": not knowing a torrent's contents is different from knowing
    /// they were all declined, and inventing the latter would be worse than
    /// showing neither.
    public static func skippedFiles(
        allFiles: [TorrentMetadata.File], queuedPaths: Set<String>
    ) -> [TorrentMetadata.File] {
        guard !allFiles.isEmpty else { return [] }
        return allFiles.filter { !queuedPaths.contains($0.path) }
    }

    /// Files in the torrent with nothing to show for them — never queued, or
    /// queued and then failed, cancelled, or deleted from disk.
    ///
    /// The set behind the row's "Download N Other Files". Broader than
    /// `skippedFiles` by exactly the states in `needsAttention`: a file that
    /// failed is, from the row's point of view, in the same position as one
    /// that was never chosen — the torrent has it and this machine does not.
    /// Neither had any way back before this; `.missing` is terminal by design
    /// and a cancelled job is gone from the engine, so `resume` reaches
    /// neither.
    ///
    /// A download still queued, running, paused or completed is **not** here:
    /// offering to download something already on its way is how a user ends up
    /// with two copies and a row that sums both.
    public static func redownloadableFiles(
        allFiles: [TorrentMetadata.File],
        paths: [(path: String, state: DownloadState)]
    ) -> [TorrentMetadata.File] {
        guard !allFiles.isEmpty else { return [] }
        let live = Set(paths.filter { !$0.state.needsAttention }.map(\.path))
        return allFiles.filter { !live.contains($0.path) }
    }
}
