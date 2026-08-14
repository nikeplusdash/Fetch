import Testing
import Foundation
@testable import FetchKit

@Suite struct LaunchRecoveryTests {
    @Test func missingPartialResetsProgressToZeroAndQueues() {
        let outcome = LaunchRecovery.reconcile(
            state: .downloading, recordedBytes: 500, partialExists: false, partialSize: 0
        )
        #expect(outcome.state == .queued)
        #expect(outcome.bytesDownloaded == 0)
    }

    /// The file on disk is the source of truth, not the recorded value —
    /// SwiftData is only written every ~2s, so it lags.
    @Test func diskSizeWinsOverRecordedValue() {
        let outcome = LaunchRecovery.reconcile(
            state: .downloading, recordedBytes: 500, partialExists: true, partialSize: 812
        )
        #expect(outcome.bytesDownloaded == 812)
    }

    @Test func downloadingAtQuitBecomesPausedNeverAutoResumes() {
        let outcome = LaunchRecovery.reconcile(
            state: .downloading, recordedBytes: 100, partialExists: true, partialSize: 100
        )
        #expect(outcome.state == .paused)
    }

    /// `.missing`, not `.failed`: the transfer did not fail, and `.failed` is
    /// resumable — so the row offered a Resume button that would silently
    /// re-download a file the user had deleted on purpose.
    @Test func completedRecordWithMissingFileBecomesMissing() {
        let outcome = LaunchRecovery.reconcile(
            state: .completed, recordedBytes: 100, partialExists: false, partialSize: 0
        )
        #expect(outcome.state == .missing)
    }

    @Test func queuedStaysQueued() {
        let outcome = LaunchRecovery.reconcile(
            state: .queued, recordedBytes: 0, partialExists: false, partialSize: 0
        )
        #expect(outcome.state == .queued)
    }
}

/// The distinction that caused every finished download to come back failed.
///
/// `reconcile`'s flag means "the file this record refers to still exists". For
/// an interrupted download that is the `.fetchpart`; for a completed one the
/// partial is gone by definition, because finishing *moves* it to its final
/// name. Checking the partial for both marked every completed download failed
/// on the next launch — visible immediately on a real install, and invisible
/// to every test until one asked.
@Suite struct CompletedRecoveryTests {
    @Test func aCompletedDownloadWhoseFileIsPresentStaysCompleted() {
        let outcome = LaunchRecovery.reconcile(
            state: .completed, recordedBytes: 606_400_000,
            partialExists: true, partialSize: 606_400_000)

        #expect(outcome.state == .completed)
        #expect(outcome.bytesDownloaded == 606_400_000)
    }

    /// Genuinely gone — moved or deleted outside the app — is its own state,
    /// so the row can say "Missing" and be cleared, rather than claiming a
    /// failure that never happened.
    @Test func aCompletedDownloadWhoseFileVanishedIsMissing() {
        let outcome = LaunchRecovery.reconcile(
            state: .completed, recordedBytes: 100,
            partialExists: false, partialSize: 0)

        #expect(outcome.state == .missing)
    }

    /// And the in-progress case still reads its size from the partial rather
    /// than trusting the recorded byte count.
    @Test func anInterruptedDownloadTrustsTheFileOverTheRecord() {
        let outcome = LaunchRecovery.reconcile(
            state: .downloading, recordedBytes: 400_000_000,
            partialExists: true, partialSize: 120_000_000)

        #expect(outcome.state == .paused)
        #expect(outcome.bytesDownloaded == 120_000_000)
    }
}

/// Believing the disk over the record.
///
/// A real install ended up with 26 records marked `cancelled` whose files were
/// complete and present — the fallout of restore checking the wrong file, which
/// marked finished downloads `failed`, which made cancelling them possible.
/// The record was wrong; the file was right there.
///
/// The codebase already states the principle ("the partial file on disk is the
/// source of truth"). This extends it: a final file present at its full size
/// means the download is done, whatever the record claims.
@Suite struct FilesystemTruthTests {
    @Test func afullSizeFinalFileMeansCompletedWhateverTheRecordSays() {
        for claimed in [DownloadState.cancelled, .failed, .paused, .queued, .downloading] {
            let outcome = LaunchRecovery.reconcile(
                state: claimed, recordedBytes: 0, expectedSize: 1000,
                finalSize: 1000, partialSize: nil)

            #expect(outcome.state == .completed, "record said \(claimed)")
            #expect(outcome.bytesDownloaded == 1000)
        }
    }

    /// A truncated final file is not a finished download — trusting its
    /// presence alone would present a broken file as complete.
    @Test func aShortFinalFileIsNotTreatedAsComplete() {
        let outcome = LaunchRecovery.reconcile(
            state: .downloading, recordedBytes: 400, expectedSize: 1000,
            finalSize: 400, partialSize: nil)

        #expect(outcome.state != .completed)
    }

    /// A deliberate cancel with nothing on disk stays cancelled — this rule
    /// heals stale records, it does not resurrect abandoned downloads.
    @Test func aCancelledDownloadWithNoFileStaysCancelled() {
        let outcome = LaunchRecovery.reconcile(
            state: .cancelled, recordedBytes: 0, expectedSize: 1000,
            finalSize: nil, partialSize: nil)

        #expect(outcome.state == .cancelled)
    }

    @Test func anInterruptedDownloadStillResumesFromItsPartial() {
        let outcome = LaunchRecovery.reconcile(
            state: .downloading, recordedBytes: 900, expectedSize: 1000,
            finalSize: nil, partialSize: 250)

        #expect(outcome.state == .paused)
        #expect(outcome.bytesDownloaded == 250)
    }

    /// Unknown expected size cannot be checked against, so the record stands.
    @Test func anUnknownExpectedSizeFallsBackToTheRecord() {
        let outcome = LaunchRecovery.reconcile(
            state: .cancelled, recordedBytes: 0, expectedSize: 0,
            finalSize: 500, partialSize: nil)

        #expect(outcome.state == .cancelled)
    }

    // MARK: - A preallocated partial is not a downloaded partial
    //
    // `SegmentedTransfer.preallocate` grows the `.fetchpart` to the full file
    // length before the first byte is requested. Measuring that file reported
    // every failed segmented download at 100% on the next launch — 80 of them
    // in the install this was found on, none of which had transferred a byte.

    @Test func aFullSizePartialWithAnEmptyMapIsNotTreatedAsDownloaded() {
        let outcome = LaunchRecovery.reconcile(
            state: .failed, recordedBytes: 1000, expectedSize: 1000,
            finalSize: nil, partialSize: 1000,
            segmentMap: SegmentMap(totalBytes: 1000, segments: 3))

        #expect(outcome.bytesDownloaded == 0)
        #expect(outcome.state == .failed)
    }

    /// The dangerous half. At 100% the single-connection path takes its
    /// `offset == expectedSize` shortcut and `verify` — which compares sizes
    /// and nothing else — passes, so the engine renames a file of zeroes into
    /// place and calls it Completed.
    @Test func aFullSizePartialOfZeroesNeverReconcilesToCompleted() {
        let outcome = LaunchRecovery.reconcile(
            state: .queued, recordedBytes: 0, expectedSize: 1000,
            finalSize: nil, partialSize: 1000,
            segmentMap: SegmentMap(totalBytes: 1000, segments: 3))

        #expect(outcome.state != .completed)
        #expect(outcome.bytesDownloaded < 1000)
    }

    @Test func aPartlyCompleteMapReportsWhatTheMapHolds() {
        var map = SegmentMap(totalBytes: 1000, segments: 4)
        map.markComplete(0..<250)
        map.markComplete(500..<750)

        let outcome = LaunchRecovery.reconcile(
            state: .paused, recordedBytes: 1000, expectedSize: 1000,
            finalSize: nil, partialSize: 1000, segmentMap: map)

        #expect(outcome.bytesDownloaded == 500)
    }

    /// A map for a different length describes other content — the same rule
    /// `DownloadEngine.restore` applies before resuming from one.
    @Test func aMapForADifferentSizeIsIgnored() {
        var map = SegmentMap(totalBytes: 4000, segments: 4)
        map.markComplete(0..<4000)

        let outcome = LaunchRecovery.reconcile(
            state: .paused, recordedBytes: 250, expectedSize: 1000,
            finalSize: nil, partialSize: 250, segmentMap: map)

        #expect(outcome.bytesDownloaded == 250)
    }

    /// Single-connection downloads never preallocate and carry no map, so the
    /// file's length is still the answer for them. This is every existing case.
    @Test func withNoMapThePartialFileIsStillTheAnswer() {
        let outcome = LaunchRecovery.reconcile(
            state: .paused, recordedBytes: 900, expectedSize: 1000,
            finalSize: nil, partialSize: 250, segmentMap: nil)

        #expect(outcome.bytesDownloaded == 250)
    }
}
