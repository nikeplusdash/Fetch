import Testing
import Foundation
@testable import FetchKit

@Suite struct CloudRowStateTests {

    @Test func bothCloudStatesAreCloudOnlyAndNeitherTransfers() {
        for state in [DownloadState.cloudQueued, .onCloud] {
            #expect(state.isCloudOnly)
            #expect(!state.transfersLocally, "\(state) must never be handed to the engine")
        }
    }

    @Test func onlyTheReadyOneIsCloudReady() {
        #expect(DownloadState.onCloud.isCloudReady)
        #expect(!DownloadState.cloudQueued.isCloudReady)
    }

    @Test func everyOrdinaryStateStillTransfers() {
        for state in [DownloadState.queued, .preparing, .downloading, .paused, .failed] {
            #expect(state.transfersLocally, "\(state) must still be resumable")
            #expect(!state.isCloudOnly)
            #expect(!state.isCloudReady)
        }
    }

    @Test func terminalStatesAreNeitherCloudNorTransferred() {
        for state in [DownloadState.completed, .cancelled, .missing] {
            #expect(!state.transfersLocally)
            #expect(!state.isCloudOnly)
            #expect(!state.isCloudReady)
        }
    }

    @Test func theRawValuesAreStableBecauseTheyArePersisted() {
        #expect(DownloadState.cloudQueued.rawValue == "cloudQueued")
        #expect(DownloadState.onCloud.rawValue == "onCloud")
        #expect(DownloadState(rawValue: "cloudQueued") == .cloudQueued)
        #expect(DownloadState(rawValue: "onCloud") == .onCloud)
    }

    @Test func statesWrittenBeforeThisStillDecode() {
        for raw in ["queued", "preparing", "downloading", "paused",
                    "completed", "failed", "cancelled", "missing"] {
            #expect(DownloadState(rawValue: raw) != nil, "\(raw) stopped decoding")
        }
    }

    @Test func aCloudRowIsNotActiveAndNotSettled() {
        #expect(!DownloadState.cloudQueued.isActive)
        #expect(!DownloadState.onCloud.isActive)
        #expect(!DownloadState.onCloud.isTerminal)
    }
}
