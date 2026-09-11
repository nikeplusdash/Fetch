import Testing
import Foundation
@testable import FetchKit

@Suite struct DownloadGroupingTests {


    @Test func filesSharingAFolderAreNamedAfterIt() {
        let name = DownloadGrouping.displayName(forPaths: [
            "The.Expanse.S03/S03E01.mkv",
            "The.Expanse.S03/S03E02.mkv",
        ])
        #expect(name == "The.Expanse.S03")
    }

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

    @Test func filesWithNoCommonRootFallBack() {
        #expect(DownloadGrouping.displayName(forPaths: ["a/x.mkv", "b/y.mkv"]) == nil)
    }

    @Test func noPathsHaveNoName() {
        #expect(DownloadGrouping.displayName(forPaths: []) == nil)
    }

    @Test func severalLooseFilesFallBack() {
        #expect(DownloadGrouping.displayName(forPaths: ["a.mkv", "b.mkv"]) == nil)
    }


    @Test func anythingDownloadingMakesTheTorrentActive() {
        #expect(DownloadGrouping.section(for: [.queued, .downloading, .completed]) == .active)
    }

    @Test func allQueuedIsQueued() {
        #expect(DownloadGrouping.section(for: [.queued, .queued]) == .queued)
    }

    @Test func allCompletedIsCompleted() {
        #expect(DownloadGrouping.section(for: [.completed, .completed]) == .completed)
    }

    @Test func anyFailureWithNothingRunningIsFailed() {
        #expect(DownloadGrouping.section(for: [.completed, .failed]) == .failed)
    }

    @Test func aFailureAlongsideRunningWorkStaysActive() {
        #expect(DownloadGrouping.section(for: [.downloading, .failed]) == .active)
    }

    @Test func pausedCountsAsActiveRatherThanQueued() {
        #expect(DownloadGrouping.section(for: [.paused]) == .active)
    }

    @Test func preparingIsActive() {
        #expect(DownloadGrouping.section(for: [.preparing]) == .active)
    }

    @Test func cancelledAloneIsFailed() {
        #expect(DownloadGrouping.section(for: [.cancelled]) == .failed)
    }

    @Test func anEmptyTorrentHasNoSection() {
        #expect(DownloadGrouping.section(for: []) == nil)
    }

    @Test func anAllReadyCloudGroupSitsInCompleted() {
        #expect(DownloadGrouping.section(for: [.onCloud]) == .completed)
    }

    @Test func aCloudGroupStillSettlingSitsWithTheQueue() {
        #expect(DownloadGrouping.section(for: [.cloudQueued]) == .queued)
        #expect(DownloadGrouping.section(for: [.onCloud, .cloudQueued]) == .queued)
    }

    @Test func aRealStateAlongsideACloudOneIsNotCollapsed() {
        #expect(DownloadGrouping.section(for: [.onCloud, .failed]) == .failed)
        #expect(DownloadGrouping.section(for: [.onCloud, .downloading]) == .active)
    }

    @Test func sectionsAreOrderedByLifecycle() {
        #expect(DownloadSection.allCases == [.active, .queued, .completed, .failed])
    }
}

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
        #expect(DownloadGrouping.skippedFiles(allFiles: [], queuedPaths: ["a.mkv"]).isEmpty)
    }

    @Test func skippedFilesKeepTheirOrderAndSizes() {
        let skipped = DownloadGrouping.skippedFiles(
            allFiles: [file("a", 10), file("b", 20), file("c", 30)],
            queuedPaths: ["b"])

        #expect(skipped.map(\.path) == ["a", "c"])
        #expect(skipped.map(\.length) == [10, 30])
    }

    @Test func matchingIsByFullPathNotFilename() {
        let skipped = DownloadGrouping.skippedFiles(
            allFiles: [file("S1/E01.mkv"), file("S2/E01.mkv")],
            queuedPaths: ["S1/E01.mkv"])

        #expect(skipped.map(\.path) == ["S2/E01.mkv"])
    }
}
