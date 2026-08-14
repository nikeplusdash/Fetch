import Foundation
import FetchKit

/// Plan 1's additions — the Downloads list, its filters and its Library.
///
/// **A file of its own, and the reason is mechanical.** Three plans are built in
/// parallel worktrees and all three need behaviour on `AppModel`. Adding it to
/// `AppModel.swift` would put three branches in the same 2,800-line file at the
/// same time. The stored properties they need are declared there once, in the
/// foundation commit; everything else lives in one of these three files, which
/// cannot collide because no two plans open the same one.
///
/// Everything here is a lookup or a call into FetchKit. The rules themselves —
/// which states a pill accepts, what one row's state is, what the rail says —
/// are `DownloadFilter`, `DownloadRowState` and `DownloadRail`, because the app
/// target has no test bundle and "which states count as failed" is exactly the
/// decision that drifts when it lives in a `switch` inside a `ForEach`.
extension AppModel {
    /// Every row there is, newest first, before any filter runs.
    ///
    /// One flat list. The two modes and, before them, the four lifecycle
    /// sections are gone: they answered "what stage is this at", which the
    /// glyph already answers per row, at the cost of burying the question
    /// people actually arrive with, which is "what did I just get".
    var allDownloadRows: [TorrentGroup] {
        DownloadLibrary.newestFirst(
            torrentGroups.flatMap(\.groups), date: \.addedAt, name: \.displayName)
    }

    /// What the list shows: the same order, narrowed.
    ///
    /// **Filters narrow, they never re-sort.** A filter that also reorders is
    /// two controls wearing one pill, and the second one is invisible.
    var visibleDownloadRows: [TorrentGroup] {
        let narrowed = allDownloadRows.filter { downloadFilter.accepts($0.rowState) }
        guard downloadFilter.showsCategories, let kind = libraryKind else { return narrowed }
        return narrowed.filter { $0.mediaKind == kind }
    }

    /// The number beside a pill.
    ///
    /// **From the unfiltered set, always.** Counted after the filter ran, every
    /// pill but the chosen one would read zero, and the control that gets you
    /// back would look like the thing that has nothing in it.
    func downloadCount(for filter: DownloadFilter) -> Int {
        allDownloadRows.filter { filter.accepts($0.rowState) }.count
    }

    /// How many rows Clear would remove: the three dead ends, wherever they
    /// are. Counted off the whole list rather than the visible one, so the
    /// button does not appear and vanish as the Library pill is chosen.
    var clearableCount: Int {
        allDownloadRows.count { DownloadFilter.isClearable($0.rowState) }
    }

    /// The kinds the category bar offers, with counts.
    ///
    /// **Only kinds that exist get a pill.** Eight fixed pills, five of them
    /// reading zero, would be a shelf describing what you do not have. Counts
    /// come from the whole library rather than the narrowed one, for the reason
    /// above: choosing Books must not erase the pill that chooses Movies.
    var libraryKinds: [(kind: MediaKind, count: Int)] {
        let completed = allDownloadRows.filter { DownloadFilter.library.accepts($0.rowState) }
        return DownloadLibrary
            .sections(completed, kind: \.mediaKind, name: \.displayName)
            .map { (kind: $0.kind, count: $0.rows.count) }
    }

    /// What the rail says on the left, which depends on which question the
    /// filter is asking.
    var downloadRailText: String {
        switch downloadFilter {
        case .downloads:
            // One count per *row*, not per file: the pills count rows and a
            // torrent with five files transferring is one thing happening, not
            // five. Preparations have no `DownloadItem` behind them yet, so
            // they are added by hand or the rail reads "Nothing running" while
            // a debrid is fetching a torrent.
            //
            // `activity` already names what failed, which is why this pill does
            // not need a rail of its own now that Failed is folded into it.
            return DownloadRail.activity(
                visibleDownloadRows.map(\.rowState)
                + Array(repeating: .preparing, count: preparations.count))
        case .library:
            let rows = visibleDownloadRows
            return DownloadRail.library(
                count: rows.count,
                bytes: rows.reduce(0) { $0 + $1.totalBytes },
                kind: libraryKind)
        }
    }

    /// What the rail says on the right, on every screen that has one: what
    /// this app is connected to.
    /// The rail's right slot: what this window is connected to.
    ///
    /// **Empty when there is nothing to name, rather than "No debrid service".**
    /// The left slot already reports the state — on Settings it said "No debrid
    /// service yet" — so with none configured the rail read the same fact
    /// twice, once at each end of the same line. The right slot names things;
    /// when there are no things, it says nothing and the left slot is believed
    /// the first time.
    var configuredServicesText: String {
        providers.isEmpty
            ? ""
            : providers.map(\.displayName).sorted().joined(separator: ", ")
    }

    /// Where a finished row's files landed, relative to the download folder.
    ///
    /// Read off the file that actually landed rather than rebuilt from the
    /// routing rules: a rule edited since the download would describe where it
    /// *would* go now, which is not where the user will find it.
    func destinationText(for group: TorrentGroup) -> String? {
        guard let url = group.items.compactMap(\.finalURL).first else { return nil }
        return RelativeFolder.text(of: url, under: downloadDirectory)
    }

    /// Where a queued row sits in the line, 1-based, among the rows this
    /// screen is showing.
    ///
    /// Nil when the row is not queued at all. The engine's own queue is not
    /// exposed and its order is by file rather than by row, so this counts what
    /// the user can see — which is the thing the sub-line is explaining.
    func queuePosition(of group: TorrentGroup) -> Int? {
        guard group.rowState == .queued else { return nil }
        // Oldest first: the line is the order things joined it, and
        // `allDownloadRows` is newest first for the list's sake.
        let waiting = Array(allDownloadRows.filter { $0.rowState == .queued }.reversed())
        guard let index = waiting.firstIndex(where: { $0.id == group.id }) else { return nil }
        return index + 1
    }

    /// Everything the row's sub-line could need, assembled once.
    func facts(for group: TorrentGroup) -> DownloadRowFacts {
        DownloadRowFacts(
            state: group.rowState,
            bytesDownloaded: group.bytesDownloaded,
            totalBytes: group.totalBytes,
            pinnedUnit: group.pinnedUnit,
            etaText: group.etaText,
            failureReason: group.items.compactMap(\.errorMessage).first,
            destination: destinationText(for: group),
            queuePosition: queuePosition(of: group))
    }
}

extension AppModel.TorrentGroup {
    /// When this row arrived: its earliest file.
    ///
    /// The earliest rather than the latest, because a torrent's files are
    /// queued together and arrive over several seconds — taking the newest
    /// would let a row climb the list while it was still being filled in.
    var addedAt: Date? { items.map(\.addedAt).min() }

    /// The one state the row's glyph answers for. See `DownloadRowState`.
    ///
    /// `.completed` for a row with no files at all, which cannot happen —
    /// `buildTorrentGroups` drops those — and is the least alarming thing to
    /// draw if it ever does.
    var rowState: DownloadState { DownloadRowState.of(items.map(\.state)) ?? .completed }

    /// Whether the row is moving, which is the only time it draws a track.
    ///
    /// A bar under a finished download is a bar that will never change again,
    /// and one under a queued download claims a measurement nobody has taken.
    var isMoving: Bool { rowState == .downloading || rowState == .paused }
}
