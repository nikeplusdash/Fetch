import Testing
@testable import FetchKit

@Suite struct RowActionsTests {

    private func actions(
        _ state: DownloadState, local: Bool = false, playable: Bool = false
    ) -> [RowAction] {
        RowActions.available(for: state, hasLocalFile: local, isPlayable: playable)
    }

    @Test func everyRowCanBeForgotten() {
        for state in DownloadState.allCases {
            #expect(actions(state).contains(.remove), "\(state) offers no ending")
        }
    }

    @Test func onlyARowWithAFileOffersTheLocalActions() {
        #expect(actions(.completed, local: true).contains(.open))
        #expect(actions(.completed, local: true).contains(.showInFinder))
        #expect(!actions(.onCloud).contains(.open))
        #expect(!actions(.onCloud).contains(.showInFinder))
    }

    /**
     The service having accepted a torrent is not the service having the
     bytes, so Play on a queued cloud row would resolve against nothing.
     */
    @Test func playNeedsBytesSomewhere() {
        #expect(actions(.completed, local: true, playable: true).contains(.play))
        #expect(actions(.onCloud, playable: true).contains(.play))
        #expect(!actions(.cloudQueued, playable: true).contains(.play))
        #expect(!actions(.completed, local: true, playable: false).contains(.play))
    }

    @Test func onlyACloudRowOffersTheServicesOwnPage() {
        #expect(actions(.onCloud).contains(.openOnService))
        #expect(actions(.cloudQueued).contains(.openOnService))
        #expect(!actions(.completed, local: true).contains(.openOnService))
    }

    @Test func aReadyCloudRowCanBeFetchedAndAQueuedOneCannot() {
        #expect(actions(.onCloud).contains(.download))
        #expect(!actions(.cloudQueued).contains(.download))
    }

    /**
     Nothing was ever started here, so Skip would stop nothing.
     */
    @Test func aQueuedCloudRowOffersNeitherDownloadNorSkip() {
        #expect(!actions(.cloudQueued).contains(.download))
        #expect(!actions(.cloudQueued).contains(.skip))
    }

    /**
     A queued cloud row's only cancel path is the confirmed "Delete from
     Service", surfaced as `.cancel`; no other state offers it, because the
     non-cloud hover ✕ is `DownloadFilter.isCancellable`-driven in the view.
     */
    @Test func onlyAQueuedCloudRowOffersCancel() {
        #expect(actions(.cloudQueued).contains(.cancel))
        #expect(!actions(.cloudQueued).contains(.download))
        #expect(!actions(.cloudQueued).contains(.skip))
        for state in [DownloadState.onCloud, .downloading, .queued, .paused, .completed] {
            #expect(!actions(state).contains(.cancel), "\(state) offers a stray cancel")
        }
    }

    @Test func theStatesThatCanBeRefetchedOfferDownload() {
        for state in [DownloadState.failed, .cancelled, .missing, .onCloud] {
            #expect(actions(state).contains(.download), "\(state) cannot be re-fetched")
        }
    }

    @Test func onlyAMovingRowCanBeSkipped() {
        for state in [DownloadState.queued, .preparing, .downloading] {
            #expect(actions(state).contains(.skip))
        }
        for state in [DownloadState.completed, .onCloud, .cloudQueued, .paused] {
            #expect(!actions(state).contains(.skip), "\(state) offers a Skip that stops nothing")
        }
    }

    /**
     A paused row already has a half-transferred file and a Resume button;
     Download would start a second transfer beside it.
     */
    @Test func aPausedRowOffersNeither() {
        #expect(!actions(.paused, local: true).contains(.download))
        #expect(!actions(.paused, local: true).contains(.skip))
    }

    /**
     A completed row whose file was deleted mid-session should offer to
     fetch it again, the same way `.missing` does.
     */
    @Test func aCompletedRowWithNoFileCanBeFetchedAgain() {
        #expect(actions(.completed, local: false).contains(.download))
        #expect(!actions(.completed, local: true).contains(.download))
    }
}
