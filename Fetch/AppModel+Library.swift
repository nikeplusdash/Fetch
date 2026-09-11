import Foundation
import FetchKit

extension AppModel {
    var allDownloadRows: [TorrentGroup] {
        DownloadLibrary.newestFirst(
            torrentGroups.flatMap(\.groups), date: \.addedAt, name: \.displayName)
    }

    var visibleDownloadRows: [TorrentGroup] {
        let narrowed = allDownloadRows.filter { downloadFilter.accepts($0.rowState) }
        guard downloadFilter.showsCategories, let kind = libraryKind else { return narrowed }
        return narrowed.filter { $0.mediaKind == kind }
    }

    func downloadCount(for filter: DownloadFilter) -> Int {
        allDownloadRows.filter { filter.accepts($0.rowState) }.count
    }

    var clearableCount: Int {
        allDownloadRows.count { DownloadFilter.isClearable($0.rowState) }
    }

    /**
     Counts preparations too, the way `downloadRailText` does: a torrent
     still resolving its metadata is drawn as a row in this list and reads
     as in progress, so a Cancel button that named a smaller number than
     the rows it was about to stop would be miscounting in the one place
     the user can check it.
     */
    var cancellableCount: Int {
        allDownloadRows.count { DownloadFilter.isCancellable($0.rowState) }
            + preparations.count
    }

    var libraryKinds: [(kind: MediaKind, count: Int)] {
        let completed = allDownloadRows.filter { DownloadFilter.library.accepts($0.rowState) }
        return DownloadLibrary
            .sections(completed, kind: \.mediaKind, name: \.displayName)
            .map { (kind: $0.kind, count: $0.rows.count) }
    }

    var downloadRailText: String {
        switch downloadFilter {
        case .downloads:
            return DownloadRail.activity(
                visibleDownloadRows.map(\.rowState)
                + Array(repeating: .preparing, count: preparations.count))
        case .library:
            let rows = visibleDownloadRows
            return DownloadRail.library(
                count: rows.count,
                bytes: rows.reduce(0) { $0 + $1.totalBytes },
                kind: libraryKind)
        case .cloud:
            let rows = visibleCloudRows
            return DownloadRail.library(
                count: rows.count,
                bytes: rows.reduce(0) { $0 + $1.size },
                kind: libraryKind)
        }
    }

    /**
     The cloud rows the kind bar has left showing. Cloud sizes can be zero
     — Premiumize's listing does not report one until a row's files are
     hydrated — so the rail's byte total is a floor, not a promise.
     */
    var visibleCloudRows: [CloudRow] {
        guard let kind = libraryKind else { return cloudRows }
        return cloudRows.filter { $0.kind == kind }
    }

    var cloudKinds: [(kind: MediaKind, count: Int)] {
        CloudLibrary.sections(cloudRows).map { (kind: $0.kind, count: $0.rows.count) }
    }

    /**
     What a pill's badge counts. Cloud rows are not `DownloadState` rows,
     so `downloadCount(for:)` would answer zero for every one of them.
     */
    func pillCount(for filter: DownloadFilter) -> Int {
        filter == .cloud ? cloudRows.count : downloadCount(for: filter)
    }

    var configuredServicesText: String {
        providers.isEmpty
            ? ""
            : providers.map(\.displayName).sorted().joined(separator: ", ")
    }

    func destinationText(for group: TorrentGroup) -> String? {
        guard let url = group.items.compactMap(\.finalURL).first else { return nil }
        return RelativeFolder.text(of: url, under: downloadDirectory)
    }

    func queuePosition(of group: TorrentGroup) -> Int? {
        guard group.rowState == .queued else { return nil }
        let waiting = Array(allDownloadRows.filter { $0.rowState == .queued }.reversed())
        guard let index = waiting.firstIndex(where: { $0.id == group.id }) else { return nil }
        return index + 1
    }

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
    var addedAt: Date? { items.map(\.addedAt).min() }

    var rowState: DownloadState { DownloadRowState.of(items.map(\.state)) ?? .completed }

    var isMoving: Bool { rowState == .downloading || rowState == .paused }
}
