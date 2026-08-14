import Testing
@testable import FetchKit

/// What "download the other files" acts on.
///
/// A torrent's row has always known the whole torrent's contents, and offered
/// no way to act on the parts of it that were skipped or that failed:
/// `SkippedFileRow` rendered greyed and inert, `.missing` is terminal by
/// design, and a cancelled job is gone from the engine, so `resume` reached
/// none of them. The only way back was to find the release in Search again.
@Suite struct RedownloadableFilesTests {
    private let all = [
        TorrentMetadata.File(path: "show/a.mkv", length: 1),
        TorrentMetadata.File(path: "show/b.mkv", length: 2),
        TorrentMetadata.File(path: "show/c.mkv", length: 3),
        TorrentMetadata.File(path: "show/d.mkv", length: 4),
    ]

    private func paths(
        _ pairs: (String, DownloadState)...
    ) -> [(path: String, state: DownloadState)] {
        pairs.map { (path: $0.0, state: $0.1) }
    }

    @Test func aFileThatWasNeverQueuedIsOffered() {
        let offered = DownloadGrouping.redownloadableFiles(
            allFiles: all, paths: paths(("show/a.mkv", .completed)))

        #expect(offered.map(\.path) == ["show/b.mkv", "show/c.mkv", "show/d.mkv"])
    }

    /// The addition over `skippedFiles`: from the row's point of view a file
    /// that failed is in the same position as one never chosen — the torrent
    /// has it and this machine does not.
    @Test func aFailedCancelledOrMissingFileIsOfferedToo() {
        let offered = DownloadGrouping.redownloadableFiles(
            allFiles: all,
            paths: paths(
                ("show/a.mkv", .failed),
                ("show/b.mkv", .cancelled),
                ("show/c.mkv", .missing),
                ("show/d.mkv", .completed)))

        #expect(offered.map(\.path) == ["show/a.mkv", "show/b.mkv", "show/c.mkv"])
    }

    /// Offering to download something already on its way is how a user ends up
    /// with two copies of it and a row that sums both.
    @Test func workAlreadyInFlightIsNotOffered() {
        let offered = DownloadGrouping.redownloadableFiles(
            allFiles: all,
            paths: paths(
                ("show/a.mkv", .queued),
                ("show/b.mkv", .downloading),
                ("show/c.mkv", .paused),
                ("show/d.mkv", .preparing)))

        #expect(offered.isEmpty)
    }

    /// Not knowing a torrent's contents is not the same as knowing they were
    /// all declined — the same rule `skippedFiles` follows.
    @Test func anUnknownFileListOffersNothing() {
        let offered = DownloadGrouping.redownloadableFiles(
            allFiles: [], paths: paths(("show/a.mkv", .failed)))

        #expect(offered.isEmpty)
    }

    @Test func everythingIsOfferedWhenNothingWasEverQueued() {
        let offered = DownloadGrouping.redownloadableFiles(allFiles: all, paths: [])
        #expect(offered.count == 4)
    }
}
