import Testing
import Foundation
@testable import FetchKit

/**
 A persisted cloud row must come back onto the Downloads list at launch in
 the exact state it was saved in, without any disk value being consulted and
 without ever being handed to a transfer.
 */
@Suite struct CloudRestoreTests {

    /**
     A same-size file on disk must not complete a cloud row. The first
     `reconcile` overload takes `finalSize` / `partialSize` from a disk
     probe; for a cloud row those are meaningless and the row is returned
     untouched.
     */
    @Test func sameSizeDiskFileDoesNotCompleteACloudRow() {
        for state in [DownloadState.onCloud, .cloudQueued] {
            let outcome = LaunchRecovery.reconcile(
                state: state, recordedBytes: 0, expectedSize: 1_000,
                finalSize: 1_000, partialSize: 800, segmentMap: nil)
            #expect(outcome.state == state, "\(state) reconciled into \(outcome.state)")
            #expect(outcome.bytesDownloaded == 0)
        }
    }

    /**
     The second overload already carries the cloud arm (Task 2); a present
     partial file still leaves the row untouched at zero bytes.
     */
    @Test func partialFileDoesNotAdvanceACloudRow() {
        let outcome = LaunchRecovery.reconcile(
            state: .onCloud, recordedBytes: 0,
            partialExists: true, partialSize: 999)
        #expect(outcome.state == .onCloud)
        #expect(outcome.bytesDownloaded == 0)
    }

    /**
     The rule the restore loop's guard rests on: only locally-transferring
     states are handed to an engine.
     */
    @Test func onlyRowsThatTransferLocallyAreResumed() {
        #expect(
            [DownloadState.onCloud, .cloudQueued, .paused, .queued, .completed]
                .filter(\.transfersLocally) == [.paused, .queued])
    }
}
