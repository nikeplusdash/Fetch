import Testing
import Foundation
@testable import FetchKit

/// Presenting a torrent's files as one thing.
///
/// Selecting three files from a torrent queues three independent jobs, because
/// a debrid hands out per-file links — there is no "download the torrent" call.
/// The engine is right to work that way; the Downloads screen was wrong to
/// show it that way, listing three peers instead of one torrent with three
/// files.
@Suite struct DownloadGroupingTests {

    // MARK: - Naming

    /// A season pack: every file shares a folder, and that folder is the
    /// torrent's name.
    @Test func filesSharingAFolderAreNamedAfterIt() {
        let name = DownloadGrouping.displayName(forPaths: [
            "The.Expanse.S03/S03E01.mkv",
            "The.Expanse.S03/S03E02.mkv",
        ])
        #expect(name == "The.Expanse.S03")
    }

    /// A single loose file is its own name — "1 file" would tell the user
    /// nothing they cannot already see.
    @Test func aLoneFileIsItsOwnName() {
        #expect(DownloadGrouping.displayName(forPaths: ["Dune.2021.2160p.mkv"])
                == "Dune.2021.2160p.mkv")
    }

    @Test func nestedFilesUseTheTopLevelFolder() {
        let name = DownloadGrouping.displayName(forPaths: [
            "Pack/Season 1/E01.mkv",
            "Pack/Season 1/E02.mkv",
            "Pack/extras/behind.mkv",
        ])
        #expect(name == "Pack")
    }

    /// Files from one torrent that share no root — rare, but a torrent can be
    /// packed that way. Naming it after one of them would be arbitrary.
    @Test func filesWithNoCommonRootFallBack() {
        #expect(DownloadGrouping.displayName(forPaths: ["a/x.mkv", "b/y.mkv"]) == nil)
    }

    @Test func noPathsHaveNoName() {
        #expect(DownloadGrouping.displayName(forPaths: []) == nil)
    }

    /// Several loose files with no folder cannot be named after any one of
    /// them either.
    @Test func severalLooseFilesFallBack() {
        #expect(DownloadGrouping.displayName(forPaths: ["a.mkv", "b.mkv"]) == nil)
    }

    // MARK: - Sections

    @Test func anythingDownloadingMakesTheTorrentActive() {
        #expect(DownloadGrouping.section(for: [.queued, .downloading, .completed]) == .active)
    }

    @Test func allQueuedIsQueued() {
        #expect(DownloadGrouping.section(for: [.queued, .queued]) == .queued)
    }

    @Test func allCompletedIsCompleted() {
        #expect(DownloadGrouping.section(for: [.completed, .completed]) == .completed)
    }

    /// A torrent with one dead file needs attention even though the rest
    /// worked — burying it under Completed would hide the problem.
    @Test func anyFailureWithNothingRunningIsFailed() {
        #expect(DownloadGrouping.section(for: [.completed, .failed]) == .failed)
    }

    /// But a failure while others still run is still an active torrent: it is
    /// making progress, and moving it to Failed mid-flight would make it jump
    /// sections and back.
    @Test func aFailureAlongsideRunningWorkStaysActive() {
        #expect(DownloadGrouping.section(for: [.downloading, .failed]) == .active)
    }

    @Test func pausedCountsAsActiveRatherThanQueued() {
        // Paused is a state the user chose and can undo from the row; Queued
        // means waiting on the concurrency limit, which they cannot.
        #expect(DownloadGrouping.section(for: [.paused]) == .active)
    }

    @Test func preparingIsActive() {
        #expect(DownloadGrouping.section(for: [.preparing]) == .active)
    }

    @Test func cancelledAloneIsFailed() {
        // Terminal and not successful — it belongs where the user looks for
        // things that did not finish.
        #expect(DownloadGrouping.section(for: [.cancelled]) == .failed)
    }

    @Test func anEmptyTorrentHasNoSection() {
        #expect(DownloadGrouping.section(for: []) == nil)
    }

    /// Sections read top to bottom in the order work moves through them.
    @Test func sectionsAreOrderedByLifecycle() {
        #expect(DownloadSection.allCases == [.active, .queued, .completed, .failed])
    }
}

/// Files in the torrent that were **not** queued.
///
/// A torrent row that lists only what you picked describes your selection, not
/// the torrent. Showing the skipped files greyed alongside makes the row an
/// honest picture of what is actually in there — and makes it obvious when a
/// selection went wrong.
@Suite struct SkippedFileTests {
    private func file(_ path: String, _ length: Int64 = 100) -> TorrentMetadata.File {
        TorrentMetadata.File(path: path, length: length)
    }

    @Test func filesNotQueuedAreReportedAsSkipped() {
        let skipped = DownloadGrouping.skippedFiles(
            allFiles: [file("Pack/E01.mkv"), file("Pack/E02.mkv"), file("Pack/E03.mkv")],
            queuedPaths: ["Pack/E01.mkv", "Pack/E03.mkv"])

        #expect(skipped.map(\.path) == ["Pack/E02.mkv"])
    }

    @Test func queuingEverythingLeavesNothingSkipped() {
        let all = [file("a.mkv"), file("b.mkv")]
        #expect(DownloadGrouping.skippedFiles(
            allFiles: all, queuedPaths: ["a.mkv", "b.mkv"]).isEmpty)
    }

    @Test func withNoKnownFileListNothingIsClaimedSkipped() {
        // Not "everything was skipped": we simply do not know what is in the
        // torrent, and inventing a skipped list would be worse than none.
        #expect(DownloadGrouping.skippedFiles(allFiles: [], queuedPaths: ["a.mkv"]).isEmpty)
    }

    @Test func skippedFilesKeepTheirOrderAndSizes() {
        let skipped = DownloadGrouping.skippedFiles(
            allFiles: [file("a", 10), file("b", 20), file("c", 30)],
            queuedPaths: ["b"])

        #expect(skipped.map(\.path) == ["a", "c"])
        #expect(skipped.map(\.length) == [10, 30])
    }

    /// Paths are the join key across a preview list, the debrid's
    /// authoritative list and the torrent's own metadata (§6), so matching
    /// must be exact rather than by filename.
    @Test func matchingIsByFullPathNotFilename() {
        let skipped = DownloadGrouping.skippedFiles(
            allFiles: [file("S1/E01.mkv"), file("S2/E01.mkv")],
            queuedPaths: ["S1/E01.mkv"])

        #expect(skipped.map(\.path) == ["S2/E01.mkv"])
    }
}
