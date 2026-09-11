import Testing
@testable import FetchKit

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
