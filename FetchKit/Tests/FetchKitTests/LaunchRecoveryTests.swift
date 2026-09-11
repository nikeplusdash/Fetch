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

@Suite struct CompletedRecoveryTests {
    @Test func aCompletedDownloadWhoseFileIsPresentStaysCompleted() {
        let outcome = LaunchRecovery.reconcile(
            state: .completed, recordedBytes: 606_400_000,
            partialExists: true, partialSize: 606_400_000)

        #expect(outcome.state == .completed)
        #expect(outcome.bytesDownloaded == 606_400_000)
    }

    @Test func aCompletedDownloadWhoseFileVanishedIsMissing() {
        let outcome = LaunchRecovery.reconcile(
            state: .completed, recordedBytes: 100,
            partialExists: false, partialSize: 0)

        #expect(outcome.state == .missing)
    }

    @Test func anInterruptedDownloadTrustsTheFileOverTheRecord() {
        let outcome = LaunchRecovery.reconcile(
            state: .downloading, recordedBytes: 400_000_000,
            partialExists: true, partialSize: 120_000_000)

        #expect(outcome.state == .paused)
        #expect(outcome.bytesDownloaded == 120_000_000)
    }
}

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

    @Test func aShortFinalFileIsNotTreatedAsComplete() {
        let outcome = LaunchRecovery.reconcile(
            state: .downloading, recordedBytes: 400, expectedSize: 1000,
            finalSize: 400, partialSize: nil)

        #expect(outcome.state != .completed)
    }

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

    @Test func anUnknownExpectedSizeFallsBackToTheRecord() {
        let outcome = LaunchRecovery.reconcile(
            state: .cancelled, recordedBytes: 0, expectedSize: 0,
            finalSize: 500, partialSize: nil)

        #expect(outcome.state == .cancelled)
    }


    @Test func aFullSizePartialWithAnEmptyMapIsNotTreatedAsDownloaded() {
        let outcome = LaunchRecovery.reconcile(
            state: .failed, recordedBytes: 1000, expectedSize: 1000,
            finalSize: nil, partialSize: 1000,
            segmentMap: SegmentMap(totalBytes: 1000, segments: 3))

        #expect(outcome.bytesDownloaded == 0)
        #expect(outcome.state == .failed)
    }

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

    @Test func aMapForADifferentSizeIsIgnored() {
        var map = SegmentMap(totalBytes: 4000, segments: 4)
        map.markComplete(0..<4000)

        let outcome = LaunchRecovery.reconcile(
            state: .paused, recordedBytes: 250, expectedSize: 1000,
            finalSize: nil, partialSize: 250, segmentMap: map)

        #expect(outcome.bytesDownloaded == 250)
    }

    @Test func withNoMapThePartialFileIsStillTheAnswer() {
        let outcome = LaunchRecovery.reconcile(
            state: .paused, recordedBytes: 900, expectedSize: 1000,
            finalSize: nil, partialSize: 250, segmentMap: nil)

        #expect(outcome.bytesDownloaded == 250)
    }
}
