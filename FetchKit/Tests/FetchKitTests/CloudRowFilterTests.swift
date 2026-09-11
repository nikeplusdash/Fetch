import Testing
@testable import FetchKit

@Suite struct CloudRowFilterTests {

    @Test func aQueuedCloudRowIsADownload() {
        #expect(DownloadFilter.downloads.accepts(.cloudQueued))
        #expect(!DownloadFilter.library.accepts(.cloudQueued))
    }

    @Test func aReadyCloudRowIsInTheLibrary() {
        #expect(DownloadFilter.library.accepts(.onCloud))
        #expect(!DownloadFilter.downloads.accepts(.onCloud))
    }

    /**
     The Cloud pill is the live account listing and owns no DownloadState
     rows at all — least of all these, which would then appear twice.
     */
    @Test func theCloudPillStillOwnsNoStateRows() {
        for state in DownloadState.allCases {
            #expect(!DownloadFilter.cloud.accepts(state))
        }
    }

    @Test func aQueuedCloudRowCanBeCancelledAndAReadyOneCannot() {
        #expect(DownloadFilter.isCancellable(.cloudQueued))
        #expect(!DownloadFilter.isCancellable(.onCloud))
    }

    @Test func neitherCloudStateIsClearable() {
        #expect(!DownloadFilter.isClearable(.cloudQueued))
        #expect(!DownloadFilter.isClearable(.onCloud))
    }

    /**
     The invariant the two toolbar buttons rest on: every state is
     cancellable, clearable, or shown as settled — never two at once.
     */
    @Test func cancellableAndClearableStayDisjoint() {
        for state in DownloadState.allCases {
            #expect(!(DownloadFilter.isCancellable(state) && DownloadFilter.isClearable(state)),
                    "\(state) claims to be both")
        }
    }

    @Test func everyStateLandsInExactlyOneOfDownloadsAndLibrary() {
        for state in DownloadState.allCases {
            let inDownloads = DownloadFilter.downloads.accepts(state)
            let inLibrary = DownloadFilter.library.accepts(state)
            #expect(inDownloads != inLibrary, "\(state) is in both pills or neither")
        }
    }
}
