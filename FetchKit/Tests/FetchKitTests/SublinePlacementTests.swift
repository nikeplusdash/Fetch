import Foundation
import Testing
@testable import FetchKit

@Suite("Sub-line placement")
struct SublinePlacementTests {
    private func facts(_ state: DownloadState) -> DownloadRowFacts {
        DownloadRowFacts(
            state: state, bytesDownloaded: 500, totalBytes: 1000,
            etaText: "about a minute", failureReason: "The service refused it",
            queuePosition: 2)
    }

    @Test("A row that is moving says how it is going, under the name")
    func runningStatesStackTheirLine() {
        for state in [DownloadState.downloading, .preparing] {
            let placement = DownloadSubline.placement(facts(state))
            #expect(placement.isUnderName, "\(state) should keep its second line")
            #expect(placement.text == DownloadSubline.text(facts(state)))
        }
    }

    @Test("A row that is not moving keeps its one line and moves what it had to the tooltip")
    func staticStatesMoveToTheTooltip() {
        for state in [DownloadState.missing, .failed, .cancelled, .queued, .paused, .cloudQueued] {
            let placement = DownloadSubline.placement(facts(state))
            #expect(placement.isTooltip, "\(state) should not stack a second line")
            #expect(placement.text?.isEmpty == false, "\(state) still has something to say")
        }
    }

    @Test("A finished row has nothing to add anywhere")
    func completedSaysNothing() {
        #expect(DownloadSubline.placement(facts(.completed)) == .none)
    }

    @Test("The failure reason survives the move rather than being dropped")
    func failureReasonIsKept() {
        let placement = DownloadSubline.placement(facts(.failed))
        #expect(placement.text?.contains("The service refused it") == true)
    }

    @Test("Every state has an answer, so a new one cannot fall through unnoticed")
    func everyStateIsPlaced() {
        for state in DownloadState.allCases {
            let placement = DownloadSubline.placement(facts(state))
            if placement == .none {
                #expect(state == .completed || state == .onCloud)
            } else {
                #expect(placement.text?.isEmpty == false)
            }
        }
    }

    @Test("Only downloading and preparing are moving")
    func activeStates() {
        #expect(DownloadState.downloading.isActive)
        #expect(DownloadState.preparing.isActive)
        for state in [DownloadState.queued, .paused, .completed, .failed, .cancelled, .missing] {
            #expect(!state.isActive, "\(state) is not changing second to second")
        }
    }

    @Test("Settled is its own question, not the one about requeueing")
    func settledIsNotBorrowedFromRequeueing() {
        #expect(DownloadState.completed.isSettled)
        #expect(DownloadState.missing.isSettled)
        #expect(DownloadState.failed.isSettled)
        #expect(DownloadState.cancelled.isSettled)
        #expect(!DownloadState.downloading.isSettled)
        #expect(!DownloadState.preparing.isSettled)
        #expect(!DownloadState.queued.isSettled)
        #expect(!DownloadState.paused.isSettled)
    }
}
